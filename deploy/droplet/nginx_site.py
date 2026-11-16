import os
import re
import sys

CONTENT_DIRECTIVES = {"root", "alias", "proxy_pass", "try_files", "fastcgi_pass", "uwsgi_pass", "scgi_pass", "grpc_pass"}
HEADER = re.compile(r"^# configuration file (.+):$")
WORKSPACE_CODE = re.compile(r"[a-z0-9-]{2,32}")
PLATFORM_UPSTREAM = "http://127.0.0.1:8100"
COPILOT_UPSTREAM = "http://127.0.0.1:8101"
COPILOT_PATHS = ("/health", "/v1/interpret")
COPILOT_ZONE = "scoot_copilot"
COPILOT_ZONE_LINE = "limit_req_zone $binary_remote_addr zone=%s:10m rate=10r/s;" % COPILOT_ZONE


class Node:
    def __init__(self, name, args, start):
        self.name = name
        self.args = args
        self.start = start
        self.end = start
        self.open = None
        self.close = None
        self.children = None


def tokenize(text):
    tokens = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c.isspace():
            i += 1
        elif c == "#":
            while i < n and text[i] != "\n":
                i += 1
        elif c in "{};":
            tokens.append((c, i, i + 1, c))
            i += 1
        else:
            start = i
            if c in "\"'":
                i += 1
                while i < n and text[i] != c:
                    i += 2 if text[i] == "\\" else 1
                i += 1
                tokens.append(("w", start, i, text[start + 1:i - 1]))
                continue
            while i < n and not text[i].isspace() and text[i] not in "{};":
                if text[i] == "$" and i + 1 < n and text[i + 1] == "{":
                    while i < n and text[i] != "}":
                        i += 1
                    i += 1
                else:
                    i += 2 if text[i] == "\\" else 1
            tokens.append(("w", start, i, text[start:i]))
    return tokens


def parse(text):
    root = Node("", [], 0)
    root.children = []
    stack = [root]
    words = []
    for kind, start, end, value in tokenize(text):
        if kind == "w":
            words.append((start, value))
        elif kind == ";" or kind == "{":
            if not words:
                raise ValueError("empty directive at offset %d" % start)
            node = Node(words[0][1], [w[1] for w in words[1:]], words[0][0])
            words = []
            stack[-1].children.append(node)
            if kind == ";":
                node.end = end
            else:
                node.open = start
                node.children = []
                stack.append(node)
        else:
            if words or len(stack) == 1:
                raise ValueError("unexpected } at offset %d" % start)
            node = stack.pop()
            node.close = start
            node.end = end
    if words or len(stack) != 1:
        raise ValueError("unbalanced braces or missing ;")
    return root


def split_dump(dump):
    files = {}
    order = []
    current = None
    for line in dump.splitlines():
        match = HEADER.match(line)
        if match:
            current = match.group(1)
            order.append(current)
            files[current] = []
        elif current is not None:
            files[current].append(line)
    return [(path, "\n".join(files[path])) for path in order]


def walk(node):
    for child in node.children or []:
        yield child
        for inner in walk(child):
            yield inner


def server_blocks(root):
    return [n for n in walk(root) if n.name == "server" and n.children is not None]


def direct(block, name):
    return [c for c in block.children if c.name == name]


def server_names(block):
    names = []
    for node in direct(block, "server_name"):
        names.extend(node.args)
    return names


def is_acme(node):
    return node.name == "location" and any(a.startswith("/.well-known/acme-challenge") for a in node.args)


def has_content(node):
    for child in node.children or []:
        if is_acme(child):
            continue
        if child.name in CONTENT_DIRECTIVES or has_content(child):
            return True
    return False


def allowed_names(host):
    return {host, "www." + host}


def matching_blocks(root, host):
    return [b for b in server_blocks(root) if host in server_names(b)]


def serving_blocks(root, host):
    return [b for b in matching_blocks(root, host) if has_content(b)]


def load_dump(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        return split_dump(handle.read())


def serving_in_dump(dump_path, host):
    found = []
    for path, text in load_dump(dump_path):
        try:
            root = parse(text)
        except ValueError:
            continue
        for block in serving_blocks(root, host):
            found.append((path, text, block))
    return found


def check(dump_path, host):
    matched = 0
    found = []
    for path, text in load_dump(dump_path):
        try:
            root = parse(text)
        except ValueError:
            continue
        matched += len(matching_blocks(root, host))
        found.extend((path, b) for b in serving_blocks(root, host))
    if matched == 0:
        print("No nginx server block has server_name %s. It may be served by a default server or by a program other than nginx." % host)
        return 1
    if not found:
        print("nginx has a server block for %s, but it only redirects or answers with a fixed reply. It serves no site." % host)
        return 1
    for path, block in found:
        extra = [n for n in server_names(block) if n not in allowed_names(host)]
        if extra:
            print("The server block in %s also serves %s. This script will not change a block that is shared with other host names." % (path, " ".join(extra)))
            return 1
    return 0


def isolated(dump_path, host, others):
    for path, text, block in serving_in_dump(dump_path, host):
        root = parse(text)
        for other in others:
            if other == host:
                continue
            for neighbour in matching_blocks(root, other):
                if neighbour.start != block.start:
                    print("The nginx file %s holds the server block of %s and also a server block of %s. A backup or a revert of one host would also restore the other. Give each host its own nginx file first." % (path, host, other))
                    return 1
    return 0


def describe(block):
    lines = []
    lines.append("    names:       %s" % " ".join(server_names(block)))
    lines.append("    listen:      %s" % "; ".join(" ".join(n.args) for n in direct(block, "listen")))
    for node in direct(block, "root"):
        lines.append("    root:        %s" % " ".join(node.args))
    for node in direct(block, "ssl_certificate"):
        lines.append("    certificate: %s" % " ".join(node.args))
    for node in direct(block, "ssl_certificate_key"):
        lines.append("    key file:    %s" % " ".join(node.args))
    for node in direct(block, "location"):
        inner = [c for c in node.children if c.name in CONTENT_DIRECTIVES]
        detail = ", ".join("%s %s" % (c.name, " ".join(c.args)) for c in inner)
        lines.append("    location %s%s" % (" ".join(node.args), (" -> " + detail) if detail else ""))
    return lines


def report(dump_path, host):
    out = []
    for path, text in load_dump(dump_path):
        try:
            root = parse(text)
        except ValueError:
            continue
        for block in matching_blocks(root, host):
            kind = "serves the site" if has_content(block) else "redirect or fixed reply (not changed)"
            out.append("  file: %s (%s)" % (path, kind))
            out.extend(describe(block))
    print("\n".join(out))


def values(dump_path, host, command):
    seen = []
    for path, text, block in serving_in_dump(dump_path, host):
        if command == "files":
            items = [os.path.realpath(path)]
        elif command == "names":
            items = server_names(block)
        elif command == "certs":
            items = [n.args[0] for n in direct(block, "ssl_certificate") if n.args]
        else:
            items = [n.args[0] for n in direct(block, "root") if n.args]
            for loc in direct(block, "location"):
                if loc.args == ["/"]:
                    items.extend(n.args[0] for n in direct(loc, "root") if n.args)
            items = [i for i in items if os.path.isabs(i)]
        for item in items:
            if item not in seen:
                seen.append(item)
    if seen:
        print("\n".join(seen))


def indent_of(text, offset):
    line_start = text.rfind("\n", 0, offset) + 1
    prefix = text[line_start:offset]
    return prefix if prefix.strip() == "" else ""


def workspace_location(inner, default_workspace):
    if default_workspace:
        lines = [
            "location = /workspace.json {",
            "    proxy_pass %s/v1/companies/%s;" % (PLATFORM_UPSTREAM, default_workspace),
            "    proxy_set_header Host $host;",
            "    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;",
            "    proxy_set_header X-Forwarded-Proto $scheme;",
            "}",
        ]
    else:
        lines = ["location = /workspace.json {", "    return 404;", "}"]
    return ("\n" + inner).join(lines)


def copilot_location(inner, path):
    lines = [
        "location = %s {" % path,
        "    client_max_body_size 64k;",
    ]
    if path == "/v1/interpret":
        lines += ["    limit_req zone=%s burst=20 nodelay;" % COPILOT_ZONE, "    limit_req_status 429;"]
    lines += [
        "    proxy_http_version 1.1;",
        "    proxy_connect_timeout 3s;",
        "    proxy_read_timeout 12s;",
        "    proxy_pass %s;" % COPILOT_UPSTREAM,
        "    proxy_set_header Host $host;",
        "    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;",
        "    proxy_set_header X-Forwarded-Proto $scheme;",
        "}",
    ]
    return ("\n" + inner).join(lines)


def www_redirect(text, block, host, base):
    inner = base + "    "
    kept = [n for n in block.children if n.name.startswith("ssl_") or n.name in ("include", "http2")]
    lines = ["server {"]
    for n in block.children:
        if n.name == "listen" and n.args:
            keep = [n.args[0]] + [a for a in n.args[1:] if a in ("ssl", "http2")]
            lines.append("%slisten %s;" % (inner, " ".join(keep)))
    lines.extend(inner + text[n.start:n.end] for n in kept)
    lines.append("%sserver_name www.%s;" % (inner, host))
    lines.append("%sreturn 301 https://%s$request_uri;" % (inner, host))
    lines.append(base + "}")
    return "\n\n" + base + "\n".join(lines)


SECURITY_HEADERS = {
    "Strict-Transport-Security": "max-age=300",
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Referrer-Policy": "strict-origin-when-cross-origin",
    "Permissions-Policy": "camera=(self), microphone=(self), geolocation=(self)",
    "Content-Security-Policy-Report-Only": (
        "default-src 'self'; script-src 'self' 'wasm-unsafe-eval' https://www.gstatic.com https://apis.google.com; "
        "style-src 'self' 'unsafe-inline'; img-src 'self' data: blob: https:; font-src 'self' data:; "
        "connect-src 'self' https://control.scootsales.my https://*.googleapis.com https://api.geoapify.com "
        "https://www.gstatic.com wss://*.firebaseio.com; frame-src https://*.firebaseapp.com; "
        "worker-src 'self' blob:; base-uri 'self'; object-src 'none'; form-action 'self'"
    ),
}


GZIP_DIRECTIVES = (
    "gzip on;",
    "gzip_vary on;",
    "gzip_proxied any;",
    "gzip_min_length 1024;",
    "gzip_types application/javascript application/json application/wasm text/css image/svg+xml font/ttf font/otf application/octet-stream;",
)
GZIP_NAMES = {line.split()[0] for line in GZIP_DIRECTIVES}


def removal_edits(text, nodes):
    edits = []
    groups = []
    for node in sorted(nodes, key=lambda n: n.start):
        if groups and not text[groups[-1][-1].end:node.start].strip(" \t"):
            groups[-1].append(node)
        else:
            groups.append([node])
    for group in groups:
        first, last = group[0], group[-1]
        line_end = text.find("\n", last.end)
        if line_end < 0:
            line_end = len(text)
        after = text[last.end:line_end].strip()
        if after and not after.startswith("#"):
            end = last.end
            while not after.startswith("}") and text[end:end + 1] in (" ", "\t"):
                end += 1
            edits.append((first.start, end, ""))
        else:
            start = first.start
            while start > 0 and text[start - 1] in (" ", "\t"):
                start -= 1
            if start > 0 and text[start - 1] == "\n":
                start -= 1
            edits.append((start, last.end, ""))
    return edits


def rewrite_block(text, block, host, new_root, default_workspace, copilot):
    base = indent_of(text, block.start)
    inner = base + "    "
    edits = []
    roots = direct(block, "root")
    root_line = "root %s;" % new_root
    managed_headers = {name.lower() for name in SECURITY_HEADERS}
    stale = [n for n in direct(block, "add_header") if n.args and n.args[0].lower() in managed_headers]
    stale += [n for n in block.children if n.name in GZIP_NAMES and n.children is None]
    edits.extend(removal_edits(text, stale))
    for line in GZIP_DIRECTIVES:
        root_line += "\n%s%s" % (inner, line)
    for name, value in SECURITY_HEADERS.items():
        root_line += "\n%sadd_header %s \"%s\" always;" % (inner, name, value)
    if roots:
        edits.append((roots[0].start, roots[0].end, root_line))
    else:
        names = direct(block, "server_name")
        anchor = names[-1].end if names else block.open + 1
        edits.append((anchor, anchor, "\n%s%s" % (inner, root_line)))
    locations = direct(block, "location")
    spa = [l for l in locations if l.args == ["/"]]
    spa_text = "location / {\n%s    expires -1;\n%s    try_files $uri $uri/ /index.html;\n%s}" % (inner, inner, inner)
    managed = [(["=", "/workspace.json"], workspace_location(inner, default_workspace))]
    if copilot:
        managed.extend((["=", path], copilot_location(inner, path)) for path in COPILOT_PATHS)
    www = "www." + host
    for node in direct(block, "server_name"):
        if www in node.args:
            remaining = [a for a in node.args if a != www]
            edits.append((node.start, node.end, "server_name %s;" % " ".join(remaining) if remaining else ""))
            edits.append((block.end, block.end, www_redirect(text, block, host, base)))
    added = ""
    for args, body in managed:
        present = [l for l in locations if l.args == args]
        if present:
            edits.append((present[0].start, present[0].end, body))
        else:
            added += body + "\n\n" + inner
    if spa:
        edits.append((spa[0].start, spa[0].end, added + spa_text))
    else:
        tail = block.close
        while tail > 0 and text[tail - 1].isspace():
            tail -= 1
        edits.append((tail, tail, "\n\n%s%s%s" % (inner, added, spa_text)))
    return edits


def rewrite(file_path, host, new_root, default_workspace, copilot, zone_elsewhere=False):
    if default_workspace and not WORKSPACE_CODE.fullmatch(default_workspace):
        print("The default workspace code must match [a-z0-9-]{2,32}.", file=sys.stderr)
        return 64
    with open(file_path, encoding="utf-8") as handle:
        text = handle.read()
    root = parse(text)
    blocks = serving_blocks(root, host)
    if not blocks:
        print("No serving block for %s in %s" % (host, file_path), file=sys.stderr)
        return 2
    edits = []
    for block in blocks:
        edits.extend(rewrite_block(text, block, host, new_root, default_workspace, copilot))
    zone_defined = any(n.name == "limit_req_zone" and any(a.startswith("zone=%s:" % COPILOT_ZONE) for a in n.args)
                       for n in walk(root))
    if copilot and not zone_defined and not zone_elsewhere:
        edits.append((blocks[0].start, blocks[0].start, COPILOT_ZONE_LINE + "\n\n" + indent_of(text, blocks[0].start)))
    for start, end, replacement in sorted(edits, key=lambda e: (e[0], e[1]), reverse=True):
        text = text[:start] + replacement + text[end:]
    sys.stdout.write(text)
    return 0


def main(argv):
    copilot = "--copilot" in argv
    zone_elsewhere = "--zone-elsewhere" in argv
    argv = [a for a in argv if a not in ("--copilot", "--zone-elsewhere")]
    command = argv[1] if len(argv) > 1 else ""
    if command == "check" and len(argv) == 4:
        return check(argv[2], argv[3])
    if command == "report" and len(argv) == 4:
        report(argv[2], argv[3])
        return 0
    if command in ("files", "names", "certs", "roots") and len(argv) == 4:
        values(argv[2], argv[3], command)
        return 0
    if command == "isolated" and len(argv) >= 4:
        return isolated(argv[2], argv[3], argv[4:])
    if command == "rewrite" and len(argv) in (5, 6):
        return rewrite(argv[2], argv[3], argv[4], argv[5] if len(argv) == 6 else "", copilot, zone_elsewhere)
    print("usage: nginx_site.py check|report|files|names|certs|roots DUMP HOST | isolated DUMP HOST [OTHER_HOST ...] | rewrite FILE HOST ROOT [WORKSPACE] [--copilot] [--zone-elsewhere]", file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv))
