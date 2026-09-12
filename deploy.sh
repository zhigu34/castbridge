#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

ENV_FILE="$ROOT_DIR/.env"
ENV_EXAMPLE="$ROOT_DIR/.env.example"
BUILD_LOG="$ROOT_DIR/logs/deploy-build.log"
UP_LOG="$ROOT_DIR/logs/deploy-up.log"
PREFLIGHT_LOG="$ROOT_DIR/logs/deploy-preflight.log"
BUILD_STATE_FILE="$ROOT_DIR/run/deploy-build-state.env"
CHECK_ONLY=0
NO_BUILD=0
NO_UXPLAY_DOWNLOAD=0
REBUILD_ALL=0

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'USAGE'
CastBridge 一键部署脚本

用法:
  ./deploy.sh [选项]

选项:
  --check-only          只做环境、配置和增量构建计划检查，不构建、不启动
  --no-uxplay-download  UxPlay 本地源码包缺失时不联网下载
  --no-build            跳过镜像构建，直接启动现有镜像
  --rebuild-all         忽略增量状态，强制重建 receiver/backend/frontend
  -h, --help            显示帮助

默认采用按服务增量构建：
  - receiver 构建输入未变化 -> 不重建 receiver
  - backend 构建输入未变化  -> 不重建 backend
  - frontend 构建输入未变化 -> 不重建 frontend
  - 仅运行时 .env 变化由 docker compose up 处理，不会触发无关镜像重建

可选环境变量:
  DEPLOY_AUTO_PULL=0       缺少基础镜像时不自动 docker pull（默认 1）
  DEPLOY_BUILD_VERBOSE=1   显示完整 Docker 构建输出（默认静默，仅失败时显示错误摘要）
  DEPLOY_FORCE_BUILD=1     与 --rebuild-all 相同，强制重建全部服务镜像
  GITHUB_DOWNLOAD_PROXY    仅 UxPlay GitHub 下载使用的代理
  GITHUB_PROXY_PROMPT=0    禁止 UxPlay 下载时询问代理

推荐更新方式:
  git pull && ./deploy.sh && docker image prune -f
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check-only) CHECK_ONLY=1 ;;
    --no-uxplay-download) NO_UXPLAY_DOWNLOAD=1 ;;
    --no-build) NO_BUILD=1 ;;
    --rebuild-all) REBUILD_ALL=1 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "未知参数: $1（使用 --help 查看用法）" ;;
  esac
  shift
done

[ "${DEPLOY_FORCE_BUILD:-0}" != "1" ] || REBUILD_ALL=1
[ "$NO_BUILD" = "0" ] || [ "$REBUILD_ALL" = "0" ] || fail "--no-build 与 --rebuild-all / DEPLOY_FORCE_BUILD=1 不能同时使用"

env_get() {
  local key="$1"
  awk -v key="$key" 'index($0, key "=") == 1 {sub(/^[^=]*=/, ""); print; exit}' "$ENV_FILE"
}

env_set() {
  local key="$1" value="$2" tmp="${ENV_FILE}.tmp.$$"
  awk -v key="$key" -v value="$value" '
    BEGIN {done=0}
    index($0, key "=") == 1 {print key "=" value; done=1; next}
    {print}
    END {if (!done) print key "=" value}
  ' "$ENV_FILE" > "$tmp"
  mv "$tmp" "$ENV_FILE"
}

ensure_env_key() {
  local key="$1" value="$2"
  grep -q "^${key}=" "$ENV_FILE" || env_set "$key" "$value"
}

validate_port() {
  local key="$1" value="$2" min="${3:-1}" max="${4:-65535}"
  case "$value" in ''|*[!0-9]*) fail "$key 不是有效端口: $value" ;; esac
  [ "$value" -ge "$min" ] && [ "$value" -le "$max" ] || fail "$key 超出端口范围 ${min}-${max}: $value"
}

normalize_arch() {
  case "$1" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) return 1 ;;
  esac
}

image_arch_ok() {
  local image="$1" expected="$2" actual
  actual="$(docker image inspect "$image" --format '{{.Architecture}}' 2>/dev/null || true)"
  [ -n "$actual" ] || return 1
  actual="$(normalize_arch "$actual" 2>/dev/null || echo "$actual")"
  [ "$actual" = "$expected" ]
}

show_error_summary() {
  local file="$1" title="${2:-执行错误}" errors
  [ -f "$file" ] || return 0
  errors="$(grep -Ein '(^|[^[:alpha:]])(error|fatal|failed|failure|timeout|timed out|exit code|non-zero|unable to|could not|connection refused|network is unreachable|permission denied|not found|no space left|denied|address already in use)([^[:alpha:]]|$)' "$file" 2>/dev/null | tail -n 80 || true)"
  warn "$title："
  if [ -n "$errors" ]; then
    printf '%s\n' "$errors" >&2
  else
    warn "未匹配到明确错误行，显示日志最后 60 行："
    tail -n 60 "$file" >&2 2>/dev/null || true
  fi
}

ensure_image() {
  local image="$1" arch="$2" rc
  if image_arch_ok "$image" "$arch"; then
    ok "基础镜像可用: $image"
    return 0
  fi
  if [ "${DEPLOY_AUTO_PULL:-1}" = "0" ]; then
    fail "缺少可用基础镜像 $image，请先 docker pull/docker load，或取消 DEPLOY_AUTO_PULL=0"
  fi
  info "准备基础镜像: $image"
  : > "$PREFLIGHT_LOG"
  set +e
  docker pull "$image" >"$PREFLIGHT_LOG" 2>&1
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    show_error_summary "$PREFLIGHT_LOG" "基础镜像拉取错误摘要"
    fail "无法拉取基础镜像 $image"
  fi
  image_arch_ok "$image" "$arch" || fail "基础镜像 $image 架构与 Docker Server 不匹配: $arch"
  ok "基础镜像准备完成: $image"
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

validate_uxplay_archive() {
  local file="$1" expected_sha="${2:-}" actual_sha
  [ -s "$file" ] || return 1

  # 必须完整读取 tar 列表，不能使用 `tar | grep -q`。
  # deploy.sh 启用了 pipefail；grep -q 提前退出会让 tar 收到 SIGPIPE，
  # 从而把正常的 UxPlay 源码包误判成损坏。
  tar -tzf "$file" >/dev/null 2>&1 || return 1
  tar -tzf "$file" 2>/dev/null \
    | awk '/^[^/]+\/CMakeLists\.txt$/ {found=1} END {exit !found}' \
    || return 1

  if [ -n "$expected_sha" ]; then
    actual_sha="$(sha256_file "$file")"
    [ "$(printf '%s' "$actual_sha" | tr '[:upper:]' '[:lower:]')" = \
      "$(printf '%s' "$expected_sha" | tr '[:upper:]' '[:lower:]')" ] || return 1
  fi
}

prepare_uxplay() {
  local version="$1" expected source_url sha candidate
  expected="$ROOT_DIR/vendor/uxplay/uxplay-v${version}.tar.gz"
  source_url="$(env_get UXPLAY_SOURCE_URL || true)"
  sha="$(env_get UXPLAY_SHA256 || true)"
  mkdir -p "$ROOT_DIR/vendor/uxplay"

  if validate_uxplay_archive "$expected" "$sha"; then
    ok "UxPlay 本地源码包有效: vendor/uxplay/uxplay-v${version}.tar.gz"
    return 0
  fi

  if [ -e "$expected" ]; then
    warn "UxPlay 本地源码包校验失败，已隔离"
    mv -f "$expected" "${expected}.invalid.$(date +%s)"
  fi

  # 旧版 deploy.sh 曾因 pipefail + grep -q 把正常源码包误标为 invalid。
  # 先重新校验这些历史文件，能恢复就不重复下载。
  while IFS= read -r -d '' candidate; do
    if validate_uxplay_archive "$candidate" "$sha"; then
      mv -f "$candidate" "$expected"
      ok "已恢复此前误判的 UxPlay 本地源码包"
      return 0
    fi
  done < <(find "$ROOT_DIR/vendor/uxplay" -maxdepth 1 -type f -name "uxplay-v${version}.tar.gz.invalid.*" -print0 | sort -zr)

  for candidate in \
    "$ROOT_DIR/UxPlay-${version}.tar.gz" \
    "$ROOT_DIR/uxplay-v${version}.tar.gz" \
    "$ROOT_DIR/vendor/uxplay/UxPlay-${version}.tar.gz"; do
    if validate_uxplay_archive "$candidate" "$sha"; then
      mv -f "$candidate" "$expected"
      ok "检测到已下载 UxPlay 源码包并自动归位"
      return 0
    fi
  done

  [ "$NO_UXPLAY_DOWNLOAD" = "0" ] || fail "缺少 UxPlay 本地源码包: vendor/uxplay/uxplay-v${version}.tar.gz"
  [ -f "$ROOT_DIR/scripts/download-uxplay.sh" ] || fail "缺少 scripts/download-uxplay.sh"
  command_exists curl || fail "需要 curl 下载 UxPlay，或手工放置 $expected"

  info "UxPlay 本地源码包缺失，准备下载 v${version}..."
  UXPLAY_SOURCE_URL="$source_url" \
  UXPLAY_SHA256="$sha" \
  GITHUB_DOWNLOAD_PROXY="${GITHUB_DOWNLOAD_PROXY:-}" \
  GITHUB_PROXY_PROMPT="${GITHUB_PROXY_PROMPT:-1}" \
    bash "$ROOT_DIR/scripts/download-uxplay.sh" "$version" || fail "UxPlay 下载失败"

  validate_uxplay_archive "$expected" "$sha" || fail "UxPlay 源码包校验失败: $expected"
  ok "UxPlay 本地源码包准备完成"
}

fingerprint_file() {
  local file="$1" rel digest
  rel="${file#$ROOT_DIR/}"
  if [ -f "$file" ]; then
    digest="$(sha256_file "$file")"
    printf 'file:%s:%s\n' "$rel" "$digest"
  else
    printf 'missing:%s\n' "$rel"
  fi
}

fingerprint_tree() {
  local dir="$1" file
  if [ ! -d "$dir" ]; then
    printf 'missing-dir:%s\n' "${dir#$ROOT_DIR/}"
    return 0
  fi

  while IFS= read -r -d '' file; do
    fingerprint_file "$file"
  done < <(
    find "$dir" -type f \
      ! -path '*/node_modules/*' \
      ! -path '*/dist/*' \
      ! -path '*/.venv/*' \
      ! -path '*/venv/*' \
      ! -path '*/__pycache__/*' \
      ! -path '*/.pytest_cache/*' \
      ! -path '*/.ruff_cache/*' \
      ! -path '*/coverage/*' \
      -print0 | sort -z
  )
}

service_fingerprint() {
  local service="$1" archive
  {
    printf 'fingerprint-version:3\n'
    fingerprint_file "$ROOT_DIR/.dockerignore"
    case "$service" in
      receiver)
        fingerprint_file "$ROOT_DIR/receiver/Dockerfile"
        fingerprint_file "$ROOT_DIR/receiver/entrypoint.sh"
        archive="$ROOT_DIR/vendor/uxplay/uxplay-v${UXPLAY_VERSION}.tar.gz"
        fingerprint_file "$archive"
        printf 'UXPLAY_VERSION=%s\n' "$UXPLAY_VERSION"
        printf 'UXPLAY_SOURCE_URL=%s\n' "$(env_get UXPLAY_SOURCE_URL || true)"
        printf 'UXPLAY_SHA256=%s\n' "$(env_get UXPLAY_SHA256 || true)"
        printf 'DEBIAN_BASE_IMAGE=%s\n' "$DEBIAN_BASE_IMAGE"
        printf 'DEBIAN_MIRROR=%s\n' "$(env_get DEBIAN_MIRROR)"
        printf 'DEBIAN_SECURITY_MIRROR=%s\n' "$(env_get DEBIAN_SECURITY_MIRROR)"
        ;;
      backend)
        fingerprint_file "$ROOT_DIR/backend/Dockerfile"
        fingerprint_file "$ROOT_DIR/backend/pyproject.toml"
        fingerprint_tree "$ROOT_DIR/backend/app"
        printf 'PYTHON_BASE_IMAGE=%s\n' "$PYTHON_BASE_IMAGE"
        printf 'PYPI_INDEX_URL=%s\n' "$(env_get PYPI_INDEX_URL)"
        ;;
      frontend)
        fingerprint_tree "$ROOT_DIR/frontend"
        printf 'NODE_BASE_IMAGE=%s\n' "$NODE_BASE_IMAGE"
        printf 'NGINX_BASE_IMAGE=%s\n' "$NGINX_BASE_IMAGE"
        printf 'NPM_REGISTRY=%s\n' "$(env_get NPM_REGISTRY)"
        ;;
      *) return 2 ;;
    esac
  } | sha256sum | awk '{print $1}'
}

state_get() {
  local key="$1"
  [ -f "$BUILD_STATE_FILE" ] || return 0
  awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$BUILD_STATE_FILE"
}

write_build_state() {
  local tmp="${BUILD_STATE_FILE}.tmp.$$"
  {
    printf 'receiver=%s\n' "$RECEIVER_FINGERPRINT"
    printf 'backend=%s\n' "$BACKEND_FINGERPRINT"
    printf 'frontend=%s\n' "$FRONTEND_FINGERPRINT"
  } > "$tmp"
  mv "$tmp" "$BUILD_STATE_FILE"
}

service_image_exists() {
  local service="$1" image_id
  image_id="$("${COMPOSE[@]}" images -q "$service" 2>/dev/null | head -n 1 || true)"
  [ -n "$image_id" ] && docker image inspect "$image_id" >/dev/null 2>&1
}

plan_service_build() {
  local service="$1" current="$2" previous reason=""
  previous="$(state_get "$service")"

  if [ "$REBUILD_ALL" = "1" ]; then
    reason="强制重建"
  elif ! service_image_exists "$service"; then
    reason="镜像不存在"
  elif [ -z "$previous" ]; then
    reason="尚无增量构建状态"
  elif [ "$current" != "$previous" ]; then
    reason="构建输入已变化"
  fi

  if [ -n "$reason" ]; then
    BUILD_SERVICES+=("$service")
    info "$service: 需要重建（$reason）"
  else
    ok "$service: 无构建变更，复用现有镜像"
  fi
}

service_selected() {
  local target="$1" service
  for service in "${BUILD_SERVICES[@]:-}"; do
    [ "$service" = "$target" ] && return 0
  done
  return 1
}

port_in_use() {
  local port="$1"
  if command_exists ss; then
    ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq ":${port}$"; return $?
  elif command_exists lsof; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; return $?
  elif command_exists netstat; then
    netstat -an 2>/dev/null | grep -E 'LISTEN|LISTENING' | grep -Eq "[\.:]${port}[[:space:]]"; return $?
  fi
  return 2
}

project_owns_web_port() {
  local port="$1"
  docker inspect castbridge-web >/dev/null 2>&1 && docker port castbridge-web 2>/dev/null | grep -Eq ":${port}$"
}

receiver_is_running() {
  [ "$(docker inspect -f '{{.State.Running}}' castbridge-receiver 2>/dev/null || true)" = "true" ]
}

check_web_port() {
  local port="$1" rc
  if project_owns_web_port "$port"; then
    ok "Web 端口 $port 已由 CastBridge 使用"
    return 0
  fi
  set +e; port_in_use "$port"; rc=$?; set -e
  case "$rc" in
    0) fail "Web 端口 $port 已被其他进程占用，请修改 .env 中 CASTBRIDGE_WEB_PORT" ;;
    1) ok "Web 端口可用: $port" ;;
    2) warn "没有 ss/lsof/netstat，跳过 Web 端口 $port 检测" ;;
  esac
}

check_airplay_ports() {
  local base="$1" port rc
  if receiver_is_running; then
    ok "AirPlay Receiver 已在运行，端口占用将在容器更新时重新校验"
    return 0
  fi
  for port in "$base" "$((base + 1))" "$((base + 2))"; do
    set +e; port_in_use "$port"; rc=$?; set -e
    case "$rc" in
      0) fail "AirPlay TCP 端口 $port 已被其他进程占用，请修改 CASTBRIDGE_AIRPLAY_PORT" ;;
      1) ;;
      2) warn "没有 ss/lsof/netstat，跳过 AirPlay TCP 端口检测"; return 0 ;;
    esac
  done
  ok "AirPlay TCP 端口可用: ${base}-$((base + 2))"
}

wait_for_health() {
  local container="$1" timeout="${2:-120}" elapsed=0 status
  while [ "$elapsed" -lt "$timeout" ]; do
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container" 2>/dev/null || true)"
    case "$status" in
      healthy|running) return 0 ;;
      unhealthy|exited|dead) return 1 ;;
    esac
    sleep 2
    elapsed=$((elapsed + 2))
  done
  return 1
}

http_ok() {
  local url="$1"
  if command_exists curl; then
    curl -fsS --max-time 4 "$url" >/dev/null 2>&1
  elif command_exists wget; then
    wget -q -T 4 -O /dev/null "$url" >/dev/null 2>&1
  else
    return 2
  fi
}

show_docker_networks() {
  warn "当前 Docker 网络与子网："
  docker network ls --format '  {{.ID}}  {{.Driver}}  {{.Name}}' >&2 || true
  local ids
  ids="$(docker network ls -q 2>/dev/null || true)"
  if [ -n "$ids" ]; then
    # shellcheck disable=SC2086
    docker network inspect $ids --format '  {{.Name}} -> {{range .IPAM.Config}}{{.Subnet}} {{end}}' >&2 2>/dev/null || true
  fi
}

compose_up_with_network_recovery() {
  local rc
  : > "$UP_LOG"
  set +e
  "${COMPOSE[@]}" up -d --remove-orphans >"$UP_LOG" 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 0 ] && return 0

  if grep -q "all predefined address pools have been fully subnetted" "$UP_LOG"; then
    warn "检测到 Docker 默认地址池已耗尽，将清理未使用网络并重试一次。"
    show_docker_networks
    docker network prune -f >/dev/null || fail "docker network prune 执行失败"
    : > "$UP_LOG"
    set +e
    "${COMPOSE[@]}" up -d --remove-orphans >"$UP_LOG" 2>&1
    rc=$?
    set -e
    [ "$rc" -eq 0 ] && return 0
  fi
  return "$rc"
}

mkdir -p logs run vendor/uxplay
for dir in logs run vendor/uxplay; do
  [ -w "$dir" ] || fail "目录不可写: $dir"
done
: > "$PREFLIGHT_LOG"

info "CastBridge 部署前检查开始"
printf '项目目录: %s\n' "$ROOT_DIR"

command_exists docker || fail "未安装 Docker"
docker version >/dev/null 2>&1 || fail "Docker daemon 不可用"
docker compose version >/dev/null 2>&1 || fail "需要 Docker Compose v2"
docker buildx version >/dev/null 2>&1 || fail "需要 Docker Buildx"
for cmd in awk grep df tar find sort sha256sum tr; do command_exists "$cmd" || fail "缺少命令: $cmd"; done

DOCKER_ARCH_RAW="$(docker info --format '{{.Architecture}}' 2>/dev/null || true)"
DOCKER_ARCH="$(normalize_arch "$DOCKER_ARCH_RAW" 2>/dev/null || true)"
[ -n "$DOCKER_ARCH" ] || fail "不支持的 Docker Server 架构: ${DOCKER_ARCH_RAW:-unknown}"
ok "Docker Server 架构: $DOCKER_ARCH"

docker buildx inspect default >/dev/null 2>&1 || fail "未找到 buildx default builder"
docker buildx inspect default --bootstrap >/dev/null 2>&1 || true
export BUILDX_BUILDER=default
ok "构建器: default (docker driver)"

[ -f "$ENV_EXAMPLE" ] || fail "缺少 .env.example"
if [ ! -f "$ENV_FILE" ]; then
  cp "$ENV_EXAMPLE" "$ENV_FILE"
  info "已从 .env.example 创建 .env"
fi
chmod 600 "$ENV_FILE" 2>/dev/null || true

ensure_env_key CASTBRIDGE_WEB_PORT 8090
ensure_env_key TZ Asia/Shanghai
ensure_env_key CASTBRIDGE_ENVIRONMENT production
ensure_env_key CASTBRIDGE_RECEIVER_NAME CastBridge
ensure_env_key CASTBRIDGE_LOG_LEVEL INFO
ensure_env_key CASTBRIDGE_RECEIVER_STALE_SECONDS 10
ensure_env_key UXPLAY_VERSION 1.74
ensure_env_key UXPLAY_SOURCE_URL ""
ensure_env_key UXPLAY_SHA256 ""
ensure_env_key CASTBRIDGE_AIRPLAY_PORT 7100
ensure_env_key CASTBRIDGE_RTP_VIDEO_PORT 5000
ensure_env_key CASTBRIDGE_RTP_AUDIO_PORT 5002
ensure_env_key DEBIAN_MIRROR http://mirrors.aliyun.com/debian
ensure_env_key DEBIAN_SECURITY_MIRROR http://mirrors.aliyun.com/debian-security
ensure_env_key PYPI_INDEX_URL https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple
ensure_env_key NPM_REGISTRY https://registry.npmmirror.com
ensure_env_key DEBIAN_BASE_IMAGE debian:bookworm-slim
ensure_env_key PYTHON_BASE_IMAGE python:3.12-slim
ensure_env_key NODE_BASE_IMAGE node:22-alpine
ensure_env_key NGINX_BASE_IMAGE nginx:1.27-alpine

WEB_PORT="$(env_get CASTBRIDGE_WEB_PORT)"
AIRPLAY_PORT="$(env_get CASTBRIDGE_AIRPLAY_PORT)"
VIDEO_RTP_PORT="$(env_get CASTBRIDGE_RTP_VIDEO_PORT)"
AUDIO_RTP_PORT="$(env_get CASTBRIDGE_RTP_AUDIO_PORT)"
RECEIVER_NAME="$(env_get CASTBRIDGE_RECEIVER_NAME)"
UXPLAY_VERSION="$(env_get UXPLAY_VERSION)"
DEBIAN_BASE_IMAGE="$(env_get DEBIAN_BASE_IMAGE)"
PYTHON_BASE_IMAGE="$(env_get PYTHON_BASE_IMAGE)"
NODE_BASE_IMAGE="$(env_get NODE_BASE_IMAGE)"
NGINX_BASE_IMAGE="$(env_get NGINX_BASE_IMAGE)"

validate_port CASTBRIDGE_WEB_PORT "$WEB_PORT"
validate_port CASTBRIDGE_AIRPLAY_PORT "$AIRPLAY_PORT" 1024 65533
validate_port CASTBRIDGE_RTP_VIDEO_PORT "$VIDEO_RTP_PORT" 1024 65535
validate_port CASTBRIDGE_RTP_AUDIO_PORT "$AUDIO_RTP_PORT" 1024 65535
[ "$VIDEO_RTP_PORT" != "$AUDIO_RTP_PORT" ] || fail "视频和音频 RTP 端口不能相同"
for airplay_port in "$AIRPLAY_PORT" "$((AIRPLAY_PORT + 1))" "$((AIRPLAY_PORT + 2))"; do
  [ "$WEB_PORT" != "$airplay_port" ] || fail "Web 端口不能与 AirPlay 端口重复: $WEB_PORT"
  [ "$VIDEO_RTP_PORT" != "$airplay_port" ] || fail "视频 RTP 端口不能与 AirPlay 端口重复: $VIDEO_RTP_PORT"
  [ "$AUDIO_RTP_PORT" != "$airplay_port" ] || fail "音频 RTP 端口不能与 AirPlay 端口重复: $AUDIO_RTP_PORT"
done
[ -n "$RECEIVER_NAME" ] || fail "CASTBRIDGE_RECEIVER_NAME 不能为空"
[ -n "$UXPLAY_VERSION" ] || fail "UXPLAY_VERSION 不能为空"

check_web_port "$WEB_PORT"
check_airplay_ports "$AIRPLAY_PORT"

FREE_KB="$(df -Pk "$ROOT_DIR" 2>/dev/null | awk 'NR==2 {print $4}' || true)"
if [ -n "$FREE_KB" ] && [ "$FREE_KB" -lt 5242880 ]; then
  warn "当前文件系统剩余空间不足 5 GiB，Docker 构建可能失败"
elif [ -n "$FREE_KB" ]; then
  ok "磁盘剩余空间: 约 $((FREE_KB / 1024 / 1024)) GiB"
fi

COMPOSE=(docker compose --env-file "$ENV_FILE")
"${COMPOSE[@]}" config >/dev/null || fail "docker compose 配置校验失败"
ok "docker compose config 校验通过"

BUILD_SERVICES=()
RECEIVER_FINGERPRINT="$(service_fingerprint receiver)"
BACKEND_FINGERPRINT="$(service_fingerprint backend)"
FRONTEND_FINGERPRINT="$(service_fingerprint frontend)"

if [ "$NO_BUILD" = "0" ]; then
  info "检查服务构建变更..."
  plan_service_build receiver "$RECEIVER_FINGERPRINT"
  plan_service_build backend "$BACKEND_FINGERPRINT"
  plan_service_build frontend "$FRONTEND_FINGERPRINT"
else
  warn "已使用 --no-build，跳过增量构建检查"
fi

if [ "$CHECK_ONLY" = "1" ]; then
  if [ "$NO_BUILD" = "0" ] && [ "${#BUILD_SERVICES[@]}" -eq 0 ]; then
    ok "增量构建计划：无需重建任何服务"
  elif [ "$NO_BUILD" = "0" ]; then
    info "增量构建计划: ${BUILD_SERVICES[*]}"
  fi
  ok "检查完成（--check-only），未下载源码、未拉取基础镜像、未构建或启动服务"
  exit 0
fi

if [ "$NO_BUILD" = "0" ] && [ "${#BUILD_SERVICES[@]}" -gt 0 ]; then
  if service_selected receiver; then
    prepare_uxplay "$UXPLAY_VERSION"
    RECEIVER_FINGERPRINT="$(service_fingerprint receiver)"
    ensure_image "$DEBIAN_BASE_IMAGE" "$DOCKER_ARCH"
  fi
  if service_selected backend; then
    ensure_image "$PYTHON_BASE_IMAGE" "$DOCKER_ARCH"
  fi
  if service_selected frontend; then
    ensure_image "$NODE_BASE_IMAGE" "$DOCKER_ARCH"
    ensure_image "$NGINX_BASE_IMAGE" "$DOCKER_ARCH"
  fi

  BUILD_CMD=("${COMPOSE[@]}" build)
  if "${COMPOSE[@]}" build --help 2>/dev/null | grep -q -- '--builder'; then
    BUILD_CMD+=(--builder default)
  fi
  BUILD_CMD+=("${BUILD_SERVICES[@]}")

  : > "$BUILD_LOG"
  info "开始增量构建: ${BUILD_SERVICES[*]}（完整日志: logs/deploy-build.log）..."
  set +e
  if [ "${DEPLOY_BUILD_VERBOSE:-0}" = "1" ]; then
    "${BUILD_CMD[@]}" 2>&1 | tee "$BUILD_LOG"
    BUILD_RC=${PIPESTATUS[0]}
  else
    "${BUILD_CMD[@]}" >"$BUILD_LOG" 2>&1
    BUILD_RC=$?
  fi
  set -e

  if [ "$BUILD_RC" -ne 0 ]; then
    show_error_summary "$BUILD_LOG" "镜像构建错误摘要"
    fail "镜像构建失败，完整日志: logs/deploy-build.log"
  fi

  RECEIVER_FINGERPRINT="$(service_fingerprint receiver)"
  BACKEND_FINGERPRINT="$(service_fingerprint backend)"
  FRONTEND_FINGERPRINT="$(service_fingerprint frontend)"
  write_build_state
  ok "增量镜像构建完成: ${BUILD_SERVICES[*]}"
elif [ "$NO_BUILD" = "0" ]; then
  ok "receiver/backend/frontend 均无构建变更，跳过镜像构建"
else
  warn "已使用 --no-build，跳过镜像构建"
fi

info "启动/更新 CastBridge..."
if ! compose_up_with_network_recovery; then
  show_error_summary "$UP_LOG" "容器启动错误摘要"
  fail "docker compose up 失败，完整日志: logs/deploy-up.log"
fi
ok "容器启动完成"

info "等待 AirPlay Receiver 健康..."
if ! wait_for_health castbridge-receiver 90; then
  "${COMPOSE[@]}" logs --tail=160 receiver >&2 || true
  fail "AirPlay Receiver 未通过健康检查"
fi
ok "AirPlay Receiver healthy（${RECEIVER_NAME}）"

info "等待 backend 健康..."
if ! wait_for_health castbridge-backend 150; then
  "${COMPOSE[@]}" logs --tail=120 backend >&2 || true
  fail "backend 未通过健康检查"
fi
ok "backend healthy（仅 Docker 内网可达）"

info "等待 Web 入口健康..."
if ! wait_for_health castbridge-web 90; then
  "${COMPOSE[@]}" logs --tail=100 frontend >&2 || true
  fail "Web 容器未通过健康检查"
fi
ok "Web 容器 healthy"

set +e
http_ok "http://127.0.0.1:${WEB_PORT}/health"
HTTP_RC=$?
set -e
case "$HTTP_RC" in
  0) ok "Web 入口与后端 API 反代正常" ;;
  1) warn "Web 容器已运行，但 /health 反代检测暂未通过" ;;
  2) warn "没有 curl/wget，跳过 HTTP 检测" ;;
esac

printf '\n'
ok "CastBridge M1 部署完成"
printf 'Web:             http://127.0.0.1:%s\n' "$WEB_PORT"
printf '局域网访问:     http://<本机IP>:%s\n' "$WEB_PORT"
printf 'AirPlay 名称:   %s\n' "$RECEIVER_NAME"
printf 'AirPlay 端口:   TCP/UDP %s-%s\n' "$AIRPLAY_PORT" "$((AIRPLAY_PORT + 2))"
printf 'mDNS:           UDP 5353（宿主机防火墙需允许局域网访问）\n'
printf 'UxPlay 源码:    vendor/uxplay/uxplay-v%s.tar.gz（仅 Receiver 重建时检查）\n' "$UXPLAY_VERSION"
printf '构建策略:       按服务指纹增量构建\n'
