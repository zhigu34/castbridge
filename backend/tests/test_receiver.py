import json
import time
from pathlib import Path

from app.receiver import load_receiver_status


def test_receiver_status_missing(tmp_path: Path) -> None:
    status = load_receiver_status(tmp_path / "missing.json")
    assert status["healthy"] is False
    assert status["state"] == "unavailable"


def test_receiver_status_ready(tmp_path: Path) -> None:
    status_file = tmp_path / "receiver-status.json"
    status_file.write_text(
        json.dumps(
            {
                "state": "ready",
                "receiver_name": "CastBridge",
                "engine": "UxPlay",
                "engine_version": "1.74",
                "timestamp": "2026-09-12T00:00:00Z",
                "timestamp_epoch": int(time.time()),
                "airplay_port": 7100,
                "video_rtp_port": 5000,
                "audio_rtp_port": 5002,
            }
        ),
        encoding="utf-8",
    )

    status = load_receiver_status(status_file)
    assert status["healthy"] is True
    assert status["state"] == "ready"
    assert status["engine"] == "UxPlay"
    assert status["airplay_port"] == 7100


def test_receiver_status_stale(tmp_path: Path) -> None:
    status_file = tmp_path / "receiver-status.json"
    status_file.write_text(
        json.dumps(
            {
                "state": "ready",
                "timestamp_epoch": int(time.time()) - 60,
            }
        ),
        encoding="utf-8",
    )

    status = load_receiver_status(status_file, stale_seconds=10)
    assert status["healthy"] is False
    assert status["message"] == "Receiver 心跳已过期"
