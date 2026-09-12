# CastBridge Roadmap

This roadmap intentionally validates the hardest technical assumptions before building a large UI or multi-protocol abstraction.

## Guiding principle

The first success criterion is not "the dashboard looks finished". It is:

> **An iPhone can select CastBridge from Screen Mirroring and its live screen appears in a Windows/macOS browser with usable LAN latency.**

Everything else follows from proving that path.

---

## M0 — Project foundation

### Goal

Create a reproducible development baseline and define component boundaries.

### Tasks

- [x] Create repository.
- [x] Write project overview.
- [x] Define initial architecture.
- [x] Define staged implementation roadmap.
- [ ] Create backend skeleton (`FastAPI`).
- [ ] Create frontend skeleton (`Vue 3 + TypeScript + Vite`).
- [ ] Add Python/Node linting and formatting.
- [ ] Add development configuration model.
- [ ] Add basic CI for backend and frontend checks.
- [ ] Add `make`/task commands for common development operations.

### Exit criteria

- Backend starts and exposes `/api/health`.
- Frontend starts and can query backend health.
- CI runs on every push/PR.
- Local setup is documented and repeatable.

---

## M1 — AirPlay ingest proof

### Goal

Prove native sender discovery and extract incoming media without rendering it locally.

### Tasks

- [ ] Document supported development OS and required packages.
- [ ] Install/build a known UxPlay version.
- [ ] Start UxPlay from Receiver Manager.
- [ ] Advertise configurable receiver name (default `CastBridge`).
- [ ] Confirm iPhone/iPad/macOS discovery.
- [ ] Confirm sender connect/disconnect lifecycle.
- [ ] Forward video through UxPlay `-vrtp`.
- [ ] Forward audio through UxPlay `-artp`.
- [ ] Record RTP metadata: codec, payload type, clock rate, resolution, fps.
- [ ] Add structured logs for receiver events.

### Prototype deliverable

A CLI/debug pipeline that demonstrates:

```text
iPhone -> AirPlay -> UxPlay -> RTP -> local test sink
```

No browser is required yet.

### Exit criteria

- iPhone can find `CastBridge` in Screen Mirroring.
- Mirroring can remain connected for at least 30 minutes without receiver crash.
- Video RTP can be inspected/played by a local GStreamer pipeline.
- Audio RTP can be inspected/played separately.
- Sender disconnect is detected reliably.

---

## M2 — Browser video over WebRTC

### Goal

Deliver live mirrored video to one browser.

### Tasks

- [ ] Build Media Worker around GStreamer.
- [ ] Receive UxPlay video RTP.
- [ ] Parse and normalize H.264.
- [ ] Build initial `webrtcbin` pipeline.
- [ ] Implement WebSocket signaling in FastAPI.
- [ ] Implement browser `RTCPeerConnection` client.
- [ ] Exchange SDP and ICE.
- [ ] Attach remote stream to `<video>`.
- [ ] Add session IDs and browser reconnect behavior.
- [ ] Capture `getStats()` metrics.

### Primary experiment

Attempt zero-transcode video first:

```text
RTP/H.264 -> depay -> parse -> pay -> WebRTC
```

If browser negotiation rejects the stream, document exactly why before adding transcoding.

### Exit criteria

- One browser displays the live iPhone/iPad/Mac mirrored screen.
- Chrome/Edge on Windows works.
- Chrome or Safari on macOS works.
- Browser refresh can recover without manual server restart.
- Baseline 1080p/30 is stable on a normal wired/Wi-Fi LAN.
- End-to-end latency is measured and recorded.

### Decision gate

After M2, write an ADR covering:

- observed H.264 profile/level
- whether passthrough works
- whether transcode fallback is required
- selected WebRTC offer/answer ownership model

---

## M3 — Audio and A/V synchronization

### Goal

Add reliable browser audio and maintain sync.

### Tasks

- [ ] Receive UxPlay L16 RTP audio.
- [ ] Normalize sample format/rate/channels.
- [ ] Encode audio to Opus.
- [ ] Add Opus track to WebRTC session.
- [ ] Measure A/V drift over 30+ minute sessions.
- [ ] Add jitter buffering/queue tuning as needed.
- [ ] Handle browser autoplay restrictions gracefully.
- [ ] Add mute/unmute UI.

### Exit criteria

- Browser receives both video and audio.
- Long-running A/V drift is not visibly disruptive.
- Disconnect/reconnect does not leave stuck audio pipelines.
- Browser autoplay policy failures produce a clear user action instead of silent failure.

---

## M4 — Product shell

### Goal

Turn the prototype into a usable browser product.

### Viewer states

- `BOOTING`
- `READY`
- `CONNECTING`
- `PLAYING`
- `RECONNECTING`
- `ERROR`

### Tasks

- [ ] Build full-screen display page.
- [ ] Show receiver name and readiness.
- [ ] Show sender/session information when available.
- [ ] Automatically transition from idle to playback.
- [ ] Automatically return to idle after sender disconnect.
- [ ] Add fullscreen button.
- [ ] Add stream stats panel.
- [ ] Add receiver restart action.
- [ ] Add human-readable error diagnostics.
- [ ] Add responsive layout for desktop browsers.

### Exit criteria

A non-technical user can:

1. Open the CastBridge page.
2. See which receiver name to select.
3. Start Screen Mirroring on an Apple device.
4. See the stream automatically.
5. Stop mirroring and see the page return to ready state.

---

## M5 — Reliability and packaging

### Goal

Make CastBridge deployable as a LAN service rather than a developer demo.

### Tasks

- [ ] Define supported Linux distribution(s).
- [ ] Add receiver/media process supervision.
- [ ] Add startup readiness checks.
- [ ] Add automatic restart with rate limiting.
- [ ] Add `/api/health` and `/api/ready` detail.
- [ ] Add log rotation/structured logging guidance.
- [ ] Add configuration file/environment variables.
- [ ] Test host-native systemd deployment.
- [ ] Evaluate Docker/host-network deployment.
- [ ] Add HTTPS reverse-proxy example.
- [ ] Add upgrade/uninstall documentation.
- [ ] Define third-party dependency/license packaging policy.

### Reliability tests

- [ ] 8-hour idle test.
- [ ] 4-hour continuous cast test.
- [ ] 50 connect/disconnect cycles.
- [ ] 20 browser refresh/reconnect cycles during an active cast.
- [ ] Sender disappears unexpectedly.
- [ ] Receiver process is killed and recovers.
- [ ] Media process is killed and recovers.

### Exit criteria

A clean Linux machine can follow the install documentation and become a functioning CastBridge receiver without editing source code.

---

## M6 — Multi-viewer mode

### Goal

Allow more than one browser to watch the same active cast.

### First step

Benchmark direct peer-per-viewer fan-out.

### Decision threshold

If CPU/bandwidth scales poorly, introduce an SFU rather than duplicating expensive media work.

Potential technologies to evaluate at that point:

- LiveKit
- mediasoup
- Pion-based service

Do not introduce an SFU before actual measurements justify it.

### Exit criteria

- At least 3 browser viewers can watch one cast on the target LAN hardware.
- New viewers can join while a session is already active.
- One viewer disconnecting does not affect others.

---

## M7 — Additional receiver protocols

Each protocol is its own research/prototype milestone. Do not couple their schedules.

### Miracast

Research areas:

- Miracast Sink implementation options.
- Wi-Fi Direct hardware/driver requirements.
- Infrastructure mode / MS-MICE feasibility.
- Linux NetworkManager/wpa_supplicant conflicts.
- RTP extraction into the existing Media Bridge.

Desired result:

```text
Windows / supported Android
        -> Miracast
        -> CastBridge
        -> existing WebRTC viewer
```

### Google Cast

Research areas:

- Device discovery.
- Receiver authentication/certification constraints.
- Difference between Cast Web Receiver applications and implementing a Cast-capable hardware/software receiver.
- Whether a compliant self-hosted generic receiver is practical for the project.

Do not advertise Google Cast compatibility until interoperability is demonstrated against real sender applications.

### DLNA

DLNA is useful for media playback but is not equivalent to whole-screen mirroring. Treat it as a separate "play media to CastBridge" feature.

---

# Suggested implementation order

The development order should be:

```text
1. Repository skeleton
2. UxPlay lifecycle
3. RTP video inspection
4. WebRTC video
5. Audio
6. Session lifecycle
7. Vue product UI
8. Reliability
9. Packaging
10. Multi-viewer
11. More protocols
```

Avoid spending significant effort on branding, dashboards, permissions, or protocol abstractions before item 4 works.

---

# Initial issue breakdown

When implementation begins, the first work items should be small enough to complete and test independently:

1. **Bootstrap FastAPI backend**
   - health endpoint
   - settings model
   - structured logging

2. **Bootstrap Vue frontend**
   - router
   - API client
   - ready/health page

3. **Implement UxPlay supervisor**
   - subprocess start/stop
   - receiver name configuration
   - log capture
   - state events

4. **Create RTP probe pipeline**
   - video UDP port
   - audio UDP port
   - inspect caps and timestamps

5. **Create WebRTC proof-of-concept**
   - GStreamer `webrtcbin`
   - WebSocket signaling
   - one browser video track

6. **Integrate receiver session with WebRTC viewer**
   - active session event
   - auto-start viewer
   - cleanup on disconnect

---

# Definition of v0.1

v0.1 is complete when all of the following are true:

- CastBridge runs on the documented Linux host.
- An iPhone/iPad/Mac discovers it through native AirPlay Screen Mirroring.
- The sender can connect without a custom sender application.
- A Windows or macOS browser can open the CastBridge web page and watch the screen.
- Audio works.
- The system survives routine connect/disconnect and browser-refresh cycles.
- Logs and status information are sufficient to troubleshoot common failures.
- Installation and operation are documented.

Anything beyond this definition belongs to a later release.