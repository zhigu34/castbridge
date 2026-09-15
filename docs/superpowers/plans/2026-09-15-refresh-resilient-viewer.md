# Refresh-Resilient Viewer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep AirPlay ingest/decode alive across browser refreshes and give every new browser viewer a locally generated H.264 keyframe so video reconnects immediately.

**Architecture:** Split `MediaBridge` into a persistent source pipeline and a replaceable viewer pipeline. The source pipeline continuously repairs the UxPlay timeline and decodes H.264 to I420 raw frames; the viewer pipeline accepts current raw frames, encodes with `x264enc`, and owns only the WebRTC peer.

**Tech Stack:** Python 3.12, GStreamer 1.x, `webrtcbin`, `avdec_h264`, `x264enc`, FastAPI status API, Vue 3 + TypeScript, Docker Compose.

**Spec:** `docs/superpowers/specs/2026-09-15-refresh-resilient-viewer-design.md`

## Global Constraints

- Keep M2 single-viewer behavior: a new viewer replaces the previous viewer.
- Browser refresh must never reset source RTP/AU/source-IDR diagnostics.
- Keep the existing AU arrival-clock retiming before source decode.
- Source H.264 reference data must not be dropped; raw frames may use a small dropping queue.
- Viewer H.264 must use `x264enc tune=zerolatency speed-preset=ultrafast bframes=0 key-int-max=60`.
- Viewer RTP must use `rtph264pay config-interval=-1` and packetization mode 1.
- Dynamic SDP `profile-level-id`/SPS/PPS must come from the viewer encoder output.
- Signaling loss or viewer disconnect stops only the viewer pipeline; process shutdown stops both pipelines.
- If `x264enc` is unavailable, viewer creation must fail explicitly rather than falling back to passthrough.

---

### Task 1: Add failing runtime/lifecycle checks

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `backend/tests/test_health.py`

**Interfaces:**
- Produces CI requirements for `avdec_h264`, `videoconvert`, `x264enc`, and `MediaBridge.start_source()/stop_source()/start_viewer()/stop_viewer()`.
- Produces API expectations for `source_pipeline_active`, `viewer_encoder`, `viewer_encoded_idr_count`, and `viewer_force_key_unit_events`.

- [ ] **Step 1: Extend receiver-image smoke assertions**

Add element assertions for `avdec_h264`, `videoconvert`, and `x264enc`. Import `MediaBridge` from the installed bridge script, start the persistent source pipeline, start/stop a viewer, and assert the source pipeline object survives viewer teardown.

- [ ] **Step 2: Extend backend media status assertions**

Require the four lifecycle/encoder diagnostic keys in `/api/v1/media`.

- [ ] **Step 3: Verify RED**

Expected before implementation: receiver-image smoke fails because `x264enc` and the split lifecycle API are missing; backend test fails because the new status keys are absent.

### Task 2: Install the local encoder runtime

**Files:**
- Modify: `receiver/Dockerfile`

**Interfaces:**
- Produces GStreamer element `x264enc` through Debian package `gstreamer1.0-plugins-ugly`.

- [ ] **Step 1: Add `gstreamer1.0-plugins-ugly` to the runtime image**
- [ ] **Step 2: Let the receiver-image smoke assertion prove the element exists**

### Task 3: Split Media Bridge source and viewer lifetimes

**Files:**
- Modify: `receiver/media_bridge.py`

**Interfaces:**
- Produces `start_source()`, `stop_source()`, `start_viewer(viewer_id)`, and `stop_viewer()`.
- Persistent source produces I420 samples via `on_raw_sample()`.
- Viewer consumes raw samples through `raw_src` and produces H.264/WebRTC through `webrtcbin`.

- [ ] **Step 1: Replace monolithic pipeline state**

Use separate `source_pipeline`, `viewer_pipeline`, source `au_src`, viewer `raw_src`, and viewer `webrtc` references. Source counters are initialized once for the process/source lifetime; viewer counters reset on each viewer replacement.

- [ ] **Step 2: Implement the persistent source pipeline**

Pipeline: `udpsrc -> rtpjitterbuffer drop-on-latency=false -> rtph264depay -> h264parse -> encoded appsink`, then existing Python AU retime into `appsrc -> h264parse -> avdec_h264 -> videoconvert -> I420 -> raw appsink`.

- [ ] **Step 3: Implement raw-frame handoff**

For each raw sample, deep-copy the buffer, clear PTS/DTS/duration, preserve/update sample caps, and push a new sample into the active viewer `raw_src`. On push failure schedule teardown only for the viewer ID that owned the failed appsrc.

- [ ] **Step 4: Implement the viewer pipeline**

Pipeline: `appsrc raw_src is-live=true format=time do-timestamp=true -> videoconvert -> x264enc tune=zerolatency speed-preset=ultrafast bframes=0 key-int-max=60 -> h264parse config-interval=-1 -> byte-stream AU -> rtph264pay pt=96 mtu=1200 config-interval=-1 aggregate-mode=none -> packetization-mode=1 -> webrtcbin`.

- [ ] **Step 5: Derive negotiation data from viewer output**

Probe the viewer H.264 parser output, count IDR NALs, capture SPS/PPS/profile-level-id, and only then create the offer. `configure_h264_codec_preferences()` uses the viewer profile/SPS/PPS.

- [ ] **Step 6: Keep keyframe feedback local**

Probe upstream `GstForceKeyUnit` at the viewer payloader sink, count it as `viewer_force_key_unit_events`, and allow it to continue upstream into `x264enc`.

- [ ] **Step 7: Separate teardown rules**

`viewer.disconnected` and signaling disconnect call only `stop_viewer()`. `run()` starts source before signaling and only process shutdown calls `stop_source()`.

- [ ] **Step 8: Poll both GStreamer buses**

Source errors set bridge error state; viewer errors stop the viewer without destroying source ingest.

### Task 4: Expose and display split-pipeline diagnostics

**Files:**
- Modify: `backend/app/media.py`
- Modify: `frontend/src/App.vue`

**Interfaces:**
- API exposes `source_pipeline_active: bool`, `viewer_encoder: str | null`, `viewer_encoded_idr_count: int`, `viewer_force_key_unit_events: int`.

- [ ] **Step 1: Add backend defaults and status conversion**
- [ ] **Step 2: Add frontend Media type and copied JSON fields**
- [ ] **Step 3: Show source pipeline, viewer encoder IDRs, and viewer ForceKeyUnit in diagnostics**
- [ ] **Step 4: Update recovery hint to distinguish source IDR scarcity from local encoder recovery**
- [ ] **Step 5: Remove the false warning that treats every source FPS below 50 as a fault**

### Task 5: Verify the complete change

**Files:**
- No new production files.

- [ ] **Step 1: Verify backend tests, frontend typecheck/build, shell/Python syntax, Compose validation, and receiver-image smoke all pass in CI**
- [ ] **Step 2: Confirm the final source shows viewer teardown does not call source teardown**
- [ ] **Step 3: Deploy with `git pull && ./deploy.sh`, mirror from iPad, then refresh the page at least five times; each new viewer should decode in about 1–2 seconds while source counters continue increasing rather than resetting**
