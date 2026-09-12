from functools import lru_cache
from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="CASTBRIDGE_",
        case_sensitive=False,
        extra="ignore",
    )

    environment: str = "development"
    receiver_name: str = "CastBridge"
    log_level: str = "INFO"
    receiver_status_file: Path = Path("/run/castbridge/receiver-status.json")
    receiver_stale_seconds: int = 10
    media_status_file: Path = Path("/run/castbridge/media-status.json")
    media_stale_seconds: int = 5


@lru_cache
def get_settings() -> Settings:
    return Settings()
