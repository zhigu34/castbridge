from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_health() -> None:
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_ready() -> None:
    response = client.get("/api/ready")
    assert response.status_code == 200
    assert response.json()["ready"] is True
    assert "media_ready" in response.json()


def test_media_status() -> None:
    response = client.get("/api/v1/media")
    assert response.status_code == 200
    payload = response.json()
    assert "healthy" in payload
    assert "broker_connected" in payload
    assert "viewer_count" in payload
    assert "source_pipeline_active" in payload
    assert "viewer_encoder" in payload
    assert "viewer_encoded_idr_count" in payload
    assert "viewer_force_key_unit_events" in payload


def test_system_websocket() -> None:
    with client.websocket_connect("/ws/system") as websocket:
        hello = websocket.receive_json()
        assert hello["type"] == "system.hello"
        websocket.send_text("ping")
        echo = websocket.receive_json()
        assert echo["type"] == "system.echo"
        assert echo["payload"]["message"] == "ping"


def test_viewer_websocket() -> None:
    with client.websocket_connect("/ws/viewer") as websocket:
        hello = websocket.receive_json()
        assert hello["type"] == "viewer.hello"
        assert hello["viewer_id"]
        assert hello["media_connected"] is False
