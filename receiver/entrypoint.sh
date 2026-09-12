#!/usr/bin/env bash
set -Eeuo pipefail

RECEIVER_NAME="${CASTBRIDGE_RECEIVER_NAME:-CastBridge}"
AIRPLAY_PORT="${CASTBRIDGE_AIRPLAY_PORT:-7100}"
AIRPLAY_FPS="${CASTBRIDGE_AIRPLAY_FPS:-60}"
VIDEO_RTP_PORT="${CASTBRIDGE_RTP_VIDEO_PORT:-5000}"
AUDIO_RTP_PORT="${CASTBRIDGE_RTP_AUDIO_PORT:-5002}"
MDNS_MODE_REQUESTED="${CASTBRIDGE_MDNS_MODE:-auto}"
HOST_DBUS_SOCKET="${CASTBRIDGE_HOST_DBUS_SOCKET:-/host/run/dbus/system_bus_socket}"
RUN_DIR="${CASTBRIDGE_RUN_DIR:-/run/castbridge}"
LOG_DIR="${CASTBRIDGE_LOG_DIR:-/var/log/castbridge}"
STATUS_FILE="$RUN_DIR/receiver-status.json"
PID_FILE="$RUN_DIR/receiver.pid"
DISCOVERY_FILE="$RUN_DIR/receiver-discovery.ready"
LOG_FILE="$LOG_DIR/receiver.log"
UXPLAY_PID=""
MDNS_MODE_RESOLVED="unknown"
EMBEDDED_MDNS=0
DISCOVERY_READY=0

mkdir -p "$RUN_DIR" "$LOG_DIR" /run/dbus /run/avahi-daemon
rm -f "$DISCOVERY_FILE"

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

validate_fps() {
  case "$AIRPLAY_FPS" in
    ''|*[!0-9]*) echo "CASTBRIDGE_AIRPLAY_FPS 不是有效帧率: $AIRPLAY_FPS" >&2; exit 2 ;;
  esac
  [ "$AIRPLAY_FPS" -ge 1 ] && [ "$AIRPLAY_FPS" -le 255 ] || {
    echo "CASTBRIDGE_AIRPLAY_FPS 必须在 1-255 范围内: $AIRPLAY_FPS" >&2
    exit 2
  }
}

validate_mdns_mode() {
  case "$MDNS_MODE_REQUESTED" in
    auto|host|embedded) ;;
    *)
      echo "CASTBRIDGE_MDNS_MODE 仅支持 auto / host / embedded: $MDNS_MODE_REQUESTED" >&2
      exit 2
      ;;
  esac
}

validate_port CASTBRIDGE_AIRPLAY_PORT "$AIRPLAY_PORT"
validate_port CASTBRIDGE_RTP_VIDEO_PORT "$VIDEO_RTP_PORT"
validate_port CASTBRIDGE_RTP_AUDIO_PORT "$AUDIO_RTP_PORT"
validate_fps
validate_mdns_mode

write_status() {
  local state="$1" exit_code="${2:-}" tmp="${STATUS_FILE}.tmp.$$"
  jq -n \
    --arg state "$state" \
    --arg receiver_name "$RECEIVER_NAME" \
    --arg version "${UXPLAY_VERSION:-1.73.7}" \
    --arg mdns_mode "$MDNS_MODE_RESOLVED" \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson timestamp_epoch "$(date +%s)" \
    --argjson pid "${UXPLAY_PID:-0}" \
    --argjson airplay_port "$AIRPLAY_PORT" \
    --argjson max_fps "$AIRPLAY_FPS" \
    --argjson video_rtp_port "$VIDEO_RTP_PORT" \
    --argjson audio_rtp_port "$AUDIO_RTP_PORT" \
    --argjson discovery_ready "$DISCOVERY_READY" \
    --arg exit_code "$exit_code" \
    '{
      state: $state,
      receiver_name: $receiver_name,
      engine: "UxPlay",
      engine_version: $version,
      mdns_mode: $mdns_mode,
      discovery_ready: ($discovery_ready == 1),
      timestamp: $timestamp,
      timestamp_epoch: $timestamp_epoch,
      pid: $pid,
      airplay_port: $airplay_port,
      max_fps: $max_fps,
      video_rtp_port: $video_rtp_port,
      audio_rtp_port: $audio_rtp_port,
      exit_code: (if $exit_code == "" then null else ($exit_code | tonumber) end)
    }' > "$tmp"
  mv -f "$tmp" "$STATUS_FILE"
}

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  DISCOVERY_READY=0
  rm -f "$DISCOVERY_FILE"
  if [ -n "$UXPLAY_PID" ] && kill -0 "$UXPLAY_PID" 2>/dev/null; then
    kill -TERM "$UXPLAY_PID" 2>/dev/null || true
    wait "$UXPLAY_PID" 2>/dev/null || true
  fi
  if [ "$EMBEDDED_MDNS" = "1" ]; then
    avahi-daemon --kill >/dev/null 2>&1 || true
  fi
  rm -f "$PID_FILE"
  write_status stopped "$rc" || true
  exit "$rc"
}
trap cleanup EXIT INT TERM

host_avahi_available() {
  local reply
  [ -S "$HOST_DBUS_SOCKET" ] || return 1
  command -v dbus-send >/dev/null 2>&1 || return 1

  reply="$(
    DBUS_SYSTEM_BUS_ADDRESS="unix:path=${HOST_DBUS_SOCKET}" \
      dbus-send --system --print-reply \
        --dest=org.freedesktop.DBus \
        /org/freedesktop/DBus \
        org.freedesktop.DBus.NameHasOwner \
        string:org.freedesktop.Avahi \
        2>/dev/null || true
  )"
  printf '%s\n' "$reply" | grep -q 'boolean true'
}

start_embedded_mdns() {
  unset DBUS_SYSTEM_BUS_ADDRESS || true
  dbus-uuidgen --ensure=/etc/machine-id >/dev/null 2>&1 || true

  if [ ! -S /run/dbus/system_bus_socket ]; then
    dbus-daemon --system --fork
  fi

  if ! avahi-daemon --daemonize --no-chroot; then
    echo "[receiver] 内置 Avahi 启动失败；请检查 UDP 5353 占用或改用 CASTBRIDGE_MDNS_MODE=host" >&2
    exit 1
  fi

  EMBEDDED_MDNS=1
  MDNS_MODE_RESOLVED="embedded"
  printf '[receiver] mDNS 模式: embedded（Receiver 内置 Avahi，UDP 5353）\n'
}

configure_mdns() {
  case "$MDNS_MODE_REQUESTED" in
    host)
      if ! host_avahi_available; then
        echo "[receiver] CASTBRIDGE_MDNS_MODE=host，但宿主机 Avahi/system D-Bus 不可用" >&2
        exit 1
      fi
      export DBUS_SYSTEM_BUS_ADDRESS="unix:path=${HOST_DBUS_SOCKET}"
      MDNS_MODE_RESOLVED="host"
      printf '[receiver] mDNS 模式: host（复用宿主机 Avahi）\n'
      ;;
    embedded)
      start_embedded_mdns
      ;;
    auto)
      if host_avahi_available; then
        export DBUS_SYSTEM_BUS_ADDRESS="unix:path=${HOST_DBUS_SOCKET}"
        MDNS_MODE_RESOLVED="host"
        printf '[receiver] mDNS 自动检测: 宿主机 Avahi 可用，使用 host 模式\n'
      else
        printf '[receiver] mDNS 自动检测: 未发现可用宿主机 Avahi，使用 embedded 模式\n'
        start_embedded_mdns
      fi
      ;;
  esac
}

wait_for_airplay_discovery() {
  local attempt output
  command -v avahi-browse >/dev/null 2>&1 || {
    echo "[receiver] 缺少 avahi-browse，无法验证 AirPlay DNS-SD 注册" >&2
    return 1
  }

  for attempt in $(seq 1 15); do
    if ! kill -0 "$UXPLAY_PID" 2>/dev/null; then
      return 1
    fi

    output="$(timeout 3 avahi-browse -rt _airplay._tcp 2>/dev/null || true)"
    if printf '%s\n' "$output" | grep -Fq "$RECEIVER_NAME"; then
      DISCOVERY_READY=1
      : > "$DISCOVERY_FILE"
      printf '[receiver] AirPlay DNS-SD 已注册: %s (_airplay._tcp)\n' "$RECEIVER_NAME"
      return 0
    fi
    sleep 1
  done

  echo "[receiver] UxPlay 已启动，但 15 秒内未发现 ${RECEIVER_NAME} 的 _airplay._tcp 注册" >&2
  return 1
}

VIDEO_PIPELINE="config-interval=1 ! udpsink host=127.0.0.1 port=${VIDEO_RTP_PORT} sync=false async=false"
AUDIO_PIPELINE="pt=96 ! udpsink host=127.0.0.1 port=${AUDIO_RTP_PORT} sync=false async=false"

printf '[receiver] 启动 UxPlay %s，设备名: %s\n' "${UXPLAY_VERSION:-1.73.7}" "$RECEIVER_NAME"
printf '[receiver] AirPlay TCP/UDP 端口: %s-%s\n' "$AIRPLAY_PORT" "$((AIRPLAY_PORT + 2))"
printf '[receiver] AirPlay 最大帧率: %s fps\n' "$AIRPLAY_FPS"
printf '[receiver] RTP 输出: video=%s audio=%s\n' "$VIDEO_RTP_PORT" "$AUDIO_RTP_PORT"
printf '[receiver] mDNS 请求模式: %s\n' "$MDNS_MODE_REQUESTED"

configure_mdns
write_status starting

/usr/local/bin/uxplay \
  -n "$RECEIVER_NAME" \
  -nh \
  -p "$AIRPLAY_PORT" \
  -fps "$AIRPLAY_FPS" \
  -vrtp "$VIDEO_PIPELINE" \
  -artp "$AUDIO_PIPELINE" \
  > >(tee -a "$LOG_FILE") 2>&1 &
UXPLAY_PID=$!
printf '%s\n' "$UXPLAY_PID" > "$PID_FILE"
write_status starting

if ! wait_for_airplay_discovery; then
  write_status discovery_failed 1
  exit 1
fi
write_status ready

while kill -0 "$UXPLAY_PID" 2>/dev/null; do
  sleep 2
  write_status ready
done

set +e
wait "$UXPLAY_PID"
RC=$?
set -e
DISCOVERY_READY=0
rm -f "$DISCOVERY_FILE"
write_status stopped "$RC"
exit "$RC"
