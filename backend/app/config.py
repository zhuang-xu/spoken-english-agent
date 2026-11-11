from functools import lru_cache

from pydantic import Field, SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Server configuration loaded from environment variables or .env."""

    app_name: str = "Spoken English Agent"
    database_path: str = "./data/spoken_agents.sqlite3"
    database_url: SecretStr = SecretStr("")
    database_maintenance: bool = False
    recordings_blob_container: str = ""
    recordings_blob_connection_string: SecretStr = SecretStr("")
    azure_openai_endpoint: str = ""
    azure_openai_api_key: SecretStr = SecretStr("")
    azure_openai_deployment: str = ""
    azure_openai_evaluation_deployment: str = ""
    # Must not exceed the deployed model's actual context capacity. Byte-level
    # token admission deliberately underfills this configured capacity.
    evaluation_context_capacity: int = Field(default=32768, ge=32768, le=2_000_000)
    azure_speech_key: SecretStr = SecretStr("")
    azure_speech_region: str = ""
    realtime_voice: str = "verse"
    entra_tenant_id: str = ""
    entra_api_audience: str = ""
    entra_scope: str = ""
    entra_allowed_client_ids: str = ""
    trust_azure_platform_auth: bool = False
    account_requests_per_minute: int = Field(default=120, ge=1)
    account_sessions_per_hour: int = Field(default=20, ge=1)
    account_evaluations_per_hour: int = Field(default=20, ge=1)

    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    @property
    def storage_path(self) -> str:
        url = self.database_url.get_secret_value()
        if url and not url.startswith(('postgresql://', 'postgres://')):
            raise ValueError('DATABASE_URL must be a PostgreSQL URI.')
        return url or self.database_path


@lru_cache
def get_settings() -> Settings:
    return Settings()
