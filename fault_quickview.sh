#!/usr/bin/env bash
set -euo pipefail

FLT=""
TICKET_DB=""
HOST=""
OOB_IP=""
RACK=""
RAID_FILE=""
MOUNT_FILE=""
SEL_FILE=""
RAID_CMD="/usr/local/bin/raidcheck.sh"
MOUNT_CMD="mount"
SEL_CMD="ipmitool sel list"
SSH_USER=""
JSON=0

usage() {
  cat <<'EOF'
Usage:
  fault_quickview.sh --flt FLT-1001 [options]

Options:
  --ticket-db FILE   CSV with columns flt,hostname,oob_ip,rack
  --host HOST        Hostname override (required when --ticket-db not used)
  --oob-ip IP        OOB IP override
  --rack RACK        Rack override
  --raid-file FILE   Local raid output file
  --mount-file FILE  Local mount output file
  --sel-file FILE    Local SEL output file
  --raid-cmd CMD     Remote raid command (default: /usr/local/bin/raidcheck.sh)
  --mount-cmd CMD    Remote mount command (default: mount)
  --sel-cmd CMD      Remote SEL command (default: ipmitool sel list)
  --ssh-user USER    SSH user for remote command execution
  --json             Output JSON
  -h, --help         Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --flt) FLT="${2:-}"; shift 2 ;;
    --ticket-db) TICKET_DB="${2:-}"; shift 2 ;;
    --host) HOST="${2:-}"; shift 2 ;;
    --oob-ip) OOB_IP="${2:-}"; shift 2 ;;
    --rack) RACK="${2:-}"; shift 2 ;;
    --raid-file) RAID_FILE="${2:-}"; shift 2 ;;
    --mount-file) MOUNT_FILE="${2:-}"; shift 2 ;;
    --sel-file) SEL_FILE="${2:-}"; shift 2 ;;
    --raid-cmd) RAID_CMD="${2:-}"; shift 2 ;;
    --mount-cmd) MOUNT_CMD="${2:-}"; shift 2 ;;
    --sel-cmd) SEL_CMD="${2:-}"; shift 2 ;;
    --ssh-user) SSH_USER="${2:-}"; shift 2 ;;
    --json) JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$FLT" ]]; then
  echo "--flt is required" >&2
  exit 1
fi

trim() {
  local s="$1"
  s="${s#${s%%[![:space:]]*}}"
  s="${s%${s##*[![:space:]]}}"
  printf '%s' "$s"
}

load_ticket() {
  local db="$1" flt="$2"
  awk -F',' -v flt="$flt" 'NR>1 && $1==flt {print $2","$3","$4; found=1; exit} END{if(!found) exit 1}' "$db"
}

run_remote() {
  local target="$1" cmd="$2"
  if [[ -n "$SSH_USER" ]]; then
    ssh "${SSH_USER}@${target}" "$cmd"
  else
    ssh "$target" "$cmd"
  fi
}

read_input_or_remote() {
  local file="$1" target="$2" cmd="$3"
  if [[ -n "$file" ]]; then
    cat "$file"
  elif [[ -n "$target" && -n "$cmd" ]]; then
    run_remote "$target" "$cmd"
  else
    true
  fi
}

if [[ -n "$TICKET_DB" ]]; then
  if ! row="$(load_ticket "$TICKET_DB" "$FLT")"; then
    echo "FLT not found in ticket db: $FLT" >&2
    exit 1
  fi
  HOST="$(trim "$(cut -d',' -f1 <<<"$row")")"
  OOB_IP="$(trim "$(cut -d',' -f2 <<<"$row")")"
  RACK="$(trim "$(cut -d',' -f3 <<<"$row")")"
elif [[ -z "$HOST" ]]; then
  echo "--host is required when --ticket-db is not provided" >&2
  exit 1
fi

RAID_TEXT="$(read_input_or_remote "$RAID_FILE" "$HOST" "$RAID_CMD")"
MOUNT_TEXT="$(read_input_or_remote "$MOUNT_FILE" "$HOST" "$MOUNT_CMD")"
SEL_TEXT="$(read_input_or_remote "$SEL_FILE" "$OOB_IP" "$SEL_CMD")"

declare -A MOUNTS
while IFS= read -r line; do
  [[ -z "${line// }" ]] && continue
  if [[ "$line" =~ ^(/dev/[[:alnum:]_/-]+)[[:space:]]+on[[:space:]]+([^[:space:]]+) ]]; then
    MOUNTS["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
  elif [[ "$line" =~ ^(sd[a-zA-Z0-9]+)[[:space:]]+(.+)$ ]]; then
    dev="/dev/${BASH_REMATCH[1]}"
    mp="$(awk '{print $NF}' <<<"${BASH_REMATCH[2]}")"
    [[ "$mp" == "-" ]] && mp=""
    MOUNTS["$dev"]="$mp"
  fi
done <<< "$MOUNT_TEXT"

disk_rows=()
while IFS= read -r line; do
  [[ -z "${line// }" ]] && continue
  if [[ "$line" =~ [Ss]lot[:=][[:space:]]*([0-9]+).*([Ss]tate|status)[:=][[:space:]]*([A-Za-z]+) ]]; then
    slot="${BASH_REMATCH[1]}"
    state="${BASH_REMATCH[3],,}"
    if [[ "$state" =~ ^(failed|missing|fault|offline|bad)$ ]]; then
      serial="$(sed -nE 's/.*(SN|Serial)[:=][[:space:]]*([[:alnum:]-]+).*/\2/p' <<<"$line" | head -n1)"
      dev="$(sed -nE 's#.*(/dev/[[:alnum:]_/-]+).*#\1#p' <<<"$line" | head -n1)"
      mp="${MOUNTS[$dev]:-}"
      safe="true"
      [[ -n "$mp" ]] && safe="false"
      disk_rows+=("$slot|${state^^}|$serial|$dev|$mp|$safe")
    fi
  elif grep -Eiq '\b(failed|missing|fault|offline)\b' <<<"$line"; then
    slot="$(sed -nE 's/.*(slot|bay)[[:space:]]*([0-9]+).*/\2/ip' <<<"$line" | head -n1)"
    [[ -z "$slot" ]] && slot="?"
    disk_rows+=("$slot|FAULT||| |false")
  fi
done <<< "$RAID_TEXT"

mem_rows=()
fan_rows=()
psu_rows=()
while IFS= read -r line; do
  [[ -z "${line// }" ]] && continue
  lower="$(tr '[:upper:]' '[:lower:]' <<<"$line")"
  if [[ "$lower" != *assert* && "$lower" != *critical* && "$lower" != *fail* ]]; then
    continue
  fi
  location="$(awk -F'|' '{if(NF>=4){gsub(/^ +| +$/,"",$4); print $4}}' <<<"$line")"
  [[ -z "$location" ]] && location="UNKNOWN"

  if grep -Eiq 'dimm|memory|ecc' <<<"$line"; then
    mem_rows+=("$location|FAULT|$line")
  elif grep -Eiq 'fan' <<<"$line"; then
    fan_rows+=("$location|FAULT|$line")
  elif grep -Eiq 'psu|power supply|power unit' <<<"$line"; then
    psu_rows+=("$location|FAULT|$line")
  fi
done <<< "$SEL_TEXT"

json_escape() {
  sed 's/\\/\\\\/g; s/"/\\"/g' <<<"$1"
}

if [[ "$JSON" -eq 1 ]]; then
  printf '{\n'
  printf '  "ticket": {"flt":"%s","hostname":"%s","oob_ip":"%s","rack":"%s"},\n' \
    "$(json_escape "$FLT")" "$(json_escape "$HOST")" "$(json_escape "$OOB_IP")" "$(json_escape "$RACK")"

  printf '  "disk_faults": ['
  for i in "${!disk_rows[@]}"; do
    IFS='|' read -r slot status serial dev mp safe <<<"${disk_rows[$i]}"
    [[ $i -gt 0 ]] && printf ','
    printf '{"slot":"%s","status":"%s","serial":"%s","device":"%s","mountpoint":"%s","replace_safe":%s}' \
      "$(json_escape "$slot")" "$(json_escape "$status")" "$(json_escape "$serial")" "$(json_escape "$dev")" "$(json_escape "$mp")" "$safe"
  done
  printf '],\n'

  print_component_array() {
    local name="$1"; shift
    local -n arr=$1
    printf '  "%s": [' "$name"
    for i in "${!arr[@]}"; do
      IFS='|' read -r loc status raw <<<"${arr[$i]}"
      [[ $i -gt 0 ]] && printf ','
      printf '{"location":"%s","status":"%s","raw":"%s"}' \
        "$(json_escape "$loc")" "$(json_escape "$status")" "$(json_escape "$raw")"
    done
    printf ']'
  }

  print_component_array mem_faults mem_rows
  printf ',\n'
  print_component_array fan_faults fan_rows
  printf ',\n'
  print_component_array psu_faults psu_rows
  printf '\n}\n'
else
  echo "FLT: $FLT"
  echo "Host: $HOST | OOB: $OOB_IP | Rack: $RACK"
  echo
  echo "[DISK]"
  if [[ ${#disk_rows[@]} -eq 0 ]]; then
    echo "- No disk faults detected"
  else
    for row in "${disk_rows[@]}"; do
      IFS='|' read -r slot status _serial dev mp safe <<<"$row"
      [[ -z "$dev" ]] && dev="-"
      [[ -z "$mp" ]] && mp="-"
      safe_label="SAFE"
      [[ "$safe" == "false" ]] && safe_label="CHECK"
      printf -- '- Slot %2s %-8s Dev=%-10s Mount=%-12s %s\n' "$slot" "$status" "$dev" "$mp" "$safe_label"
    done
  fi

  print_section() {
    local title="$1"; shift
    local -n arr=$1
    echo
    echo "[$title]"
    if [[ ${#arr[@]} -eq 0 ]]; then
      echo "- No faults detected"
      return
    fi
    for row in "${arr[@]}"; do
      IFS='|' read -r loc status _raw <<<"$row"
      echo "- $loc: $status"
    done
  }

  print_section MEMORY mem_rows
  print_section FAN fan_rows
  print_section PSU psu_rows
fi
