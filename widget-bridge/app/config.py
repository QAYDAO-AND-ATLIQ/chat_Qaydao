"""Configuration loaded from environment variables."""
from typing import List
from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", case_sensitive=True)

    # Chatwoot
    CHATWOOT_BASE_URL: str = "http://chatwoot-web:3000"
    CHATWOOT_API_TOKEN: str
    CHATWOOT_ACCOUNT_ID: int = 1
    WIDGET_INBOX_ID: int = 3   # WebWidget on qaydao.com
    WHATSAPP_INBOX_ID: int = 5  # WhatsApp Cloud (+966548456966)

    # WhatsApp template
    TEMPLATE_NAME: str = "time"  # switch to website_ooh_v1 once approved
    TEMPLATE_LANGUAGE: str = "ar"
    TEMPLATE_CATEGORY: str = "UTILITY"

    # Working hours (Asia/Riyadh)
    TIMEZONE: str = "Asia/Riyadh"
    OPEN_HOUR: int = 9       # 9:00 AM
    CLOSE_HOUR: int = 23     # 11:59 PM (close at 12:00)
    CLOSE_MINUTE: int = 59
    CLOSED_DAYS: List[int] = Field(default_factory=lambda: [4])
    # Python weekday: Mon=0, Tue=1, Wed=2, Thu=3, Fri=4, Sat=5, Sun=6

    # Redis (dedup)
    REDIS_URL: str = "redis://chatwoot-redis:6379/3"
    DEDUP_TTL_SECONDS: int = 86400  # 24h

    # Webhook security
    WEBHOOK_SECRET: str

    # Behavior toggles
    DRY_RUN: bool = True               # set False to actually send WhatsApp
    SEND_INTERNAL_NOTE: bool = True     # post note in original conversation
    ADD_TAG: bool = True                # tag contact "from_website"
    TAG_NAME: str = "from_website"
    OOH_LABEL: str = "after_hours"

    # Logging buffer
    STATS_BUFFER_SIZE: int = 200


settings = Settings()
