import json
import logging

from cloudlaunch_api.enums import Event
from cloudlaunch_api.logs import REDACTED, JsonFormatter, log_event


def make_logger(name):
    logger = logging.getLogger(name)
    logger.setLevel(logging.INFO)
    logger.propagate = False
    return logger


def capture_record(logger, handler_records):
    class Capture(logging.Handler):
        def emit(self, record):
            handler_records.append(record)

    logger.handlers = [Capture()]
    return logger


def test_log_event_emits_json_with_fields():
    records = []
    logger = capture_record(make_logger("test.json"), records)

    log_event(logger, Event.REQUEST_COMPLETED, request_id="req-1", status=200, duration_ms=1.5)
    payload = json.loads(JsonFormatter().format(records[0]))

    assert payload["event"] == "request_completed"
    assert payload["requestId"] == "req-1"
    assert payload["status"] == 200
    assert payload["level"] == "INFO"
    assert payload["timestamp"]


def test_log_event_redacts_sensitive_keys():
    records = []
    logger = capture_record(make_logger("test.redact"), records)

    log_event(
        logger,
        Event.WIREGUARD_APPLY_STARTED,
        private_key="secret-key",
        auth_token="secret-token",
        password="secret-pass",
        wireguard_config="[Interface]",
        firebase_credentials_file="/tmp/service-account.json",
        client_id="abc",
    )
    payload = json.loads(JsonFormatter().format(records[0]))

    assert payload["privateKey"] == REDACTED
    assert payload["authToken"] == REDACTED
    assert payload["password"] == REDACTED
    assert payload["wireguardConfig"] == REDACTED
    assert payload["firebaseCredentialsFile"] == REDACTED
    assert payload["clientId"] == "abc"


def test_log_event_redacts_nested_sensitive_fields():
    records = []
    logger = capture_record(make_logger("test.nested"), records)

    log_event(
        logger,
        Event.REQUEST_FAILED,
        metadata={"token": "secret-token", "safe": "value"},
    )
    payload = json.loads(JsonFormatter().format(records[0]))

    assert payload["metadata"]["token"] == REDACTED
    assert payload["metadata"]["safe"] == "value"


def test_log_event_drops_none_fields():
    records = []
    logger = capture_record(make_logger("test.none"), records)

    log_event(logger, Event.REQUEST_RECEIVED, request_id="req-1", email=None)
    payload = json.loads(JsonFormatter().format(records[0]))

    assert "email" not in payload


def test_formatter_redacts_sensitive_exception_message():
    records = []
    logger = capture_record(make_logger("test.exc"), records)

    try:
        raise ValueError("token=secret")
    except ValueError:
        logger.exception("failed")
    payload = json.loads(JsonFormatter().format(records[0]))

    assert payload["exceptionType"] == "ValueError"
    assert payload["exceptionMessage"] == REDACTED
