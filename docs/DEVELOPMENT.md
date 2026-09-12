# CastBridge Development Guide

## Development philosophy

CastBridge is a media/networking project first and a dashboard project second. Development should therefore validate protocol and media assumptions before adding abstractions or UI complexity.

The preferred workflow is:

1. Prove a media path with a minimal command-line pipeline.
2. Measure it.
3. Wrap it behind a stable interface.
4. Add UI only after the behavior is reproducible.

## Initial technology baseline

- Python 3.12+
- FastAPI
- Vue 3
- TypeScript
- Vite
- GStreamer 1.x with WebRTC plugins
- UxPlay as the initial AirPlay receiver

Exact dependency versions should be pinned when implementation starts and updated deliberately.

## Planned top-level structure

```text
backend/
frontend/
media/
receiver/
deploy/
docs/
```

### `backend/`

Owns API, configuration, signaling, session state, and process orchestration.

### `frontend/`

Owns the browser display surface and diagnostics UI.

### `receiver/`

Owns adapters and supervisors around native casting receivers. Protocol-specific behavior belongs here rather than leaking into the frontend.

### `media/`

Owns GStreamer pipelines, WebRTC integration, media capabilities, and statistics.

### `deploy/`

Owns systemd/Docker/reverse-proxy packaging after the core media path works.

## API design rules

- Keep media bytes out of FastAPI.
- Use typed request/response models.
- Prefer explicit session state transitions over implicit booleans.
- Use WebSocket events for live session changes.
- Include stable machine-readable error codes alongside human-readable messages.
- Add a `session_id` to logs/events as early as possible.

## Subprocess rules

UxPlay and GStreamer command invocation is security-sensitive.

- Never build shell command strings from user input.
- Use argument arrays with shell execution disabled.
- Validate receiver names and media configuration.
- Capture stdout/stderr.
- Track exit code and restart count.
- Rate-limit automatic restart loops.
- Make shutdown graceful before sending a hard kill.

## Frontend rules

- The viewer should have a small explicit state machine.
- Playback state must not be inferred only from whether a `<video>` element has `srcObject`.
- Browser autoplay failures must become visible UI states.
- Fullscreen behavior should degrade gracefully when browser policies reject automatic fullscreen.
- Diagnostics should be optional and not obstruct the viewing surface.

## Media rules

- Prefer passthrough/repacketization before transcoding.
- Do not assume codec parameters; inspect real sender streams.
- Record the exact negotiated WebRTC SDP during early development, but do not persist it in normal production logs.
- Measure packet loss, jitter, RTT, bitrate, resolution, and frame rate.
- When transcoding becomes necessary, document why and benchmark CPU/GPU cost.

## Testing strategy

### Unit tests

Use unit tests for:

- configuration validation
- session state transitions
- signaling message validation
- receiver-process parsing
- command argument generation

### Integration tests

Use integration tests for:

- API + WebSocket lifecycle
- mocked receiver events
- media-worker startup/cleanup
- browser reconnect semantics

### Hardware/manual interoperability tests

Native casting requires real devices. Keep a compatibility matrix containing at least:

- sender device/model
- OS version
- protocol
- codec observed
- resolution/fps
- connection result
- audio result
- measured latency
- notes

Do not claim protocol/device compatibility based only on code paths or protocol documentation.

## Commit conventions

Use short conventional prefixes where practical:

```text
feat: ...
fix: ...
docs: ...
test: ...
refactor: ...
chore: ...
```

Prefer commits that represent one independently understandable change.

## Branching

Until multiple contributors require a heavier model:

- `main` should remain runnable.
- Use short-lived feature branches for non-trivial work.
- Merge through PRs once CI exists.

## Documentation decisions

Important architecture decisions discovered through prototypes should become ADRs under:

```text
docs/adr/
```

Examples:

- WebRTC offerer role.
- H.264 passthrough vs transcode strategy.
- Process topology.
- Deployment/networking model.
- SFU selection, if one is eventually required.

## Definition of done for technical milestones

A milestone is not complete because code compiles. It should have:

- a reproducible test path
- clear logs on failure
- cleanup on disconnect/shutdown
- measured behavior where performance matters
- relevant documentation updated

See [ROADMAP.md](ROADMAP.md) for milestone acceptance criteria.