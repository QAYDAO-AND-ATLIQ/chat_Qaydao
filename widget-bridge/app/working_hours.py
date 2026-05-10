"""Business-hours logic for Asia/Riyadh."""
from datetime import datetime
from zoneinfo import ZoneInfo
from config import settings


def now_local() -> datetime:
    return datetime.now(tz=ZoneInfo(settings.TIMEZONE))


def is_business_hours(dt: datetime | None = None) -> bool:
    """Return True if dt (or now) falls inside QAYDAO business hours."""
    dt = dt or now_local()
    # weekday: Mon=0 ... Sun=6
    if dt.weekday() in settings.CLOSED_DAYS:
        return False
    if dt.hour < settings.OPEN_HOUR:
        return False
    if dt.hour > settings.CLOSE_HOUR:
        return False
    if dt.hour == settings.CLOSE_HOUR and dt.minute > settings.CLOSE_MINUTE:
        return False
    return True


def is_after_hours(dt: datetime | None = None) -> bool:
    return not is_business_hours(dt)


def status_line() -> str:
    n = now_local()
    return (
        f"{n.strftime('%Y-%m-%d %H:%M:%S %Z')} | "
        f"weekday={n.strftime('%A')} | "
        f"business_hours={is_business_hours(n)}"
    )
