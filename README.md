# CastBridge

> Turn any browser into a wireless display.

CastBridge is a self-hosted casting gateway that receives native screen-casting protocols such as AirPlay and bridges the incoming media stream to WebRTC, so Windows, macOS, Linux, tablets, and other devices can watch the mirrored screen directly in a modern browser.

## Project status

**Early design / v0.1 planning.** The first milestone intentionally focuses on one reliable end-to-end path:

**iPhone / iPad / Mac → AirPlay → CastBridge → WebRTC → Browser**

Miracast, Google Cast, DLNA, multi-viewer distribution, and remote deployment are planned as later phases.

## Why CastBridge?

Most wireless-display receivers render into a native application or directly to HDMI. CastBridge separates the **receiver** from the **viewer**:

```text
Sender                           CastBridge                         Viewer
┌──────────────┐                ┌──────────────────────┐           ┌────────────────────┐
│ iPhone/iPad  │ -- AirPlay --> │ Receiver / Media GW  │ --WebRTC->│ Chrome / Edge      │
│ Mac          │                │                      │           │ Safari / Firefox   │
└──────────────┘                └──────────────────────┘           └────────────────────┘
```

The sender sees CastBridge as a normal casting target. The viewer only needs a browser.

## Goals

- Be discoverable as a native AirPlay receiver in the LAN.
- Receive screen mirroring without requiring a custom sender app.
- Forward media to browsers with low latency through WebRTC.
- Allow Windows and macOS viewers to watch with no local installation.
- Keep the control plane and media plane separated.
- Provide a clean Web UI for receiver state, active sessions, playback, and diagnostics.
- Make deployment reproducible on a Linux host.
- Leave a clean extension path for Miracast, Google Cast, DLNA, and SFU-based multi-viewer delivery.

## Non-goals for v0.1

- Implementing the AirPlay protocol from scratch.
- Miracast / Wi-Fi Direct support.
- Google Cast receiver compatibility.
- Public-Internet traversal as the primary use case.
- Remote keyboard/mouse control of the sender.
- DRM-protected content bypass.
- 4K/60 as a launch requirement.

## v0.1 architecture

```text
                         ┌───────────────────────────────┐
                         │          CastBridge           │
                         │                               │
 iPhone / iPad / Mac     │  ┌──────────┐   RTP H.264   │
        │                │  │ UxPlay   │──────────────┐│
        │ AirPlay        │  │ receiver │              ││
        └───────────────►│  └──────────┘              ▼│
                         │                      ┌──────────────┐
                         │                      │ GStreamer    │
                         │                      │ media bridge │
                         │                      └──────┬───────┘
                         │                             │ WebRTC
                         │  ┌──────────────┐           │
                         │  │ FastAPI      │◄──────────┘
                         │  │ signaling /  │
                         │  │ sessions     │
                         │  └──────┬───────┘
                         └─────────┼─────────────────────┘
                                   │
                                   ▼
                         ┌──────────────────────┐
                         │ Vue 3 + TypeScript   │
                         │ Browser display      │
                         └──────────────────────┘
```

### Proposed stack

| Layer | Technology | Responsibility |
| --- | --- | --- |
| Native receiver | UxPlay | AirPlay discovery, session handling, decrypted media output |
| Media pipeline | GStreamer | RTP ingest, codec handling, WebRTC transport |
| WebRTC | GStreamer `webrtcbin` | SDP/ICE/media transport to browsers |
| API / signaling | FastAPI | Sessions, WebSocket signaling, status, health APIs |
| Web UI | Vue 3 + TypeScript | Viewer, full-screen display, session status, diagnostics |
| Deployment | Docker / systemd | Repeatable LAN deployment |

UxPlay 1.73+ exposes `-vrtp` and `-artp`, which makes it possible to forward received media to an external pipeline instead of rendering it locally. The initial design uses that capability rather than modifying the AirPlay receiver itself.

## Repository layout

```text
castbridge/
├── backend/                 # FastAPI application
├── frontend/                # Vue 3 + TypeScript web UI
├── media/                   # GStreamer / WebRTC integration
├── receiver/                # Receiver process integration
├── deploy/                  # Docker, systemd, reverse proxy
├── docs/
│   ├── ARCHITECTURE.md
│   └── ROADMAP.md
└── README.md
```

The directories above are the target structure; implementation directories will be added as each milestone starts.

## Target user flow

1. Deploy CastBridge on a Linux host in the local network.
2. Open the CastBridge display page on Windows or macOS.
3. On an iPhone/iPad/Mac, open **Screen Mirroring / AirPlay**.
4. Select the CastBridge receiver name.
5. The incoming screen appears in the browser through WebRTC.
6. When the sender disconnects, the browser returns to the idle screen automatically.

## Performance targets for v0.1

- 1080p screen mirroring.
- 30 FPS baseline; 60 FPS considered after the baseline is stable.
- LAN glass-to-glass latency target: **< 300 ms**, with optimization work aiming lower.
- Automatic recovery from sender disconnects and viewer refreshes.
- Prefer H.264 passthrough/repacketization where browser negotiation permits it; avoid decode/re-encode unless necessary.

## Security model

The first release is LAN-first, but it will still enforce basic boundaries:

- Browser signaling is authenticated or protected by a short-lived display/session token before multi-user deployment.
- Receiver and viewer sessions are explicitly paired by CastBridge.
- Web UI should be served through HTTPS for production WebRTC/browser use.
- No attempt will be made to circumvent DRM-protected playback.
- External access is out of scope until authentication and TURN policy are defined.

## Documentation

- [Architecture](docs/ARCHITECTURE.md)
- [Roadmap and implementation plan](docs/ROADMAP.md)

## Planned milestones

- **M0 — Project foundation:** repository, architecture, development environment.
- **M1 — AirPlay ingest:** UxPlay receiver starts reliably and exports video/audio RTP.
- **M2 — Browser video:** RTP H.264 reaches a browser over WebRTC.
- **M3 — Audio + A/V sync:** browser receives synchronized audio and video.
- **M4 — Product shell:** Vue viewer, session states, full-screen mode, diagnostics.
- **M5 — Packaging:** Linux deployment, health checks, logs, restart strategy.
- **M6 — Protocol expansion:** evaluate Miracast, Google Cast, and DLNA separately.

See [ROADMAP.md](docs/ROADMAP.md) for acceptance criteria and sequencing.

## License

A project license has **not yet been selected**. UxPlay is GPL-3.0 licensed, so packaging and distribution boundaries must be reviewed before CastBridge chooses its final license and release model.

---

**CastBridge — native casting in, WebRTC out.**