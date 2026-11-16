from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest

SPEC = importlib.util.spec_from_file_location("check_logs", Path(__file__).with_name("check_logs.py"))
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

CASES = (
    ("ERROR Authorization: Basic dXNlcjpwYXNzd29yZA==", "dXNlcjpwYXNzd29yZA"),
    ('ERROR {"password": "two words secret"}', "two words"),
    ('ERROR {"private_key": "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADAN"}', "MIIEvQIBADAN"),
    ("ERROR header x-api-key SUPERSECRETVALUE sent", "SUPERSECRETVALUE"),
    ("ERROR connect https://admin:HUNTER2PASS@db.example.com/x", "HUNTER2PASS"),
    ("ERROR cookie session=SESSIONVALUE123 expired", "SESSIONVALUE123"),
    ("ERROR got Bearer BEARERVALUE999 rejected", "BEARERVALUE999"),
    ("ERROR token=abc123SECRET failed", "abc123SECRET"),
    ("ERROR bad eyJhbGciOi.eyJzdWIiOiIx.SIGPART123 jwt", "SIGPART123"),
    ("ERROR bad ya29.OAUTHACCESS123 sent", "OAUTHACCESS123"),
    ("ERROR bad 1//REFRESHTOK456 sent", "REFRESHTOK456"),
    ("ERROR oobCode OOBVALUE1 used", "OOBVALUE1"),
    ("ERROR auth INTERNALAUTH1 failed", "INTERNALAUTH1"),
    ("ERROR seed SEEDWORDS1 loaded", "SEEDWORDS1"),
    ("ERROR pass PASSVALUE1 wrong", "PASSVALUE1"),
    ("ERROR GET /invite?t=INVITETOKEN1&c=other HTTP/1.1 sent", "INVITETOKEN1"),
    ("ERROR GET /invite?t=INVITETOKEN1&c=OTHERVAL2 ok", "OTHERVAL2"),
    ("ERROR Authorization: Token TOKENVALUE777", "TOKENVALUE777"),
    ("ERROR Authorization: Digest username=bob response=DIGESTRESP1", "DIGESTRESP1"),
    ("ERROR Cookie: a=ONEVAL1; b=TWOVAL2; c=THREEVAL3", "TWOVAL2"),
    ("ERROR using xkeysib-abcdef123456 to send", "abcdef123456"),
    ("ERROR key AIzaSyA1B2C3D4E5 invalid", "A1B2C3D4E5"),
    ("ERROR sk-live9876543 rejected", "live9876543"),
    ('ERROR {\"password\": \"ESCAPEDPASS\"}', "ESCAPEDPASS"),
    ("ERROR pwd=PWDVALUE1 bad", "PWDVALUE1"),
    ("ERROR passphrase=PHRASEVAL1 bad", "PHRASEVAL1"),
    ("ERROR otp=482913 bad", "482913"),
    ("ERROR signature=SIGVALUE1 bad", "SIGVALUE1"),
    ("ERROR password is MYPASSIS1 wrong", "MYPASSIS1"),
    ("ERROR password=p@ss@word1 wrong", "word1"),
    ("ERROR ghp_GITHUBTOKEN123 revoked", "GITHUBTOKEN123"),
    ("ERROR connect https://us:p@ss@host.example/x", "p@ss"),
    ("ERROR sign-in failed with hunter2-Passw0rd as password", "hunter2-Passw0rd"),
    ("ERROR mailed https://c.example/#staffInvite=stf_0123456789abcdef01234567.Zm9vYmFy", "Zm9vYmFy"),
    ("ERROR request 0123456789abcdef0123456789abcdef failed", "0123456789abcdef0123456789abcdef"),
    ("ERROR upstream gave Zx9Kq2Lm8Vb4Nc7Rt1Yw5Hd3Jf6Gs0PaQeUiOp", "Zx9Kq2Lm8Vb4Nc7Rt1Yw5Hd3Jf6Gs0PaQeUiOp"),
    ("ERROR invitation ABCD-2345-EFGH was reused", "ABCD-2345-EFGH"),
    ('1.2.3.4 - - "POST /staff/v1/session HTTP/1.1" 500 21 apikey=PLAINVALUE', "PLAINVALUE"),
    ('1.2.3.4 - - "GET /x HTTP/1.1" 500 21 0123456789abcdef0123456789abcdef', "0123456789abcdef0123456789abcdef"),
    ("ERROR Brevo refused xsmtpsib-9f3c2a77d1e04b6f for the smtp key", "9f3c2a77d1e04b6f"),
)


@pytest.mark.parametrize("line,secret", CASES)
def test_secret_never_printed(tmp_path: Path, capsys: pytest.CaptureFixture[str], line: str, secret: str) -> None:
    log = tmp_path / "app.log"
    log.write_text(line + "\n", encoding="utf-8")
    assert MODULE.main([str(log)]) == 1
    assert secret not in capsys.readouterr().out


def test_error_keyword_and_status_stay_readable(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    log = tmp_path / "app.log"
    log.write_text("ERROR 502 upstream password=hidden1\n", encoding="utf-8")
    MODULE.main([str(log)])
    assert "ERROR 502 upstream" in capsys.readouterr().out


def test_corrupt_state_exits_2(tmp_path: Path) -> None:
    log = tmp_path / "app.log"
    log.write_text("ERROR x\n", encoding="utf-8")
    state = tmp_path / "state.json"
    state.write_text("{not json", encoding="utf-8")
    assert MODULE.main([str(log), "--state", str(state)]) == 2


def test_http_status_stays_visible_when_path_has_a_sensitive_word(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    log = tmp_path / "app.log"
    log.write_text('1.2.3.4 - - "POST /staff/v1/session HTTP/1.1" 500 21\n', encoding="utf-8")
    MODULE.main([str(log)])
    assert '" 500 21' in capsys.readouterr().out


def test_rotated_log_is_read_from_the_start(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    log = tmp_path / "app.log"
    state = tmp_path / "state.json"
    log.write_text("INFO old line one is long enough\nERROR first\n", encoding="utf-8")
    assert MODULE.main([str(log), "--state", str(state)]) == 1
    log.write_text("INFO new file starts different and is longer than before\nERROR second after rotation\n", encoding="utf-8")
    assert MODULE.main([str(log), "--state", str(state)]) == 1
    assert "second after rotation" in capsys.readouterr().out


def test_normal_error_line_stays_readable(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    log = tmp_path / "app.log"
    line = "2026-11-15T12:30:45,123 ERROR /api/v1/orders/42 failed status=503 id a1b2c3 trace line 88"
    log.write_text(line + "\n", encoding="utf-8")
    MODULE.main([str(log)])
    assert line in capsys.readouterr().out


def test_request_id_is_masked_and_status_stays(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    log = tmp_path / "app.log"
    log.write_text('ERROR req 0123456789abcdef0123456789abcdef "GET /x HTTP/1.1" 500 9\n', encoding="utf-8")
    MODULE.main([str(log)])
    assert 'ERROR req *** "GET /x HTTP/1.1" 500 9' in capsys.readouterr().out
