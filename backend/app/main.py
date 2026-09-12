from datetime import UTC, datetime
from typing import Any
from uuid import uuid4

from fastapi import FastAPI, WebSocket, WebSocketDisconnect

from app.config import get_settings
from app.media import load_media_status
from app.receiver import load_receiver_status

settings = get_settings()

app = FastAPI(
    title="CastBridge API",
    version="0.2.0",
    description="CastBridge 控制面与 WebRTC 信令 API",
)

media_socket: WebSocket | None = None
viewer_sockets: dict[str, WebSocket] = {}


def receiver_snapshot() -> dict[str, Any]:
    return load_receiver_status(
        settings.receiver_status_file,
        stale_seconds=settings.receiver_stale_seconds,
    )


def media_snapshot() -> dict[str, Any]:
    snapshot = load_media_status(
        settings.media_status_file,
        stale_seconds=settings.media_stale_seconds,
    )
    snapshot["broker_connected"] = media_socket is not None
    snapshot["viewer_count"] = len(viewer_sockets)
    return snapshot


async def send_to_media(message: dict[str, Any]) -> bool:
    socket = media_socket
    if socket is None:
        return False
    try:
        await socket.send_json(message)
        return True
    except (RuntimeError, WebSocketDisconnect):
        return False


async def send_to_viewer(viewer_id: str, message: dict[str, Any]) -> bool:
    socket = viewer_sockets.get(viewer_id)
    if socket is None:
        return False
    try:
        await socket.send_json(message)
        return True
    except (RuntimeError, WebSocketDisconnect):
        return False


@app.get("/health", tags=["system"])
@app.get("/api/health", tags=["system"])
async def health() -> dict[str, str]:
    return {
        "status": "ok",
        "service": "castbridge-backend",
        "version": app.version,
    }


@app.get("/api/ready", tags=["system"])
async def ready() -> dict[str, str | bool]:
    receiver = receiver_snapshot()
    media = media_snapshot()
    return {
        "ready": True,
        "receiver": settings.receiver_name,
        "receiver_ready": bool(receiver["healthy"]),
        "receiver_state": str(receiver["state"]),
        "media_ready": bool(media["healthy"]),
        "media_state": str(media["state"]),
        "environment": settings.environment,
    }


@app.get("/api/v1/system", tags=["system"])
async def system_info() -> dict[str, str]:
    return {
        "name": "CastBridge",
        "receiver_name": settings.receiver_name,
        "environment": settings.environment,
        "time": datetime.now(UTC).isoformat(),
    }


@app.get("/api/v1/receiver", tags=["receiver"])
async def receiver_info() -> dict[str, Any]:
    return receiver_snapshot()


@app.get("/api/v1/media", tags=["media"])
async def media_info() -> dict[str, Any]:
    return media_snapshot()


@app.websocket("/ws/system")
async def system_socket(websocket: WebSocket) -> None:
    await websocket.accept()
    receiver = receiver_snapshot()
    media = media_snapshot()
    await websocket.send_json(
        {
            "type": "system.hello",
            "payload": {
                "receiver_name": settings.receiver_name,
                "receiver_ready": receiver["healthy"],
                "receiver_state": receiver["state"],
                "media_ready": media["healthy"],
                "media_state": media["state"],
                "version": app.version,
            },
        }
    )

    try:
        while True:
            message = await websocket.receive_text()
            await websocket.send_json({"type": "system.echo", "payload": {"message": message}})
    except WebSocketDisconnect:
        return


@app.websocket("/ws/media")
async def media_signaling_socket(websocket: WebSocket) -> None:
    global media_socket

    await websocket.accept()
    previous = media_socket
    media_socket = websocket
    if previous is not None and previous is not websocket:
        try:
            await previous.close(code=1012)
        except RuntimeError:
            pass

    await websocket.send_json({"type": "media.hello", "viewer_count": len(viewer_sockets)})
    for viewer_id in list(viewer_sockets):
        await websocket.send_json({"type": "viewer.connected", "viewer_id": viewer_id})

    try:
        while True:
            message = await websocket.receive_json()
            viewer_id = message.get("viewer_id")
            message_type = message.get("type")
            if not isinstance(viewer_id, str) or not isinstance(message_type, str):
                continue
            if message_type not in {"webrtc.offer", "webrtc.ice", "webrtc.state"}:
                continue
            await send_to_viewer(viewer_id, message)
    except WebSocketDisconnect:
        pass
    finally:
        if media_socket is websocket:
            media_socket = None
        for viewer_id in list(viewer_sockets):
            await send_to_viewer(viewer_id, {"type": "media.offline"})


@app.websocket("/ws/viewer")
async def viewer_signaling_socket(websocket: WebSocket) -> None:
    viewer_id = uuid4().hex[:12]
    await websocket.accept()
    viewer_sockets[viewer_id] = websocket

    await websocket.send_json(
        {
            "type": "viewer.hello",
            "viewer_id": viewer_id,
            "media_connected": media_socket is not None,
        }
    )
    await send_to_media({"type": "viewer.connected", "viewer_id": viewer_id})

    try:
        while True:
            message = await websocket.receive_json()
            message_type = message.get("type")
            if message_type not in {"webrtc.answer", "webrtc.ice"}:
                continue
            message["viewer_id"] = viewer_id
            if not await send_to_media(message):
                await websocket.send_json({"type": "media.offline"})
    except WebSocketDisconnect:
        pass
    finally:
        viewer_sockets.pop(viewer_id, None)
        await send_to_media({"type": "viewer.disconnected", "viewer_id": viewer_id})
