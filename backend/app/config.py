from functools import lru_cache

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


@lru_cache
def get_settings() -> Settings:
    return Settings()
