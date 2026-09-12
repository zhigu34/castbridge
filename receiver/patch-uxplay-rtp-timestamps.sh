#!/bin/sh
set -eu

file="renderers/video_renderer.c"

[ -f "$file" ] || {
  echo "[uxplay-patch] missing $file" >&2
  exit 1
}

grep -q 'static bool sync = false;' "$file" || {
  echo "[uxplay-patch] expected sync declaration not found" >&2
  exit 1
}

grep -q 'bool rtp = (bool) strlen(rtp_pipeline);' "$file" || {
  echo "[uxplay-patch] expected RTP mode declaration not found" >&2
  exit 1
}

sync_checks="$(grep -c 'if (sync) {' "$file" || true)"
[ "$sync_checks" -eq 2 ] || {
  echo "[uxplay-patch] expected exactly 2 timestamp sync checks, found $sync_checks" >&2
  exit 1
}

# UxPlay 1.73.x only writes GstBuffer PTS when the renderer's `sync` flag is
# enabled. The -vrtp pipeline bypasses the videosink branch that sets that flag,
# so RTP output can be produced with non-advancing/invalid RTP timestamps.
# Preserve the AirPlay-provided PTS whenever RTP forwarding is enabled while
# leaving normal rendered-video -vsync behavior unchanged.
sed -i \
  -e '/static bool sync = false;/a static bool rtp_output = false;' \
  -e '/bool rtp = (bool) strlen(rtp_pipeline);/a\    rtp_output = rtp;' \
  -e 's/if (sync) {/if (sync || rtp_output) {/g' \
  "$file"

grep -q 'static bool rtp_output = false;' "$file"
grep -q 'rtp_output = rtp;' "$file"
[ "$(grep -c 'if (sync || rtp_output) {' "$file")" -eq 2 ]

echo "[uxplay-patch] RTP video timestamps enabled"
