from datetime import UTC, datetime

from fastapi import FastAPI, WebSocket, WebSocketDisconnect

from app.config import get_settings

settings = get_settings()

app = FastAPI(
    title="CastBridge API",
    version="0.1.0",
    description="CastBridge 控制面与 WebRTC 信令 API",
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
    return {
        "ready": True,
        "receiver": settings.receiver_name,
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


@app.websocket("/ws/system")
async def system_socket(websocket: WebSocket) -> None:
    await websocket.accept()
    await websocket.send_json(
        {
            "type": "system.hello",
            "payload": {
                "receiver_name": settings.receiver_name,
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
