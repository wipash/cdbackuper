#!/usr/bin/env bash
set -Eeuo pipefail


VERSION="1.1.0"
# --- Configuration via env (with defaults) -------------------------------
DATA_ROOT="${DATA_ROOT:-/data}"         # PVC mount
DEVICE_GLOB="${DEVICE_GLOB:-/dev/sr*}"  # CD/DVD devices to watch
RETRIES="${RETRIES:-3}"                 # ddrescue retry passes
TIMEOUT="${TIMEOUT:-7200}"              # seconds, per-disc guard
EXTRACT_FILES="${EXTRACT_FILES:-true}"  # true|false
POLL_SECS="${POLL_SECS:-5}"
NODE_NAME="${NODE_NAME:-$(cat /etc/hostname)}"
# ddrescue limits for badly damaged disks (applied to retry pass only)
MAX_READ_ERRORS="${MAX_READ_ERRORS:-15000}"  # Stop after N read errors
MAX_BAD_AREAS="${MAX_BAD_AREAS:-30}"         # Stop after N bad areas
SECTOR_TIMEOUT="${SECTOR_TIMEOUT:-600}"       # Timeout per sector (seconds)
# -------------------------------------------------------------------------

mkdir -p /var/run/cd-import /mnt/work

# FIX: Ensure /dev/fd exists for process substitution (missing in newer Talos/containerd)
if [[ ! -e /dev/fd ]]; then
  ln -sf /proc/self/fd /dev/fd
fi

# Enhanced logging with device context
log() {
  local dev_id="${1:-}"
  shift || true
  if [[ -n "$dev_id" ]]; then
    echo "[$(date -u +%FT%TZ)] [$NODE_NAME:$dev_id] $*"
  else
    echo "[$(date -u +%FT%TZ)] [$NODE_NAME] $*"
  fi
}

# FIX #4: Verify NFS mount at startup
if ! mountpoint -q "$DATA_ROOT"; then
  log "" "FATAL: $DATA_ROOT is not mounted! Cannot proceed."
  exit 1
fi
log "" "✓ Confirmed $DATA_ROOT is mounted"

has_media() {
  local dev="$1"
  # ID_CDROM_MEDIA=1 is a good signal; fallback to blkid TYPE
  if udevadm info --query=property --name="$dev" 2>/dev/null | grep -q '^ID_CDROM_MEDIA=1$'; then
    return 0
  fi
  if blkid -o value -s TYPE "$dev" &>/dev/null; then
    return 0
  fi
  return 1
}

disc_label() {
  local dev="$1"
  blkid -o value -s LABEL "$dev" 2>/dev/null || echo "unknown"
}

disc_uuid() {
  local dev="$1"
  blkid -o value -s UUID "$dev" 2>/dev/null || echo ""
}

dump_metadata() {
  local dev="$1" dest="$2"
  blkid -o export "$dev" > "$dest/blkid.txt" 2>/dev/null || true
}

iso_info_dump() {
  local iso="$1" dest="$2"
  isoinfo -d -i "$iso" > "$dest/isoinfo.txt" 2>/dev/null || true
}

convert_psd_previews() {
  local files_dir="$1"
  local dev_name="$2"
  local psd_count=0

  # Count PSDs first
  psd_count=$(find "$files_dir" -type f -iname "*.psd" 2>/dev/null | wc -l)

  if [[ $psd_count -eq 0 ]]; then
    return 0
  fi

  log "$dev_name" "🖼️  Found $psd_count PSD file(s), generating jpgs..."

  # Convert each PSD
  local converted_count=0
  while IFS= read -r -d '' psd; do
    # Remove any case variation of .psd extension
    local jpg
    jpg="$(sed 's/\.[pP][sS][dD]$//' <<< "$psd").jpg"
    if convert "${psd}[0]" -quality 85 "$jpg" 2>/dev/null; then
      # Match JPG timestamp to PSD
      touch -r "$psd" "$jpg" 2>/dev/null || true
      converted_count=$((converted_count + 1))
    else
      log "$dev_name" "⚠️  Failed to convert: $(basename "$psd")"
    fi
  done < <(find "$files_dir" -type f -iname "*.psd" -print0 2>/dev/null)

  log "$dev_name" "✓ PSD conversion complete ($converted_count/$psd_count)"
}

make_status() {
  local dest="$1" status="$2" msg="$3" iso="$4" started="$5" finished="$6" uuid="$7" is_retry="$8" discord_msg_id="${9:-}"
  local rescued="" rescued_pct="" read_errors=""

  # Parse job log (contains ddrescue output and all other logs)
  if [[ -f "$dest/job.log" ]]; then
    # Get the last "rescued:" line (final status) - match only "rescued:", not "pct rescued:"
    rescued=$(grep '^ *rescued:' "$dest/job.log" | tail -1 | awk '{print $2, $3}' | tr -d ',' || echo "unknown")
    # Get percentage - strip trailing comma
    rescued_pct=$(grep 'pct rescued:' "$dest/job.log" | tail -1 | awk '{print $3}' | tr -d ',' || echo "0%")
    # Read errors is field 6, need to strip trailing comma
    read_errors=$(grep 'read errors:' "$dest/job.log" | tail -1 | awk '{print $6}' | tr -d ',' || echo "0")
  fi

  # Track retry attempts and nodes
  local retry_nodes=""
  if [[ -f "$dest/status.json" ]]; then
    # Preserve previous nodes list
    retry_nodes=$(jq -r '.retry_nodes // [] | join(",")' "$dest/status.json" 2>/dev/null || echo "")
  fi

  if [[ "$is_retry" == "true" ]]; then
    # Append current node to retry list
    if [[ -n "$retry_nodes" ]]; then
      retry_nodes="${retry_nodes},${NODE_NAME}"
    else
      retry_nodes="${NODE_NAME}"
    fi
  fi

  jq -n --arg node "$NODE_NAME" \
        --arg status "$status" \
        --arg message "$msg" \
        --arg iso "$(basename "$iso")" \
        --arg started "$started" \
        --arg finished "$finished" \
        --arg uuid "$uuid" \
        --arg rescued "$rescued" \
        --arg rescued_pct "$rescued_pct" \
        --arg read_errors "$read_errors" \
        --arg is_retry "$is_retry" \
        --arg retry_nodes "$retry_nodes" \
        --arg discord_message_id "$discord_msg_id" \
        '{node:$node,status:$status,message:$message,iso:$iso,uuid:$uuid,started:$started,finished:$finished,is_retry:($is_retry=="true"),retry_nodes:(if $retry_nodes == "" then [] else ($retry_nodes|split(",")) end),ddrescue:{rescued:$rescued,rescued_pct:$rescued_pct,read_errors:$read_errors},discord_message_id:$discord_message_id}' \
    > "$dest/status.json"
}

send_discord_start_notification() {
  local label="$1"
  local outdir="$2"
  local dev_name="$3"
  local is_retry="${4:-false}"

  # Skip if webhook not configured
  [[ -z "${DISCORD_WEBHOOK_URL:-}" ]] && return 0

  local retry_info=""
  if [[ "$is_retry" == "true" ]]; then
    local retry_nodes=""
    if [[ -f "$outdir/status.json" ]]; then
      retry_nodes=$(jq -r '.retry_nodes // [] | join(", ")' "$outdir/status.json" 2>/dev/null || echo "")
    fi
    if [[ -n "$retry_nodes" ]]; then
      retry_info=$'\n🔄 **Retry attempt** (Previous: '"$retry_nodes"')'
    else
      retry_info=$'\n🔄 **Retry attempt**'
    fi
  fi

  local description
  description=$(printf "**Node:** %s  //  %s\n**Disc Label:** %s%s\n\n💬 *Reply to add disc label*" \
    "$NODE_NAME" "$dev_name" "$label" "$retry_info")

  local payload
  payload=$(jq -n \
    --arg username "CD Archiver" \
    --arg title "💿 Processing CD..." \
    --arg description "$description" \
    --argjson color 16776960 \
    --arg footer "$(basename "$outdir")" \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      username: $username,
      embeds: [{
        title: $title,
        description: $description,
        color: $color,
        footer: {text: $footer},
        timestamp: $timestamp
      }]
    }')

  local response
  response=$(curl -s -X POST "${DISCORD_WEBHOOK_URL}?wait=true" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>/dev/null || echo "")

  # Extract message ID from response
  local msg_id=""
  if [[ -n "$response" ]]; then
    msg_id=$(echo "$response" | jq -r '.id // empty' 2>/dev/null || echo "")
  fi

  echo "$msg_id"
}

update_discord_notification() {
  local message_id="$1"
  local status="$2"
  local label="$3"
  local rescued_pct="$4"
  local read_errors="$5"
  local outdir="$6"
  local dev_name="$7"
  local is_retry="${8:-false}"

  # Skip if webhook not configured
  [[ -z "${DISCORD_WEBHOOK_URL:-}" ]] && return 0

  local color emoji title description retry_info=""
  local unc_path
  unc_path="\\\\brian\\Backup\\Maurice\\cd-archive\\$(basename "$outdir")"

  # Add retry information if this is a duplicate disc
  if [[ "$is_retry" == "true" ]]; then
    local retry_nodes=""
    if [[ -f "$outdir/status.json" ]]; then
      retry_nodes=$(jq -r '.retry_nodes // [] | join(", ")' "$outdir/status.json" 2>/dev/null || echo "")
    fi
    if [[ -n "$retry_nodes" ]]; then
      retry_info=$'\n🔄 **Retry attempt** (Previous: '"$retry_nodes"')'
    else
      retry_info=$'\n🔄 **Retry attempt**'
    fi
  fi

  if [[ "$status" == "success" ]]; then
    color="3066993"  # Green
    emoji="✅"
    title="CD Archived Successfully"
    description=$(printf "**Node:** %s  //  %s\n**Label:** %s\n**Rescued:** %s%s\n**Path:** \`%s\`\n\n💬 *Reply to add disc label*" \
      "$NODE_NAME" "$dev_name" "$label" "$rescued_pct" "$retry_info" "$unc_path")
  else
    color="15158332"  # Red
    emoji="❌"
    title="CD Archive Failed/Partial"

    local log_tail=""
    if [[ -f "$outdir/job.log" ]]; then
      log_tail=$(tail -5 "$outdir/job.log" || true)
    fi

    description=$(printf "**Node:** %s  //  %s\n**Label:** %s\n**Rescued:** %s\n**Read Errors:** %s%s\n**Path:** \`%s\`\n\n**Last log lines:**\n\`\`\`\n%s\n\`\`\`" \
      "$NODE_NAME" "$dev_name" "$label" "$rescued_pct" "$read_errors" "$retry_info" "$unc_path" "$log_tail")
  fi

  local payload
  payload=$(jq -n \
    --arg username "CD Archiver" \
    --arg title "$emoji $title" \
    --arg description "$description" \
    --argjson color "$color" \
    --arg footer "$(basename "$outdir")" \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      username: $username,
      embeds: [{
        title: $title,
        description: $description,
        color: $color,
        footer: {text: $footer},
        timestamp: $timestamp
      }]
    }')

  # Try to update existing message, fall back to new POST
  if [[ -n "$message_id" ]]; then
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X PATCH \
      "${DISCORD_WEBHOOK_URL}/messages/${message_id}" \
      -H "Content-Type: application/json" \
      -d "$payload" 2>/dev/null || echo "000")

    if [[ "$http_code" =~ ^2 ]]; then
      return 0
    fi
  fi

  # Fallback: send as new message
  curl -s -X POST "${DISCORD_WEBHOOK_URL}" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>/dev/null || true
}

process_disc() {
  local dev="$1"
  local dev_name
  dev_name=$(basename "$dev")
  local started finished label uuid outdir iso rc=0 timeout_pid is_retry=false job_log discord_message_id=""

  # FIX #3: Clean mount point before use
  umount /mnt/work 2>/dev/null || true

  # FIX #3: Setup trap for cleanup
  cleanup_mount() {
    umount /mnt/work 2>/dev/null || true
  }
  trap cleanup_mount EXIT INT TERM

  label="$(disc_label "$dev" | tr -cd '[:alnum:]_. -' | tr ' ' '_')"
  uuid="$(disc_uuid "$dev" | tr -cd '[:alnum:]-')"
  started="$(date -u +%Y-%m-%dT%H%M%SZ)"

  # Skip generic/meaningless labels when naming directories
  case "$label" in
    NEW|My_Disc|unknown)
      label_suffix=""
      ;;
    *)
      label_suffix="_${label}"
      ;;
  esac

  if [[ -n "$uuid" ]]; then
    outdir="$DATA_ROOT/${uuid}${label_suffix}"
  else
    outdir="$DATA_ROOT/${started}${label_suffix}"
  fi

  # Detect duplicate disc by checking if output directory already exists
  if [[ -d "$outdir" && (-f "$outdir/status.json" || -f "$outdir/ddrescue.mapfile") ]]; then
    is_retry=true
    # Backup previous job log if it exists (before we start redirecting to it)
    if [[ -f "$outdir/job.log" ]]; then
      cp "$outdir/job.log" "$outdir/job.log.backup-$(date -u +%Y%m%d-%H%M%S)"
    fi
  else
    mkdir -p "$outdir"
  fi

  # Redirect all subsequent output to job.log (and still show in stdout for kubectl logs)
  job_log="$outdir/job.log"
  exec > >(tee -a "$job_log") 2>&1

  # Log initialization info (now captured in job.log)
  if [[ "$is_retry" == "true" ]]; then
    log "$dev_name" "════════════════════════════════════════"
    log "$dev_name" "🔄 DUPLICATE DETECTED - Retrying recovery"
    log "$dev_name" "   Label: '$label'"
    log "$dev_name" "   Output: $(basename "$outdir")"

    # Read previous attempt info
    if [[ -f "$outdir/status.json" ]]; then
      local prev_nodes prev_pct
      prev_nodes=$(jq -r '.node // "unknown"' "$outdir/status.json" 2>/dev/null || echo "unknown")
      prev_pct=$(jq -r '.ddrescue.rescued_pct // "unknown"' "$outdir/status.json" 2>/dev/null || echo "unknown")
      log "$dev_name" "   Previous: Node=$prev_nodes, Rescued=$prev_pct"
    fi

    log "$dev_name" "   Current: Node=$NODE_NAME"
    log "$dev_name" "   Will resume using existing mapfile"
    log "$dev_name" "════════════════════════════════════════"
  else
    log "$dev_name" "════════════════════════════════════════"
    log "$dev_name" "🔵 STARTED - Label: '$label'"
    log "$dev_name" "   Output: $(basename "$outdir")"
    log "$dev_name" "════════════════════════════════════════"
  fi

  dump_metadata "$dev" "$outdir"

  iso="$outdir/disc.iso"
  touch "$outdir/.in-progress"

  # Send start notification to Discord and capture message ID
  discord_message_id=$(send_discord_start_notification "$label" "$outdir" "$dev_name" "$is_retry")
  if [[ -n "$discord_message_id" ]]; then
    log "$dev_name" "📨 Discord start notification sent (msg ID: $discord_message_id)"
  fi

  # Preserve existing retry_nodes before overwriting status.json
  local existing_retry_nodes="[]"
  if [[ "$is_retry" == "true" && -f "$outdir/status.json" ]]; then
    existing_retry_nodes=$(jq -c '.retry_nodes // []' "$outdir/status.json" 2>/dev/null || echo "[]")
  fi

  # Write early status.json so the bot knows processing is in progress
  jq -n --arg node "$NODE_NAME" \
        --arg status "in_progress" \
        --arg uuid "$uuid" \
        --arg started "$started" \
        --arg is_retry "$is_retry" \
        --arg discord_message_id "$discord_message_id" \
        --argjson retry_nodes "$existing_retry_nodes" \
        '{node:$node,status:$status,uuid:$uuid,started:$started,is_retry:($is_retry=="true"),discord_message_id:$discord_message_id,retry_nodes:$retry_nodes}' \
    > "$outdir/status.json"

  # FIX #2: Track timeout guard PID so we can kill it later
  (
    sleep "$TIMEOUT"
    if [[ -f "$outdir/.in-progress" ]]; then
      log "$dev_name" "⏱️  TIMEOUT hit, stopping ddrescue"
      pkill -f "ddrescue .* $dev" || true
    fi
  ) &
  timeout_pid=$!

  # ddrescue fast pass + a few retries
  log "$dev_name" "📀 Running ddrescue (fast pass + $RETRIES retries)..."
  set +e
  # Fast pass: no limits, just skip bad sectors quickly
  ddrescue -d -b 2048 -n "$dev" "$iso" "$outdir/ddrescue.mapfile" 2>&1 | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | cat -s
  # Retry pass: apply limits to prevent hanging on severely damaged disks
  ddrescue -d -R -b 2048 -r"$RETRIES" \
    --max-read-errors=+"$MAX_READ_ERRORS" \
    --max-bad-areas=+"$MAX_BAD_AREAS" \
    --timeout="${SECTOR_TIMEOUT}s" \
    "$dev" "$iso" "$outdir/ddrescue.mapfile" 2>&1 | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | cat -s
  rc=$?
  set -e

  # FIX #2: Kill timeout guard if still running
  if kill -0 "$timeout_pid" 2>/dev/null; then
    kill "$timeout_pid" 2>/dev/null || true
    wait "$timeout_pid" 2>/dev/null || true
  fi

  log "$dev_name" "📝 ddrescue completed with exit code: $rc"

  iso_info_dump "$iso" "$outdir"

  # FIX #5: Try to extract files (support both ISO 9660 and UDF formats)
  local files_extracted=false
  local mount_error=""
  if [[ "${EXTRACT_FILES}" == "true" && -s "$iso" ]]; then
    log "$dev_name" "📂 Extracting files from ISO..."
    mkdir -p "$outdir/files"

    # Try mounting (works for both ISO 9660 and UDF formats)
    mount_error=$(mount -o loop,ro "$iso" /mnt/work 2>&1) || true
    if mountpoint -q /mnt/work; then
      rsync -a /mnt/work/ "$outdir/files/" || true
      umount /mnt/work || true
      files_extracted=true
      log "$dev_name" "✓ Files extracted successfully"

      # Generate PSD previews
      convert_psd_previews "$outdir/files" "$dev_name"
    else
      log "$dev_name" "⚠️  Could not mount ISO - may be corrupt or unsupported format"
      if [[ -n "$mount_error" ]]; then
        log "$dev_name" "   Mount error: ${mount_error:0:200}"
        echo "$mount_error" > "$outdir/mount-error.txt"
      fi
    fi
  fi

  finished="$(date -u +%Y-%m-%dT%H%M%SZ)"

  # Auto-delete ISO on successful extraction
  if [[ "$rc" -eq 0 && "$files_extracted" == "true" && "${DELETE_ISO_ON_SUCCESS:-true}" == "true" ]]; then
    log "$dev_name" "🗑️  Deleting ISO to save space"
    rm -f "$iso"
  fi

  # Parse rescue stats for notification
  local rescued_pct="unknown"
  local rescued_pct_num=0
  local read_errors="0"
  if [[ -f "$outdir/job.log" ]]; then
    # FIX: Strip trailing comma from rescued_pct
    rescued_pct=$(grep 'pct rescued:' "$outdir/job.log" | tail -1 | awk '{print $3}' | tr -d ',' || echo "unknown")
    # Extract numeric value for comparison (e.g., "99.5%" -> 99.5)
    rescued_pct_num="${rescued_pct%\%}"
    # Ensure it's actually numeric, fall back to 0 if parsing failed
    if ! [[ "$rescued_pct_num" =~ ^[0-9]+\.?[0-9]*$ ]]; then
      rescued_pct_num=0
    fi
    # Read errors is field 6, need to strip trailing comma
    read_errors=$(grep 'read errors:' "$outdir/job.log" | tail -1 | awk '{print $6}' | tr -d ',' || echo "0")
  fi

  # Success criteria:
  # - If EXTRACT_FILES=true: require files to be extracted successfully (with >95% rescued as fallback)
  # - If EXTRACT_FILES=false: require ddrescue exit code 0
  local is_success=false
  if [[ "${EXTRACT_FILES}" == "true" ]]; then
    # Success if files extracted AND (ddrescue succeeded OR rescued >= 95%)
    if [[ "$files_extracted" == "true" ]]; then
      if [[ $rc -eq 0 ]] || [[ $(echo "$rescued_pct_num >= 95" | bc -l 2>/dev/null || echo 0) -eq 1 ]]; then
        is_success=true
      fi
    fi
  else
    # Just wanted the ISO, so success if ddrescue succeeded
    if [[ $rc -eq 0 ]]; then
      is_success=true
    fi
  fi

  # Check if a user label was added during processing
  local user_label=""
  if [[ -f "$outdir/label.txt" ]]; then
    user_label=$(head -1 "$outdir/label.txt" | tr -cd '[:alnum:]_. -' | tr ' ' '_')
  fi
  local display_label="${user_label:-$label}"

  # Rename folder BEFORE notification so embed shows correct path
  if [[ -n "$user_label" ]]; then
    local new_outdir
    if [[ -n "$uuid" ]]; then
      new_outdir="$DATA_ROOT/${uuid}_${user_label}"
    else
      new_outdir="$DATA_ROOT/${started}_${user_label}"
    fi
    if [[ "$outdir" != "$new_outdir" && ! -d "$new_outdir" ]]; then
      if mv "$outdir" "$new_outdir" 2>/dev/null; then
        log "$dev_name" "📁 Renamed to $(basename "$new_outdir")"
        outdir="$new_outdir"
      else
        log "$dev_name" "⚠️ Could not rename folder, continuing with original name"
      fi
    fi
  fi

  if [[ "$is_success" == "true" ]]; then
    make_status "$outdir" "success" "Recovered successfully" "$iso" "$started" "$finished" "$uuid" "$is_retry" "$discord_message_id"
    update_discord_notification "$discord_message_id" "success" "$display_label" "$rescued_pct" "$read_errors" "$outdir" "$dev_name" "$is_retry"
    log "$dev_name" "════════════════════════════════════════"
    log "$dev_name" "✅ SUCCESS - Rescued: $rescued_pct"
    if [[ "$is_retry" == "true" ]]; then
      log "$dev_name" "   🔄 This was a retry attempt"
    fi
    log "$dev_name" "════════════════════════════════════════"
  else
    make_status "$outdir" "partial_or_failed" "ddrescue exited rc=$rc after retries" "$iso" "$started" "$finished" "$uuid" "$is_retry" "$discord_message_id"
    update_discord_notification "$discord_message_id" "failure" "$display_label" "$rescued_pct" "$read_errors" "$outdir" "$dev_name" "$is_retry"
    log "$dev_name" "════════════════════════════════════════"
    log "$dev_name" "❌ FAILED - Rescued: $rescued_pct, Errors: $read_errors"
    if [[ "$is_retry" == "true" ]]; then
      log "$dev_name" "   🔄 This was a retry attempt - try another node/drive?"
    fi
    log "$dev_name" "   See: $(basename "$outdir")/status.json"
    log "$dev_name" "════════════════════════════════════════"
  fi

  rm -f "$outdir/.in-progress"
  sync || true

  # Eject disc
  log "$dev_name" "⏏️  Ejecting disc..."
  if eject "$dev" 2>/dev/null; then
    # Wait for device to actually report no media (max 30s)
    local wait_count=0
    while has_media "$dev" && [[ $wait_count -lt 30 ]]; do
      sleep 1
      wait_count=$((wait_count + 1))
    done
    if [[ $wait_count -ge 30 ]]; then
      log "$dev_name" "⚠️  Device still reporting media after 30s"
    fi
    # Extra safety buffer
    sleep 2
  else
    log "$dev_name" "⚠️  Eject command failed"
  fi

  # Cleanup trap on normal exit
  trap - EXIT INT TERM
  cleanup_mount
}

# FIX #6: Track background jobs to avoid zombie accumulation
declare -A active_jobs

# Eject all drives at startup to clear any previously inserted discs
log "" "⏏️  Ejecting all drives at startup..."
for dev in $DEVICE_GLOB; do
  if [[ -e "$dev" ]]; then
    eject "$dev" 2>/dev/null || true
    log "" "  Ejected $(basename "$dev")"
  fi
done

# Wait for all drives to finish ejecting before starting main loop
log "" "⏳ Waiting for all drives to clear..."
for dev in $DEVICE_GLOB; do
  if [[ -e "$dev" ]]; then
    wait_count=0
    while has_media "$dev" && [[ $wait_count -lt 30 ]]; do
      sleep 1
      wait_count=$((wait_count + 1))
    done
    if [[ $wait_count -ge 30 ]]; then
      log "" "⚠️  $(basename "$dev") still reporting media after 30s - proceeding anyway"
    fi
  fi
done
log "" "✓ All drives cleared"

# Main loop
log "" "🚀 Starting CD watcher v$VERSION - monitoring: $DEVICE_GLOB"
log "" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

while true; do
  # Clean up finished jobs
  for pid in "${!active_jobs[@]}"; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null || true
      finished_dev="${active_jobs[$pid]}"
      unset 'active_jobs[$pid]'
      log "$(basename "$finished_dev")" "Job completed (PID: $pid)"
    fi
  done

  for dev in $DEVICE_GLOB; do
    [[ -e "$dev" ]] || continue
    lock="/var/run/cd-import/$(basename "$dev").lock"

    if has_media "$dev"; then
      # FIX #1: Atomic lock using mkdir instead of touch + check
      if mkdir "$lock" 2>/dev/null; then
        (
          process_disc "$dev" || true
          # Keep lock for a moment to prevent immediate re-detection
          sleep 3
          rmdir "$lock" 2>/dev/null || true
        ) &
        # FIX #6: Track the background job PID
        active_jobs[$!]="$dev"
        log "$(basename "$dev")" "Spawned job PID $! (active jobs: ${#active_jobs[@]})"
      fi
    fi
  done
  sleep "$POLL_SECS"
done
