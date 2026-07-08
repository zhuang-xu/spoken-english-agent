from functools import lru_cache
from typing import Literal

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    app_name: str = "Spoken English Agent"
    database_path: str = "./data/spoken_agents.sqlite3"
    provider: Literal["mock", "azure"] = "mock"

    azure_openai_endpoint: str | None = None
    azure_openai_api_key: str | None = None
    azure_openai_api_version: str = "2024-10-21"
    azure_openai_deployment: str = "gpt-4o-mini"

    azure_speech_key: str | None = None
    azure_speech_region: str | None = None
    azure_speech_recognition_language: str = "en-US"
    azure_speech_voice: str = "en-US-JennyNeural"

    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8")


@lru_cache
def get_settings() -> Settings:
    return Settings()
