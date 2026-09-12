#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_DIR="${ROOT_DIR}/vendor/uxplay"
VERSION="${1:-${UXPLAY_VERSION:-1.74}}"
SOURCE_URL="${UXPLAY_SOURCE_URL:-https://github.com/FDH2/UxPlay/archive/refs/tags/v${VERSION}.tar.gz}"
EXPECTED_SHA256="${UXPLAY_SHA256:-}"
DOWNLOAD_PROXY="${GITHUB_DOWNLOAD_PROXY:-}"
PROXY_PROMPT_DONE=0

usage() {
  cat <<'USAGE'
Usage:
  bash scripts/download-uxplay.sh [version]

Examples:
  bash scripts/download-uxplay.sh
  bash scripts/download-uxplay.sh 1.74

Optional environment variables:
  UXPLAY_SOURCE_URL=https://...       override UxPlay source archive URL
  UXPLAY_SHA256=<sha256>              verify source archive checksum when set
  GITHUB_DOWNLOAD_PROXY=http://...    proxy used only for this GitHub download
  GITHUB_PROXY_PROMPT=0               disable interactive proxy prompt
USAGE
}

archive_name() {
  printf 'uxplay-v%s.tar.gz\n' "$VERSION"
}

sha256_of() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$file" | awk '{print $NF}'
  else
    return 2
  fi
}

validate_archive() {
  local file="$1" actual expected_lower actual_lower
  [ -s "$file" ] || return 1
  tar -tzf "$file" >/dev/null 2>&1 || return 1
  tar -tzf "$file" 2>/dev/null | grep -Eq '^[^/]+/CMakeLists\.txt$' || return 1

  if [ -n "$EXPECTED_SHA256" ]; then
    actual="$(sha256_of "$file")" || {
      echo "无法执行 SHA256 校验：需要 sha256sum、shasum 或 openssl" >&2
      return 1
    }
    actual_lower="$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')"
    expected_lower="$(printf '%s' "$EXPECTED_SHA256" | tr '[:upper:]' '[:lower:]')"
    [ "$actual_lower" = "$expected_lower" ] || {
      echo "UxPlay SHA256 不匹配" >&2
      echo "expected: $EXPECTED_SHA256" >&2
      echo "actual:   $actual" >&2
      return 1
    }
  fi
}

prompt_github_proxy_if_needed() {
  local answer proxy

  [ "$PROXY_PROMPT_DONE" = "0" ] || return 0
  PROXY_PROMPT_DONE=1

  case "$SOURCE_URL" in
    *github.com*|*githubusercontent.com*|*codeload.github.com*) ;;
    *) return 0 ;;
  esac

  [ -z "$DOWNLOAD_PROXY" ] || return 0
  [ "${GITHUB_PROXY_PROMPT:-1}" != "0" ] || return 0
  [ -t 0 ] || return 0

  printf '需要从 GitHub 下载 UxPlay，是否为本次下载配置代理？ [y/N]: '
  read -r answer
  case "$answer" in
    y|Y|yes|YES|Yes|是)
      printf '请输入代理地址（例如 http://127.0.0.1:7890 或 socks5h://127.0.0.1:7891）: '
      read -r proxy
      if [ -z "$proxy" ]; then
        echo "未输入代理地址，将直接下载。"
        return 0
      fi
      case "$proxy" in
        http://*|https://*|socks5://*|socks5h://*) DOWNLOAD_PROXY="$proxy" ;;
        *) echo "不支持的代理格式" >&2; exit 2 ;;
      esac
      ;;
  esac
}

download() {
  local target tmp
  local -a curl_args

  mkdir -p "$DEST_DIR"
  target="${DEST_DIR}/$(archive_name)"
  tmp="${target}.part"

  if [ -f "$target" ]; then
    if validate_archive "$target"; then
      echo "UxPlay 本地源码包有效: ${target#$ROOT_DIR/}"
      return 0
    fi
    mv -f "$target" "${target}.invalid.$(date +%s)"
    echo "已有 UxPlay 源码包无效，已隔离。" >&2
  fi

  command -v curl >/dev/null 2>&1 || {
    echo "缺少 curl，无法下载 UxPlay" >&2
    exit 1
  }

  prompt_github_proxy_if_needed
  echo "下载 UxPlay v${VERSION} -> ${target#$ROOT_DIR/}"

  curl_args=(
    -fL
    --silent
    --show-error
    --retry 5
    --retry-delay 3
    --connect-timeout 15
  )
  if [ -n "$DOWNLOAD_PROXY" ]; then
    curl_args+=(--proxy "$DOWNLOAD_PROXY")
  fi

  rm -f "$tmp"
  if ! curl "${curl_args[@]}" "$SOURCE_URL" -o "$tmp"; then
    rm -f "$tmp"
    echo "UxPlay 下载失败: $SOURCE_URL" >&2
    exit 1
  fi

  if ! validate_archive "$tmp"; then
    rm -f "$tmp"
    echo "下载的 UxPlay 源码包校验失败" >&2
    exit 1
  fi

  mv "$tmp" "$target"
  echo "UxPlay 本地源码包准备完成"
}

case "$VERSION" in
  -h|--help|help) usage ;;
  *[!0-9A-Za-z._-]*|'') echo "非法版本号: $VERSION" >&2; exit 2 ;;
  *) download ;;
esac
