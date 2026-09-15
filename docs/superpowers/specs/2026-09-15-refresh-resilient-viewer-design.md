# Refresh-Resilient WebRTC Viewer Design

## Goal

Make browser refresh/open reliable: refreshing `/` may replace the browser WebRTC peer, but it must not reset the AirPlay ingest/decode state or force the new page to wait for the iPhone's very sparse source IDR.

## Current failure mode

The current `MediaBridge.start_peer()` owns the whole chain from `udpsrc` through `webrtcbin`, and `stop_peer()` destroys that whole pipeline. A browser refresh closes `/ws/viewer`, the backend sends `viewer.disconnected`, and Media Bridge tears down the pipeline. The new page then starts receiving the middle of the AirPlay GOP. Because the source can go tens of seconds or minutes without a new IDR, Chrome repeatedly sends PLI/ForceKeyUnit but UxPlay cannot create a fresh source IDR.

## Chosen architecture

Split Media Bridge into two lifetimes.

### 1. Persistent source pipeline

Starts when the Media Bridge process starts and remains alive regardless of browser viewers:

```text
UxPlay H.264 RTP :5000
  -> rtpjitterbuffer
  -> rtph264depay
  -> h264parse
  -> encoded AU appsink
  -> Python AU retime bridge
  -> encoded AU appsrc (arrival-clock PTS)
  -> h264parse
  -> avdec_h264
  -> videoconvert
  -> I420 raw-frame appsink
```

The existing non-dropping encoded-AU bridge remains in front of the decoder so the source reference chain is not damaged and the broken UxPlay RTP clock is still replaced after complete AU reconstruction.

The raw appsink may use a very small dropping queue because raw frames are independent; dropping an old raw frame only reduces frame rate and cannot poison an H.264 reference chain.

Source diagnostics (`source_idr_count`, SPS/PPS, input RTP clock, retimed AU counters) belong to this persistent pipeline and therefore survive browser refreshes.

### 2. Viewer pipeline

Created only for the active browser viewer:

```text
raw appsrc
  -> videoconvert
  -> x264enc tune=zerolatency speed-preset=ultrafast bframes=0 key-int-max=60
  -> h264parse config-interval=-1
  -> rtph264pay config-interval=-1
  -> webrtcbin
```

The persistent source pipeline pushes each current raw frame into the active viewer's `raw appsrc`.

A fresh `x264enc` starts each viewer session from a decodable keyframe, so a page refresh no longer depends on the iPhone producing another IDR. While connected, browser PLI/ForceKeyUnit reaches the local encoder rather than terminating at an unresponsive AirPlay source. `key-int-max=60` also guarantees periodic recovery even if a feedback event is missed.

The viewer encoder is destroyed on page disconnect. The source ingest/decode pipeline is not.

## Codec and negotiation

Install `gstreamer1.0-plugins-ugly` so `x264enc` is guaranteed to exist in the shared receiver/media image.

Keep dynamic H.264 SDP profile negotiation, but derive `profile-level-id` and SPS/PPS from the viewer encoder output, not from the original AirPlay source. `rtph264pay config-interval=-1` sends SPS/PPS with each IDR.

The first raw frame after a viewer connects starts the local encoder; offer creation waits for the encoder SPS exactly as the current passthrough design waits for source SPS.

## Viewer lifecycle

Backend WebSocket behavior can remain simple: each page load gets a new `viewer_id`.

- `viewer.connected`: replace only the viewer pipeline.
- `viewer.disconnected`: stop only that viewer pipeline when IDs match.
- Media signaling reconnect: preserve/restart the persistent source pipeline; do not conflate signaling loss with source pipeline teardown unless the Media Bridge process itself is shutting down.
- A new viewer still replaces the previous viewer because M2 remains single-viewer.

No stable browser token, localStorage identity, or reconnect grace period is required to solve refresh reliability.

## Status and diagnostics

Add explicit fields so diagnostics distinguish source and viewer encoder behavior:

- `source_pipeline_active`
- `viewer_encoder` = `x264enc`
- `viewer_encoded_idr_count`
- `viewer_force_key_unit_events`

Keep the existing source IDR counters. A healthy refreshed session should show browser decode starting immediately even when `source_idr_count` has not increased.

## Error handling

- If persistent source pipeline cannot start, set Media Bridge state to `error` and expose the GStreamer error.
- If `x264enc` is missing, fail viewer creation with a clear error rather than silently falling back to the broken long-GOP passthrough behavior.
- If viewer pipeline push fails, stop only that viewer pipeline; source ingest remains alive.
- Resolution/caps changes from rotation update the viewer raw appsrc caps from the latest raw sample and allow GStreamer renegotiation.

## Tests and verification

CI receiver smoke test must assert `avdec_h264`, `videoconvert`, and `x264enc` are present in addition to the existing WebRTC elements.

Manual acceptance test:

1. Start iPad mirroring and wait until the source has only one IDR.
2. Confirm video is decoding normally.
3. Refresh the browser repeatedly (at least five times) without stopping AirPlay.
4. Each refresh should display moving video within about 1-2 seconds without waiting for a new source IDR.
5. `source_idr_count` may remain unchanged while browser `frames_decoded` resumes and PLI does not enter a sustained storm.
6. Stop/start the browser viewer while keeping the iPad session active; source diagnostics should continue increasing rather than reset to zero.

## Trade-off

This intentionally trades some CPU and one encode generation for reliable viewer startup/recovery. The previous zero-transcode path cannot guarantee refresh recovery because the AirPlay source does not honor WebRTC keyframe requests and can use an extremely long GOP. Hardware-encoder optimization can be added later without changing the source/viewer lifetime split.