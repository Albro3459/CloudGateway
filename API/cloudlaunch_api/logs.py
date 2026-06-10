import json
import logging
import re
import sys
from datetime import datetime, timezone
from typing import Any

from .enums import Event

REDACTED = "[redacted]"

_SENSITIVE_KEY_PARTS = (
    "authorization",
    "credential",
    "password",
    "privatekey",
    "private_key",
    "secret",
    "token",
    "wireguardconfig",
    "wireguard_config",
)
_SENSITIVE_VALUE_PATTERN = re.compile(
    r"(?i)(authorization|credential|password|private[_-]?key|secret|token|wireguard[_-]?config)"
)


def _normalized_key(key: str) -> str:
    return key.lower().replace("-", "_")


def _to_camel_key(key: str) -> str:
    parts = key.split("_")
    return parts[0] + "".join(part[:1].upper() + part[1:] for part in parts[1:])


def is_sensitive_key(key: str) -> bool:
    normalized = _normalized_key(key)
    compact = normalized.replace("_", "")
    return any(part in normalized or part in compact for part in _SENSITIVE_KEY_PARTS)


def redact_value(value: Any) -> Any:
    if isinstance(value, dict):
        return redact_fields(value)
    if isinstance(value, list):
        return [redact_value(item) for item in value]
    if isinstance(value, tuple):
        return tuple(redact_value(item) for item in value)
    if isinstance(value, str) and _SENSITIVE_VALUE_PATTERN.search(value):
        return REDACTED
    return value


def redact_fields(fields: dict[str, Any]) -> dict[str, Any]:
    return {
        _to_camel_key(key): REDACTED if is_sensitive_key(key) else redact_value(value)
        for key, value in fields.items()
    }


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, Any] = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": redact_value(record.getMessage()),
        }
        fields = getattr(record, "event_fields", None)
        if fields:
            payload.update(redact_fields(fields))
        if record.exc_info and record.exc_info[0] is not None:
            payload["exceptionType"] = record.exc_info[0].__name__
            payload["exceptionMessage"] = redact_value(str(record.exc_info[1]))
        return json.dumps(payload, default=str, separators=(",", ":"))


def setup_logging() -> None:
    logger = logging.getLogger("cloudlaunch_api")
    if logger.handlers:
        return
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    logger.addHandler(handler)
    logger.setLevel(logging.INFO)
    logger.propagate = False


def log_event(
    logger: logging.Logger,
    event: Event,
    *,
    level: int = logging.INFO,
    exc_info=None,
    **fields: Any,
) -> None:
    event_fields = {"event": event.value}
    event_fields.update({key: value for key, value in fields.items() if value is not None})
    logger.log(
        level,
        event.value,
        extra={"event_fields": redact_fields(event_fields)},
        exc_info=exc_info,
    )
