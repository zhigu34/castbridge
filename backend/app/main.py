from datetime import UTC, datetime
from typing import Any

from fastapi import FastAPI, WebSocket, WebSocketDisconnect

from app.config import get_settings
from app.receiver import load_receiver_status

settings = get_settings()

app = FastAPI(
    title="CastBridge API",
    version="0.1.0",
    description="CastBridge 控制面与 WebRTC 信令 API",
)


def receiver_snapshot() -> dict[str, Any]:
    return load_receiver_status(
        settings.receiver_status_file,
        stale_seconds=settings.receiver_stale_seconds,
    )


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
    return {
        "ready": True,
        "receiver": settings.receiver_name,
        "receiver_ready": bool(receiver["healthy"]),
        "receiver_state": str(receiver["state"]),
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


@app.websocket("/ws/system")
async def system_socket(websocket: WebSocket) -> None:
    await websocket.accept()
    receiver = receiver_snapshot()
    await websocket.send_json(
        {
            "type": "system.hello",
            "payload": {
                "receiver_name": settings.receiver_name,
                "receiver_ready": receiver["healthy"],
                "receiver_state": receiver["state"],
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
