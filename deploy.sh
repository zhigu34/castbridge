#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

ENV_FILE="$ROOT_DIR/.env"
ENV_EXAMPLE="$ROOT_DIR/.env.example"
BUILD_LOG="$ROOT_DIR/logs/deploy-build.log"
UP_LOG="$ROOT_DIR/logs/deploy-up.log"
PREFLIGHT_LOG="$ROOT_DIR/logs/deploy-preflight.log"
CHECK_ONLY=0
NO_BUILD=0

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'EOF'
CastBridge 一键部署脚本

用法:
  ./deploy.sh [选项]

选项:
  --check-only   只做环境/配置检查，不构建和启动
  --no-build     跳过镜像构建，直接启动现有镜像
  -h, --help     显示帮助

可选环境变量:
  DEPLOY_AUTO_PULL=0      缺少基础镜像时不自动 docker pull（默认 1）
  DEPLOY_BUILD_VERBOSE=1  显示完整 Docker 构建输出（默认静默，仅失败时显示错误摘要）

推荐更新方式:
  git pull && ./deploy.sh && docker image prune -f
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check-only) CHECK_ONLY=1 ;;
    --no-build) NO_BUILD=1 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "未知参数: $1（使用 --help 查看用法）" ;;
  esac
  shift
done

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

  errors="$(grep -Ein '(^|[^[:alpha:]])(error|fatal|failed|failure|timeout|timed out|exit code|non-zero|unable to|could not|connection refused|network is unreachable|permission denied|not found|no space left|denied)([^[:alpha:]]|$)' "$file" 2>/dev/null | tail -n 80 || true)"

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

project_owns_port() {
  local port="$1"
  if docker inspect castbridge-web >/dev/null 2>&1 && docker port castbridge-web 2>/dev/null | grep -Eq ":${port}$"; then
    return 0
  fi
  return 1
}

check_port() {
  local port="$1" rc
  if project_owns_port "$port"; then
    ok "Web 端口 $port 已由 CastBridge 使用"
    return 0
  fi

  set +e
  port_in_use "$port"
  rc=$?
  set -e

  case "$rc" in
    0) fail "Web 端口 $port 已被其他进程占用，请修改 .env 中 CASTBRIDGE_WEB_PORT" ;;
    1) ok "Web 端口可用: $port" ;;
    2) warn "没有 ss/lsof/netstat，跳过端口 $port 检测" ;;
  esac
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

mkdir -p logs
: > "$PREFLIGHT_LOG"

info "CastBridge 部署前检查开始"
printf '项目目录: %s\n' "$ROOT_DIR"

command_exists docker || fail "未安装 Docker"
docker version >/dev/null 2>&1 || fail "Docker daemon 不可用"
docker compose version >/dev/null 2>&1 || fail "需要 Docker Compose v2"
docker buildx version >/dev/null 2>&1 || fail "需要 Docker Buildx"
for cmd in awk grep df; do command_exists "$cmd" || fail "缺少命令: $cmd"; done

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

WEB_PORT="$(env_get CASTBRIDGE_WEB_PORT)"
case "$WEB_PORT" in ''|*[!0-9]*) fail "CASTBRIDGE_WEB_PORT 不是有效端口: $WEB_PORT" ;; esac
[ "$WEB_PORT" -ge 1 ] && [ "$WEB_PORT" -le 65535 ] || fail "CASTBRIDGE_WEB_PORT 超出有效范围: $WEB_PORT"
check_port "$WEB_PORT"

FREE_KB="$(df -Pk "$ROOT_DIR" 2>/dev/null | awk 'NR==2 {print $4}' || true)"
if [ -n "$FREE_KB" ] && [ "$FREE_KB" -lt 5242880 ]; then
  warn "当前文件系统剩余空间不足 5 GiB，Docker 构建可能失败"
elif [ -n "$FREE_KB" ]; then
  ok "磁盘剩余空间: 约 $((FREE_KB / 1024 / 1024)) GiB"
fi

ensure_image python:3.12-slim "$DOCKER_ARCH"
ensure_image node:22-alpine "$DOCKER_ARCH"
ensure_image nginx:1.27-alpine "$DOCKER_ARCH"

COMPOSE=(docker compose --env-file "$ENV_FILE")
"${COMPOSE[@]}" config >/dev/null || fail "docker compose 配置校验失败"
ok "docker compose config 校验通过"

if [ "$CHECK_ONLY" = "1" ]; then
  ok "检查完成（--check-only），未构建或启动服务"
  exit 0
fi

if [ "$NO_BUILD" = "0" ]; then
  BUILD_CMD=("${COMPOSE[@]}" build)
  if "${COMPOSE[@]}" build --help 2>/dev/null | grep -q -- '--builder'; then
    BUILD_CMD+=(--builder default)
  fi
  BUILD_CMD+=(backend frontend)

  : > "$BUILD_LOG"
  info "开始构建 backend/frontend（默认静默，完整日志: logs/deploy-build.log）..."

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
  ok "backend/frontend 镜像构建完成"
else
  warn "已使用 --no-build，跳过镜像构建"
fi

info "启动/更新 CastBridge..."
if ! compose_up_with_network_recovery; then
  show_error_summary "$UP_LOG" "容器启动错误摘要"
  fail "docker compose up 失败，完整日志: logs/deploy-up.log"
fi
ok "容器启动完成"

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
ok "CastBridge 部署完成"
printf 'Web:         http://127.0.0.1:%s\n' "$WEB_PORT"
printf '局域网访问: http://<本机IP>:%s\n' "$WEB_PORT"
printf 'Backend:     internal only (backend:8000，通过 Web /api 和 /ws 访问)\n'
printf '\n推荐更新命令:\n  git pull && ./deploy.sh && docker image prune -f\n'
