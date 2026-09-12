# CastBridge Architecture

## 1. Purpose

CastBridge turns native wireless-display input into browser-viewable real-time media.

The architectural rule is simple:

> **Casting protocols terminate at the CastBridge host; browsers only speak WebRTC and Web APIs.**

This avoids trying to make a browser itself implement AirPlay, Miracast, or Google Cast discovery and receiver behavior.

## 2. v0.1 scope

The first supported path is:

```text
Apple sender
(iPhone / iPad / Mac)
        │
        │ AirPlay
        ▼
     UxPlay
        │
        │ RTP video/audio
        ▼
  Media Bridge
   (GStreamer)
        │
        │ WebRTC
        ▼
Browser viewer
(Windows/macOS/Linux)
```

### In scope

- LAN AirPlay discovery and mirroring.
- One active sender per receiver instance.
- One browser viewer initially, with the internals designed to grow to multiple viewers.
- H.264 video baseline.
- Audio transport and A/V synchronization.
- WebRTC signaling over WebSocket.
- Session lifecycle and observability.
- Linux-first deployment.

### Out of scope

- AirPlay protocol reimplementation.
- Miracast / Wi-Fi Direct in v0.1.
- Google Cast in v0.1.
- Internet-first deployment.
- DRM bypass.
- Remote control of the sender.

## 3. Logical components

### 3.1 Receiver Manager

Responsible for running and supervising the native receiver process.

Responsibilities:

- Start/stop UxPlay.
- Set the advertised receiver name.
- Allocate RTP output ports.
- Detect receiver readiness.
- Detect sender connection/disconnection.
- Collect stdout/stderr into structured application logs.
- Restart the receiver after recoverable failures.
- Expose receiver state to the backend.

The Receiver Manager should treat UxPlay as an external process rather than embedding or modifying it in v0.1.

### 3.2 Media Bridge

Responsible for translating the incoming RTP media into a browser-compatible WebRTC session.

Expected pipeline responsibilities:

- Receive H.264/H.265 RTP video exported by UxPlay.
- Receive L16 RTP audio exported by UxPlay.
- Inspect the video codec and negotiated browser capabilities.
- Prefer H.264 repacketization/passthrough where possible.
- Transcode only when negotiation or stream format makes passthrough impossible.
- Encode browser audio as Opus.
- Maintain timestamps and A/V synchronization.
- Expose WebRTC statistics and pipeline health.

Conceptual video path:

```text
UxPlay RTP/H264
    │
    ▼
udpsrc
    │
rtph264depay
    │
h264parse
    │
rtph264pay
    │
webrtcbin
    │
    ▼
Browser
```

Conceptual audio path:

```text
UxPlay RTP/L16
    │
    ▼
udpsrc
    │
RTP depay
    │
audioconvert / audioresample
    │
opusenc
    │
rtpopuspay
    │
webrtcbin
    │
    ▼
Browser
```

These are design-level pipelines. Exact caps, payload types, clock rates, queueing, and jitter handling must be validated with real UxPlay output before being hard-coded.

### 3.3 Backend / Control Plane

FastAPI owns the control plane, not the media plane.

Responsibilities:

- WebSocket signaling for SDP and ICE.
- Receiver status API.
- Display/viewer registration.
- Session lifecycle.
- Health/readiness endpoints.
- Configuration API.
- Event stream to the web UI.
- Authentication/token checks once enabled.

The backend must not relay raw video frames.

### 3.4 Frontend

Vue 3 + TypeScript provides the browser display surface.

Primary states:

```text
BOOTING
  ↓
READY
  ↓
CONNECTING
  ↓
PLAYING
  ↓
DISCONNECTED
  ↓
READY
```

The initial viewer should support:

- Idle/ready screen.
- Advertised receiver name.
- Active-sender indicator.
- WebRTC playback.
- Fullscreen mode.
- Audio mute/unmute.
- Basic stream diagnostics.
- Error and reconnect states.

## 4. Process architecture

A practical v0.1 deployment may run four processes:

```text
┌───────────────────────────────────────────────┐
│ Linux host                                    │
│                                               │
│  castbridge-api        FastAPI                │
│       │                                       │
│       ├─────────────┐                         │
│       │             │                         │
│  receiver-manager   │                         │
│       │             │                         │
│     UxPlay          │                         │
│       │             │                         │
│   RTP video/audio   │                         │
│       ▼             ▼                         │
│  media-worker / GStreamer                     │
│       │                                       │
│       │ WebRTC                                │
└───────┼───────────────────────────────────────┘
        │
        ▼
 Browser viewer
```

The first implementation can keep Receiver Manager and Media Worker inside the FastAPI service process if that speeds up development, but their interfaces should remain separable so they can be split later.

## 5. Session model

A CastBridge session represents one sender mirroring session.

Suggested model:

```text
CastSession
├── id
├── receiver_id
├── state
├── sender_protocol        # airplay initially
├── sender_name            # when detectable
├── started_at
├── ended_at
├── video_codec
├── video_width
├── video_height
├── video_fps
├── audio_codec
├── viewer_count
└── failure_reason
```

Suggested states:

```text
IDLE
RECEIVER_CONNECTED
MEDIA_DETECTED
WEBRTC_NEGOTIATING
STREAMING
STOPPING
ENDED
FAILED
```

State changes should be emitted as events so the web UI does not poll aggressively.

## 6. WebRTC signaling

### WebSocket

Proposed endpoint:

```text
/ws/displays/{display_id}
```

Message envelope:

```json
{
  "type": "webrtc.offer",
  "session_id": "...",
  "payload": {}
}
```

Initial message types:

- `display.hello`
- `receiver.state`
- `session.started`
- `session.ended`
- `webrtc.offer`
- `webrtc.answer`
- `webrtc.ice`
- `webrtc.restart`
- `stream.stats`
- `error`

The exact offerer role should be chosen after validating the GStreamer integration. Either browser-offer or server-offer can work; consistency matters more than the choice.

## 7. REST API sketch

Initial endpoints:

```text
GET  /api/health
GET  /api/ready
GET  /api/v1/receiver
GET  /api/v1/session
GET  /api/v1/config
PUT  /api/v1/config/receiver
POST /api/v1/receiver/restart
```

Configuration should begin small:

```json
{
  "receiver_name": "CastBridge",
  "video": {
    "prefer_h264": true,
    "max_width": 1920,
    "max_height": 1080,
    "max_fps": 30
  }
}
```

## 8. Networking

The host needs LAN reachability for two very different paths:

### Sender → CastBridge

AirPlay discovery/control/media ports are managed by the native receiver. LAN multicast/mDNS must not be blocked by container/network configuration.

This is an important Docker consideration: receiver discovery may require host networking or explicit multicast handling. The first working deployment should prefer simplicity over container isolation.

### Browser → CastBridge

The browser needs:

- HTTPS/HTTP for UI and API.
- WSS/WS for signaling.
- ICE candidate connectivity for WebRTC media.

For a same-LAN v0.1, host candidates may be sufficient. TURN is not required until routing/NAT scenarios are supported.

## 9. Deployment strategy

### Development

Recommended baseline:

```text
Linux host
├── UxPlay installed locally
├── GStreamer installed locally
├── FastAPI in Python virtualenv
└── Vue dev server
```

This minimizes networking surprises while the media path is being proven.

### v0.1 packaged deployment

Two viable paths should be evaluated after M3:

1. **Host-native services** using systemd for the receiver/media components plus a packaged frontend.
2. **Hybrid containers** where API/UI are containerized but the receiver/media services use host networking.

A fully isolated Docker Compose deployment should not be treated as a requirement until AirPlay discovery is validated under container networking.

## 10. Observability

Every major process should expose or report:

- uptime
- state
- active session ID
- restart count
- last error
- negotiated codec
- video resolution/fps
- RTP packet counters
- WebRTC RTT/jitter/loss where available
- current viewer count

Logs should carry `session_id` so a single cast can be traced across receiver, media, signaling, and browser events.

## 11. Failure recovery

Expected recovery behavior:

| Failure | Expected behavior |
| --- | --- |
| Browser refresh | Renegotiate WebRTC without restarting AirPlay if possible |
| Sender disconnect | Stop media worker, mark session ended, return UI to READY |
| UxPlay crash | Supervisor restarts it and UI reports temporary unavailable state |
| GStreamer failure | Tear down WebRTC, restart media worker, preserve receiver when possible |
| Signaling socket loss | Browser reconnects with bounded exponential backoff |
| Codec unsupported | Emit clear diagnostic; optionally fall back to transcode path later |

## 12. Security

v0.1 is LAN-first but should not bake in insecure assumptions.

Minimum design rules:

- Do not expose shell execution through the API.
- Sanitize configurable receiver names and command arguments.
- Do not construct UxPlay/GStreamer command lines from untrusted raw strings.
- Use structured subprocess argument arrays.
- Treat SDP and ICE as untrusted network input.
- Add display/session tokens before supporting shared or untrusted networks.
- Serve HTTPS in packaged deployments.
- Never claim compatibility with or attempt bypass of DRM-protected casting.

## 13. Third-party boundary

UxPlay is GPL-3.0 licensed. CastBridge should initially invoke it as a separate executable and document the dependency clearly. Before distributing bundled binaries/images, review the licensing implications of packaging UxPlay and its dependencies together with CastBridge.

The project license should be selected only after that packaging boundary is decided.

## 14. Expansion path

After the AirPlay path is stable, protocols should be added as independent receiver adapters:

```text
ReceiverAdapter
├── AirPlayAdapter
├── MiracastAdapter
├── CastAdapter
└── DlnaAdapter
```

Each adapter should normalize events into the same internal session/media model. The frontend and browser WebRTC layer should remain protocol-agnostic.

For multiple simultaneous browser viewers, evaluate an SFU rather than multiplying one upstream media pipeline per viewer.

## 15. Architecture decision checkpoints

The following questions must be answered by prototypes rather than assumption:

1. Can H.264 from UxPlay be repacketized into browser WebRTC without re-encoding reliably?
2. Which H.264 profile/level/packetization modes are emitted by real iPhone/iPad/macOS senders?
3. Does UxPlay's RTP timestamp behavior preserve stable A/V sync when audio is transcoded to Opus?
4. Should GStreamer or a separate WebRTC server own peer negotiation long-term?
5. What container networking model preserves reliable AirPlay discovery?
6. How many viewers can one media worker support before an SFU becomes necessary?

These answers determine the implementation after M2/M3 and should be documented as ADRs when proven.