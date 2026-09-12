#!/usr/bin/env bash
set -Eeuo pipefail

RECEIVER_NAME="${CASTBRIDGE_RECEIVER_NAME:-CastBridge}"
AIRPLAY_PORT="${CASTBRIDGE_AIRPLAY_PORT:-7100}"
VIDEO_RTP_PORT="${CASTBRIDGE_RTP_VIDEO_PORT:-5000}"
AUDIO_RTP_PORT="${CASTBRIDGE_RTP_AUDIO_PORT:-5002}"
RUN_DIR="${CASTBRIDGE_RUN_DIR:-/run/castbridge}"
LOG_DIR="${CASTBRIDGE_LOG_DIR:-/var/log/castbridge}"
STATUS_FILE="$RUN_DIR/receiver-status.json"
PID_FILE="$RUN_DIR/receiver.pid"
LOG_FILE="$LOG_DIR/receiver.log"
UXPLAY_PID=""

mkdir -p "$RUN_DIR" "$LOG_DIR"

validate_port() {
  local name="$1" value="$2"
  case "$value" in
    ''|*[!0-9]*) echo "$name 不是有效端口: $value" >&2; exit 2 ;;
  esac
  [ "$value" -ge 1024 ] && [ "$value" -le 65533 ] || {
    echo "$name 必须在 1024-65533 范围内: $value" >&2
    exit 2
  }
}

validate_port CASTBRIDGE_AIRPLAY_PORT "$AIRPLAY_PORT"
validate_port CASTBRIDGE_RTP_VIDEO_PORT "$VIDEO_RTP_PORT"
validate_port CASTBRIDGE_RTP_AUDIO_PORT "$AUDIO_RTP_PORT"

write_status() {
  local state="$1" exit_code="${2:-}" tmp="${STATUS_FILE}.tmp.$$"
  jq -n \
    --arg state "$state" \
    --arg receiver_name "$RECEIVER_NAME" \
    --arg version "${UXPLAY_VERSION:-1.74}" \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson timestamp_epoch "$(date +%s)" \
    --argjson pid "${UXPLAY_PID:-0}" \
    --argjson airplay_port "$AIRPLAY_PORT" \
    --argjson video_rtp_port "$VIDEO_RTP_PORT" \
    --argjson audio_rtp_port "$AUDIO_RTP_PORT" \
    --arg exit_code "$exit_code" \
    '{
      state: $state,
      receiver_name: $receiver_name,
      engine: "UxPlay",
      engine_version: $version,
      timestamp: $timestamp,
      timestamp_epoch: $timestamp_epoch,
      pid: $pid,
      airplay_port: $airplay_port,
      video_rtp_port: $video_rtp_port,
      audio_rtp_port: $audio_rtp_port,
      exit_code: (if $exit_code == "" then null else ($exit_code | tonumber) end)
    }' > "$tmp"
  mv -f "$tmp" "$STATUS_FILE"
}

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  if [ -n "$UXPLAY_PID" ] && kill -0 "$UXPLAY_PID" 2>/dev/null; then
    kill -TERM "$UXPLAY_PID" 2>/dev/null || true
    wait "$UXPLAY_PID" 2>/dev/null || true
  fi
  rm -f "$PID_FILE"
  write_status stopped "$rc" || true
  exit "$rc"
}
trap cleanup EXIT INT TERM

VIDEO_PIPELINE="config-interval=1 ! udpsink host=127.0.0.1 port=${VIDEO_RTP_PORT} sync=false async=false"
AUDIO_PIPELINE="pt=96 ! udpsink host=127.0.0.1 port=${AUDIO_RTP_PORT} sync=false async=false"

printf '[receiver] 启动 UxPlay %s，设备名: %s\n' "${UXPLAY_VERSION:-1.74}" "$RECEIVER_NAME"
printf '[receiver] AirPlay TCP/UDP 端口: %s-%s\n' "$AIRPLAY_PORT" "$((AIRPLAY_PORT + 2))"
printf '[receiver] RTP 输出: video=%s audio=%s\n' "$VIDEO_RTP_PORT" "$AUDIO_RTP_PORT"

/usr/local/bin/uxplay \
  -n "$RECEIVER_NAME" \
  -nh \
  -p "$AIRPLAY_PORT" \
  -vrtp "$VIDEO_PIPELINE" \
  -artp "$AUDIO_PIPELINE" \
  > >(tee -a "$LOG_FILE") 2>&1 &
UXPLAY_PID=$!
printf '%s\n' "$UXPLAY_PID" > "$PID_FILE"
write_status ready

while kill -0 "$UXPLAY_PID" 2>/dev/null; do
  sleep 2
  write_status ready
 done

set +e
wait "$UXPLAY_PID"
RC=$?
set -e
write_status stopped "$RC"
exit "$RC"
