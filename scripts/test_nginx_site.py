import contextlib
import io
import re
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "deploy" / "droplet"))
import nginx_site

SITE_FILE = """server {
    listen 80;
    server_name scootsales.my www.scootsales.my;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name scootsales.my www.scootsales.my;
    ssl_certificate /etc/letsencrypt/live/scootsales.my/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/scootsales.my/privkey.pem;
    root /var/www/old-site;
    gzip on;
    gzip_types text/plain;
    location / {
        try_files $uri $uri/ /index.html;
    }
}

server {
    listen 443 ssl http2;
    server_name hardware.scootsales.my;
    ssl_certificate /etc/letsencrypt/live/hardware.scootsales.my/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/hardware.scootsales.my/privkey.pem;
    root /var/www/hardware;
    gzip on;
    location / {
        try_files $uri /index.html;
    }
}
"""

GZIP_DIRECTIVES = ("gzip", "gzip_vary", "gzip_proxied", "gzip_min_length", "gzip_types")


def render(path):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = nginx_site.rewrite(str(path), "scootsales.my", "/var/www/scootsales-dashboard/current", "acme", False)
    assert code == 0
    return out.getvalue()


def block_text(text, host):
    root = nginx_site.parse(text)
    block = [b for b in nginx_site.server_blocks(root) if host in nginx_site.server_names(b)][-1]
    return text[block.start:block.end], block


class DashboardSiteCompressionTests(unittest.TestCase):
    def test_dashboard_block_compresses_app_files_once_and_leaves_hardware_alone(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "site.conf"
            path.write_text(SITE_FILE, encoding="utf-8")
            first = render(path)
            path.write_text(first, encoding="utf-8")
            second = render(path)

        self.assertEqual(first, second)
        root = nginx_site.parse(first)
        dashboard = nginx_site.serving_blocks(root, "scootsales.my")
        self.assertEqual(len(dashboard), 1)
        for name in GZIP_DIRECTIVES:
            self.assertEqual(len(nginx_site.direct(dashboard[0], name)), 1, name)
        self.assertEqual(nginx_site.direct(dashboard[0], "gzip")[0].args, ["on"])
        types = nginx_site.direct(dashboard[0], "gzip_types")[0].args
        for mime in ("application/javascript", "application/wasm", "application/json", "text/css", "image/svg+xml", "font/ttf", "application/octet-stream"):
            self.assertIn(mime, types)
        self.assertEqual(block_text(SITE_FILE, "hardware.scootsales.my")[0], block_text(first, "hardware.scootsales.my")[0])


SHARED_LINE_SITE = """server {
    listen 443 ssl http2;
    server_name scootsales.my;
    ssl_certificate /etc/letsencrypt/live/scootsales.my/fullchain.pem; # managed by Certbot
%s
    location / {
        try_files $uri $uri/ /index.html;
    }
}

server {
    listen 443 ssl http2;
    server_name hardware.scootsales.my;
    root /var/www/hardware;
    add_header X-Frame-Options "SAMEORIGIN" always; gzip on;
    location / {
        try_files $uri /index.html;
    }
}
"""

NEW_ROOT = "/var/www/scootsales-dashboard/current"

ROOT_LINE = "\n    root /var/www/old;"

SHARED_LINE_CASES = {
    "gzip then root": ("    gzip on; root /var/www/old;", []),
    "add_header then root": ('    add_header X-Frame-Options "DENY" always; root /var/www/old;', []),
    "gzip then charset": ("    gzip on; charset utf-8;" + ROOT_LINE, ["charset"]),
    "add_header then charset": ('    add_header X-Frame-Options "DENY" always; charset utf-8;' + ROOT_LINE, ["charset"]),
    "two managed then charset": ("    gzip on; gzip_vary on; charset utf-8;" + ROOT_LINE, ["charset"]),
    "charset then gzip": ("    charset utf-8; gzip on;" + ROOT_LINE, ["charset"]),
    "gzip with its own comment": ("    gzip on; # compression" + ROOT_LINE, []),
}


class ManagedDirectiveRemovalTests(unittest.TestCase):
    def render_text(self, text):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "site.conf"
            path.write_text(text, encoding="utf-8")
            return render(path)

    def test_removing_a_managed_setting_keeps_every_setting_that_shared_its_line(self):
        for title, (body, kept) in SHARED_LINE_CASES.items():
            with self.subTest(title):
                source = SHARED_LINE_SITE % body
                first = self.render_text(source)
                self.assertEqual(self.render_text(first), first)
                dashboard_text, dashboard = block_text(first, "scootsales.my")
                self.assertEqual([r.args for r in nginx_site.direct(dashboard, "root")], [[NEW_ROOT]])
                for name in kept:
                    self.assertEqual(len(nginx_site.direct(dashboard, name)), 1, name)
                for name in GZIP_DIRECTIVES:
                    self.assertEqual(len(nginx_site.direct(dashboard, name)), 1, name)
                self.assertIn("fullchain.pem; # managed by Certbot", dashboard_text)
                self.assertIsNone(re.search(r"[ \t]+\n", dashboard_text))
                self.assertEqual(
                    block_text(source, "hardware.scootsales.my")[0], block_text(first, "hardware.scootsales.my")[0]
                )
        alone = SITE_FILE.replace("    gzip_types text/plain;\n", "    gzip_types text/plain;\n    charset utf-8;\n", 1)
        alone_text, alone_block = block_text(self.render_text(alone), "scootsales.my")
        self.assertIsNone(re.search(r"\n[ \t]*\n[ \t]*(gzip|charset)", alone_text))
        self.assertEqual(len(nginx_site.direct(alone_block, "charset")), 1)
        self.assertNotIn("text/plain", alone_text)

    def test_a_managed_setting_on_the_line_of_the_closing_brace_keeps_the_added_blocks_whole(self):
        counts = []
        for pad in (" ", " " * 6, " " * 10, "\t" * 8):
            with self.subTest(repr(pad)):
                source = (
                    "server {\n    listen 443;\n    server_name scootsales.my;\n    root /x;\n    gzip on;" + pad + "}\n"
                )
                first = self.render_text(source)
                self.assertEqual(self.render_text(first), first)
                names = [child.name for child in block_text(first, "scootsales.my")[1].children]
                self.assertEqual([n for n in names if n != "location" and "location".endswith(n)], [])
                counts.append(names.count("location"))
        self.assertGreaterEqual(min(counts), 2)
        self.assertEqual(len(set(counts)), 1)


CONTROL_BLOCK = """server {
    listen 443 ssl http2;
    server_name control.scootsales.my;
    location / {
        proxy_pass http://127.0.0.1:8100;
    }
}
"""

SCOOT_ONLY = SITE_FILE.split("server {\n    listen 443 ssl http2;\n    server_name hardware")[0]
HARDWARE_ONLY = "server {" + SITE_FILE.split("server {")[-1]


class HostIsolationTests(unittest.TestCase):
    def isolated(self, files, host, others):
        with tempfile.TemporaryDirectory() as folder:
            dump = Path(folder) / "dump"
            dump.write_text(
                "".join("# configuration file %s:\n%s\n" % (path, text) for path, text in files.items()),
                encoding="utf-8",
            )
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = nginx_site.main(["nginx_site.py", "isolated", str(dump), host, *others])
            return code, out.getvalue()

    def test_a_file_that_serves_two_dashboard_hosts_is_refused_for_either_host(self):
        files = {"/etc/nginx/conf.d/all.conf": SITE_FILE}
        for host, other in (("hardware.scootsales.my", "scootsales.my"), ("scootsales.my", "hardware.scootsales.my")):
            with self.subTest(host):
                code, message = self.isolated(files, host, [other, "control.scootsales.my"])
                self.assertEqual(code, 1)
                self.assertIn("/etc/nginx/conf.d/all.conf", message)
                self.assertIn(other, message)

    def test_a_file_that_also_holds_the_control_host_is_refused(self):
        files = {"/etc/nginx/conf.d/all.conf": HARDWARE_ONLY + CONTROL_BLOCK}
        code, message = self.isolated(files, "hardware.scootsales.my", ["scootsales.my", "control.scootsales.my"])
        self.assertEqual(code, 1)
        self.assertIn("control.scootsales.my", message)

    def test_one_file_per_host_passes_for_both_hosts(self):
        files = {
            "/etc/nginx/conf.d/scoot.conf": SCOOT_ONLY,
            "/etc/nginx/conf.d/hardware.conf": HARDWARE_ONLY,
            "/etc/nginx/conf.d/control.conf": CONTROL_BLOCK,
        }
        for host, other in (("hardware.scootsales.my", "scootsales.my"), ("scootsales.my", "hardware.scootsales.my")):
            with self.subTest(host):
                self.assertEqual(self.isolated(files, host, [other, "control.scootsales.my"]), (0, ""))


if __name__ == "__main__":
    unittest.main()
