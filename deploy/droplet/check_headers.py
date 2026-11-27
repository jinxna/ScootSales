from __future__ import annotations

import re
import socket
import ssl
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import nginx_site

CONTROL_TEMPLATE = HERE / "nginx-control.https.conf.tpl"
PROMO_TEMPLATE = HERE / "nginx-promo.https.conf.tpl"
ADD_HEADER = re.compile(r'^\s*add_header\s+(\S+)\s+"(.*)"\s+always;\s*$')


def template_expected(template: Path) -> dict[str, str]:
    found = {}
    for line in template.read_text(encoding="utf-8").splitlines():
        match = ADD_HEADER.match(line)
        if match:
            found[match.group(1)] = match.group(2)
    return found


def expected_for(host: str, control_host: str, promo_host: str) -> dict[str, str]:
    if host == control_host:
        return template_expected(CONTROL_TEMPLATE)
    if host == promo_host:
        return template_expected(PROMO_TEMPLATE)
    return dict(nginx_site.SECURITY_HEADERS)


def fetch_headers(host: str, address: str) -> dict[str, str]:
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    with socket.create_connection((address, 443), timeout=10) as raw:
        with context.wrap_socket(raw, server_hostname=host) as tls:
            tls.sendall(f"HEAD / HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n".encode())
            data = b""
            while b"\r\n\r\n" not in data:
                chunk = tls.recv(65536)
                if not chunk:
                    break
                data += chunk
    headers = {}
    for line in data.decode("latin-1").split("\r\n")[1:]:
        if ":" in line:
            name, value = line.split(":", 1)
            headers[name.strip().lower()] = value.strip()
    return headers


def compare(expected: dict[str, str], live: dict[str, str]) -> list[str]:
    problems = []
    for name, value in expected.items():
        got = live.get(name.lower())
        if got is None:
            problems.append(f"missing {name}")
        elif got != value:
            problems.append(f"different {name}: live value does not match the installed config")
    return problems


def main(argv: list[str]) -> int:
    args = [a for a in argv if not a.startswith("--")]
    control_host = "control.scootsales.my"
    promo_host = "site.scootsales.my"
    address = "127.0.0.1"
    for flag in argv:
        if flag.startswith("--address="):
            address = flag.split("=", 1)[1]
        if flag.startswith("--control-host="):
            control_host = flag.split("=", 1)[1]
        if flag.startswith("--promo-host="):
            promo_host = flag.split("=", 1)[1]
    if not args:
        print("Usage: check_headers.py HOST [HOST ...] [--address=IP] [--control-host=HOST] [--promo-host=HOST] [--print-expected]")
        return 2
    failed = 0
    for host in args:
        expected = expected_for(host, control_host, promo_host)
        if "--print-expected" in argv:
            print(f"{host}: expects {', '.join(expected)}")
            continue
        try:
            problems = compare(expected, fetch_headers(host, address))
        except OSError as error:
            problems = [f"cannot connect: {error}"]
        if problems:
            failed = 1
            print(f"FAIL  {host}: {'; '.join(problems)}")
        else:
            print(f"OK    {host}: all {len(expected)} security headers match the installed config")
    return failed


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
