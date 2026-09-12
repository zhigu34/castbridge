#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

ENV_FILE="$ROOT_DIR/.env"
ENV_EXAMPLE="$ROOT_DIR/.env.example"
BUILD_LOG="$ROOT_DIR/logs/deploy-build.log"
UP_LOG="$ROOT_DIR/logs/deploy-up.log"
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
  --check-only   只做环境和配置检查，不构建、不启动
  --no-build     跳过镜像构建，直接启动现有镜像
  -h, --help     显示帮助

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

port_in_use() {
  local port="$1"
  if command_exists ss; then
    ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq ":${port}$"
  elif command_exists lsof; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
  elif command_exists netstat; then
    netstat -an 2>/dev/null | grep -E 'LISTEN|LISTENING' | grep -Eq "[\.:]${port}[[:space:]]"
  else
    return 2
  fi
}

project_owns_port() {
  local port="$1"
  docker inspect castbridge-web >/dev/null 2>&1 || return 1
  docker port castbridge-web 2>/dev/null | grep -Eq ":${port}$"
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
    2) warn "未找到 ss/lsof/netstat，跳过端口占用检测" ;;
  esac
}

wait_for_health() {
  local container="$1" timeout="${2:-120}" elapsed=0 status
  while [ "$elapsed" -lt "$timeout" ]; do
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container" 2>/dev/null || true)"
    case "$status" in
      healthy) return 0 ;;
      unhealthy|exited|dead) return 1 ;;
    esac
    sleep 2
    elapsed=$((elapsed + 2))
  done
  return 1
}

show_log_tail() {
  local file="$1"
  [ -f "$file" ] || return 0
  warn "最后 80 行日志："
  tail -n 80 "$file" >&2 || true
}

mkdir -p logs

info "CastBridge 部署前检查开始"
printf '项目目录: %s\n' "$ROOT_DIR"

command_exists docker || fail "未安装 Docker"
docker version >/dev/null 2>&1 || fail "Docker daemon 不可用"
docker compose version >/dev/null 2>&1 || fail "需要 Docker Compose v2"
for cmd in awk grep tee; do command_exists "$cmd" || fail "缺少命令: $cmd"; done

[ -f "$ENV_EXAMPLE" ] || fail "缺少 .env.example"
if [ ! -f "$ENV_FILE" ]; then
  cp "$ENV_EXAMPLE" "$ENV_FILE"
  info "已从 .env.example 创建 .env"
fi
chmod 600 "$ENV_FILE" 2>/dev/null || true

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

WEB_PORT="${CASTBRIDGE_WEB_PORT:-8090}"
[[ "$WEB_PORT" =~ ^[0-9]+$ ]] || fail "CASTBRIDGE_WEB_PORT 必须是数字"
[ "$WEB_PORT" -ge 1 ] && [ "$WEB_PORT" -le 65535 ] || fail "CASTBRIDGE_WEB_PORT 超出有效范围"
check_port "$WEB_PORT"

docker compose config >/dev/null || fail "docker-compose.yml 或 .env 配置无效"
ok "Docker Compose 配置检查通过"

if [ "$CHECK_ONLY" = "1" ]; then
  ok "检查完成，未执行构建和启动"
  exit 0
fi

if [ "$NO_BUILD" = "0" ]; then
  info "构建 CastBridge 镜像..."
  : > "$BUILD_LOG"
  set +e
  docker compose build 2>&1 | tee "$BUILD_LOG"
  rc=${PIPESTATUS[0]}
  set -e
  if [ "$rc" -ne 0 ]; then
    show_log_tail "$BUILD_LOG"
    fail "镜像构建失败"
  fi
  ok "镜像构建完成"
else
  info "已跳过镜像构建"
fi

info "启动 CastBridge..."
: > "$UP_LOG"
set +e
docker compose up -d 2>&1 | tee "$UP_LOG"
rc=${PIPESTATUS[0]}
set -e
if [ "$rc" -ne 0 ]; then
  show_log_tail "$UP_LOG"
  fail "容器启动失败"
fi

info "等待后端健康检查..."
if ! wait_for_health castbridge-backend 120; then
  docker compose logs --tail=120 backend >&2 || true
  fail "后端未进入 healthy 状态"
fi
ok "后端已就绪"

info "等待 Web 入口健康检查..."
if ! wait_for_health castbridge-web 120; then
  docker compose logs --tail=120 frontend >&2 || true
  fail "Web 容器未进入 healthy 状态"
fi
ok "Web 入口已就绪"

printf '\n'
ok "CastBridge 部署完成"
printf '访问地址: http://127.0.0.1:%s\n' "$WEB_PORT"
printf '局域网访问: http://<本机IP>:%s\n' "$WEB_PORT"
printf '\n推荐更新命令:\n  git pull && ./deploy.sh && docker image prune -f\n'
