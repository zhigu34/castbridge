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


def test_system_websocket() -> None:
    with client.websocket_connect("/ws/system") as websocket:
        hello = websocket.receive_json()
        assert hello["type"] == "system.hello"
        websocket.send_text("ping")
        echo = websocket.receive_json()
        assert echo["type"] == "system.echo"
        assert echo["payload"]["message"] == "ping"
