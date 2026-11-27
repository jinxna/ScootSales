#!/usr/bin/env bash
set -euo pipefail

CONTROL_HOST=${SCOOT_CONTROL_HOST:-control.scootsales.my}
PRIMARY_DASHBOARD_HOST=${SCOOT_PRIMARY_DASHBOARD_HOST:-scootsales.my}
DASHBOARD_HOST=$PRIMARY_DASHBOARD_HOST
KNOWN_DASHBOARD_HOSTS=(scootsales.my hardware.scootsales.my)
PROMO_HOST=site.scootsales.my
PROMO_WWW=${SCOOT_PROMO_WWW:-/var/www/scootsales-site}
KEEP_PROMO_RELEASES=3
LOCK_DIR=
BASE=${SCOOT_BASE:-/opt/scoot}
ETC=${SCOOT_ETC:-/etc/scoot}
WWW=${SCOOT_WWW:-/var/www/scootsales-dashboard}
BACKUP_DIR=$BASE/backup
ENV_FILE=$ETC/platform.env
UNIT=scoot-platform
KEEP_RELEASES=3
KEEP_DASHBOARDS=3
MAX_ROOT_MB=500
CERT_WARN_SECONDS=1209600
MIN_MEM_MB=500
MIN_DISK_MB=1500
HEALTH_URL=http://127.0.0.1:8100/health
COPILOT_UNIT=scoot-copilot
SCHEDULER_UNIT=scoot-scheduler
SCHEDULER_SOCKET=/run/scoot-scheduler/uvicorn.sock
COPILOT_USER=scoot-copilot
COPILOT_KEY_FILE=/etc/scoot-copilot/budget-key.json
COPILOT_ENV_FILE=$ETC/copilot.env
COPILOT_HEALTH_URL=http://127.0.0.1:8101/health
FORECAST_VENV=$BASE/forecast-venv
FORECAST_COMPANY=dev
FORECAST_COMPANIES=(dev hardware)
HERE=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
SOURCE=$(dirname "$HERE")

ACTION=deploy
APPLY=0
SKIP_NGINX=0
EMAIL=
DEFAULT_WORKSPACE=
WORKSPACE_GIVEN=0
AGREE=0
POS=()
PASS=()
PY=
NGINX_TARGET=
NGINX_LINK=
WORK=
OTHER_OWNER=
OTHER_PORT=
SITE_FILES=()
SITE_CERTS=()
SITE_ROOTS=()

say() { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
die() { printf 'STOP: %s\n' "$*" >&2; exit 1; }

act() {
  if [ "$APPLY" = 1 ]; then
    printf 'RUN  %s\n' "$*"
    "$@"
  else
    printf 'DRY  %s\n' "$*"
  fi
}

usage() {
  cat <<'USAGE'
Usage: scoot-deploy.sh [action] [options]

Actions
  deploy        Install the unpacked release (default).
  copilot-install
                Add the Gemini-only Scout service (settings file and service unit).
                Run  deploy --apply  first. Does not start it and does not touch nginx.
  copilot-start Check the Scout settings, restart the Scout service, check health.
                The dashboard action adds the two nginx paths that reach it.
  forecast-install
                Make /opt/scoot/forecast-venv and add the weekly forecast units for each company
                (dev = cos40005, hardware = hardware-client-sales).
                Run  deploy --apply  first. Leaves the timers as they are.
  forecast-run  Run one company's forecast and retailer intelligence once as a dry run. With --apply it writes both.
                --company dev (default, cos40005) or --company hardware (hardware-client-sales).
  start         Check the settings, restart the service, check health.
  headers       Check the security headers that each site sends against the installed config (read only).
  scheduler-install
                Run the background jobs as their own service. Turns the jobs off inside scoot-platform.
                If a step fails, the script puts the jobs back inside scoot-platform. By hand:
                systemctl disable --now scoot-scheduler; set PLATFORM_SCHEDULER_ENABLED=true in the settings file; scoot-deploy start --apply
  rollback      Switch to the previous kept release and restart.
  install-key   install-key central FILE | install-key company PROJECT_ID FILE | install-key copilot FILE
  signing-key   Make the signing key once and store it in the settings file.
  public-key    Print the public signing key (safe to share). The dashboard build needs it.
  create-owner  create-owner EMAIL: make or reset the first owner sign-in in Firebase (asks for a password).
  brevo         Run scripts/brevo_templates.py. Add --apply --confirm-account EMAIL to write.
  certificate   Get the HTTPS certificate for the Control Centre: certificate --email EMAIL --agree-tos
  dashboard     Put the new company dashboard on one dashboard host (scootsales.my, or the host
                named with --dashboard-host). Finds how that site is served now.
                Backs up the nginx file and the web root of that host first. Without --apply it only reports.
                Needs --default-workspace CODE with --apply.
                It changes only the nginx file of that host. Another dashboard host is not touched.
  dashboard-revert
                Put back the newest backup made by  dashboard --apply  for the same host.
                Give the same --dashboard-host as for the dashboard action.
  promo         promo FOLDER: put the promotional website on site.scootsales.my. FOLDER is the
                site-static folder made by  npm run export:static  in the promotion repo.
                Copies it to a new release in /var/www/scootsales-site, leaves out product/
                images that no page uses, points current at it and writes the nginx file.
                Add --email EMAIL --agree-tos to get the HTTPS certificate when there is none.
                Add the DNS A record for site.scootsales.my first.
  status        Show what is installed and running.

Options
  --apply       Do the work. Without it every action only prints what it would do.
  --skip-nginx  Do not touch nginx or certbot.
  --dashboard-host NAME
                Host name of the company dashboard (default scootsales.my). Another host
                that is served by this droplet's nginx, such as hardware.scootsales.my, is allowed.
  --default-workspace CODE
                Company code that the bare address of that host (for example https://scootsales.my/) opens.
                Other companies use /w/CODE. Only the dashboard action uses it.
USAGE
}

parse() {
  if [ -n "${SCOOT_DASHBOARD_HOST:-}" ] && [ "$SCOOT_DASHBOARD_HOST" != "$PRIMARY_DASHBOARD_HOST" ]; then
    die "SCOOT_DASHBOARD_HOST is set to $SCOOT_DASHBOARD_HOST. The primary dashboard host is $PRIMARY_DASHBOARD_HOST. Unset SCOOT_DASHBOARD_HOST and name another host with --dashboard-host. Nothing was changed."
  fi
  if [ $# -gt 0 ]; then
    case "$1" in
      deploy|start|headers|scheduler-install|copilot-install|copilot-start|forecast-install|forecast-run|rollback|install-key|signing-key|public-key|create-owner|brevo|certificate|dashboard|dashboard-revert|promo|status) ACTION=$1; shift ;;
      --rollback) ACTION=rollback; shift ;;
    esac
  fi
  if [ "$ACTION" = brevo ]; then
    PASS=("$@")
    return 0
  fi
  while [ $# -gt 0 ]; do
    case "$1" in
      --apply) APPLY=1 ;;
      --skip-nginx) SKIP_NGINX=1 ;;
      --dashboard-host) DASHBOARD_HOST=${2:-}; shift ;;
      --default-workspace) DEFAULT_WORKSPACE=${2:-}; WORKSPACE_GIVEN=1; shift ;;
      --email) EMAIL=${2:-}; shift ;;
      --company) FORECAST_COMPANY=${2:-}; shift ;;
      --agree-tos) AGREE=1 ;;
      -h|--help) usage; exit 0 ;;
      *) POS+=("$1") ;;
    esac
    shift
  done
  [[ "$DASHBOARD_HOST" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || die "Give a plain host name for --dashboard-host."
  if [ "$WORKSPACE_GIVEN" = 1 ]; then
    [[ "$DEFAULT_WORKSPACE" =~ ^[a-z0-9-]{2,32}$ ]] || die "Give the company code for --default-workspace: 2 to 32 lower-case letters, digits or dashes. Copy it from the company page in the Control Centre."
  fi
  case "$DASHBOARD_HOST" in
    "$CONTROL_HOST"|www.scootsales.my|"$PROMO_HOST")
      die "$DASHBOARD_HOST is not allowed as the dashboard host. Use scootsales.my or hardware.scootsales.my."
      ;;
  esac
}

is_primary_host() { [ "$DASHBOARD_HOST" = "$PRIMARY_DASHBOARD_HOST" ]; }

site_current() {
  if is_primary_host; then printf '%s\n' "$WWW/current"; else printf '%s\n' "$WWW/current-$DASHBOARD_HOST"; fi
}

backup_prefix() {
  if is_primary_host; then printf '%s\n' scootsales; else printf '%s\n' "$DASHBOARD_HOST"; fi
}

host_flag() {
  if ! is_primary_host; then printf ' --dashboard-host %s' "$DASHBOARD_HOST"; fi
}

has_dashboard() { [ -d "$SOURCE/dashboard" ] || [ -d "$BASE/platform/dashboard" ]; }

need_root() {
  if [ "$APPLY" = 1 ] && [ "$(id -u)" != 0 ]; then
    die "Run this script as root."
  fi
}

env_value() {
  [ -f "$ENV_FILE" ] || return 0
  sed -n "s/^$1=//p" "$ENV_FILE" | tail -n 1 | sed -e "s/^['\"]//" -e "s/['\"]\$//"
}

set_env() {
  local tmp
  tmp=$(umask 077; mktemp "$ETC/.platform.env.XXXXXX")
  N=$1 V=$2 awk 'BEGIN { FS = "=" } $1 == ENVIRON["N"] { print ENVIRON["N"] "=" ENVIRON["V"]; found = 1; next } { print } END { if (!found) print ENVIRON["N"] "=" ENVIRON["V"] }' "$ENV_FILE" > "$tmp"
  chmod 600 "$tmp"
  chown root:root "$tmp"
  mv -f "$tmp" "$ENV_FILE"
}

check_resources() {
  local mem disk probe
  mem=
  if [ -r /proc/meminfo ]; then
    mem=$(awk '/^MemAvailable:/ { a = $2 } /^MemFree:/ { f = $2 } END { print int((a ? a : f) / 1024) }' /proc/meminfo)
  fi
  [ -n "$mem" ] || die "Cannot read the free memory of this server. Nothing was changed."
  probe=$BASE
  [ -d "$probe" ] || probe=/
  disk=$(df -Pm "$probe" | awk 'NR == 2 { print $4 }')
  say "Free memory: ${mem} MB. Free disk: ${disk} MB."
  if [ "$mem" -lt "$MIN_MEM_MB" ]; then
    die "Only ${mem} MB of memory is free. This droplet also runs another server. The Python packages need about ${MIN_MEM_MB} MB while they install, and the service needs about 200 MB while it runs. Stop something else or add swap, then run this script again. Nothing was changed."
  fi
  if [ "$disk" -lt "$MIN_DISK_MB" ]; then
    die "Only ${disk} MB of disk is free. Each release needs about 700 MB with its Python packages, and two are kept. Free at least ${MIN_DISK_MB} MB, then run this script again. Nothing was changed."
  fi
}

port_owners() {
  command -v ss >/dev/null 2>&1 || die "The command ss is missing. Install iproute2, then run this script again."
  ss -H -ltnp "sport = :$1" 2>/dev/null | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | sort -u
}

check_ports() {
  local port owners owner
  for port in 80 443; do
    owners=$(port_owners "$port")
    for owner in $owners; do
      if [ "$owner" != nginx ]; then
        say "Port $port is owned by '$owner', not by the host nginx." >&2
        say "This script did not change anything, and it will not touch that program." >&2
        say "Manual alternative: run  scoot-deploy.sh deploy --apply --skip-nginx" >&2
        say "It installs the service on 127.0.0.1:8100 and the web files in $BASE/platform/web." >&2
        say "Then add $CONTROL_HOST to the program that owns port $port: serve $BASE/platform/web at /," >&2
        say "and proxy /staff/ and /v1/ to http://127.0.0.1:8100 with the X-Forwarded-For header." >&2
        exit 1
      fi
    done
  done
  command -v nginx >/dev/null 2>&1 || die "Nothing but nginx may own port 80 or 443, and the nginx command is missing. Use --skip-nginx and set up the web server yourself."
  nginx -t >/dev/null 2>&1 || die "The current nginx configuration fails nginx -t. Fix it first. Nothing was changed."
}

pick_python() {
  local candidate
  for candidate in python3.13 python3.12 python3.11 python3.10 python3; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

install_packages() {
  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v openssl >/dev/null 2>&1 || missing+=(openssl)
  "$PY" -c 'import ensurepip, venv' >/dev/null 2>&1 || missing+=(python3-venv)
  if [ ${#missing[@]} -gt 0 ]; then
    command -v apt-get >/dev/null 2>&1 || die "Missing packages: ${missing[*]}. Install them, then run this script again."
    act apt-get update -qq
    act apt-get install -y -qq "${missing[@]}"
  else
    say "keep   packages (all present)"
  fi
}

release_id() {
  local id
  id=$(sed -n 's/^id=//p' "$SOURCE/RELEASE" 2>/dev/null | head -n 1)
  [[ "$id" =~ ^[0-9]{8}-[0-9]{6}$ ]] || die "RELEASE is missing or wrong in $SOURCE. Unpack the package again."
  printf '%s\n' "$id"
}

prepare_base() {
  if [ -e "$BASE/platform" ] && [ ! -L "$BASE/platform" ]; then
    die "$BASE/platform exists and is not a link. Move it away, then run this script again."
  fi
  id scoot >/dev/null 2>&1 || act useradd --system --home-dir "$BASE" --no-create-home --shell /usr/sbin/nologin scoot
  act install -d -m 0755 -o root -g root "$BASE" "$BASE/releases" "$BASE/bin"
  act install -d -m 0750 -o root -g scoot "$ETC"
  act install -d -m 0700 -o scoot -g scoot "$ETC/company-keys"
}

create_env() {
  local hash invite tmp
  if [ -f "$ENV_FILE" ]; then
    say "keep   $ENV_FILE (exists, not changed)"
    return 0
  fi
  if [ "$APPLY" != 1 ]; then
    say "DRY  create $ENV_FILE from platform.env.tpl (mode 0600; two random secrets are made on this server and never shown)"
    return 0
  fi
  hash=$(openssl rand -hex 32)
  invite=$(openssl rand -base64 48 | tr '+/' '-_' | tr -d '=\n')
  tmp=$(umask 077; mktemp "$ETC/.platform.env.XXXXXX")
  sed -e "s|@@CONTROL_HOST@@|$CONTROL_HOST|g" -e "s|@@DASHBOARD_HOST@@|$PRIMARY_DASHBOARD_HOST|g" -e "s|@@STAFF_HASH_SECRET@@|$hash|" -e "s|@@INVITE_SECRET@@|$invite|" "$HERE/platform.env.tpl" > "$tmp"
  chmod 600 "$tmp"
  chown root:root "$tmp"
  mv -f "$tmp" "$ENV_FILE"
  say "made   $ENV_FILE (fill the empty values; see the guide)"
}

install_release() {
  local dir=$BASE/releases/$1
  if [ -f "$dir/.complete" ]; then
    say "keep   release $1 (already installed)"
    return 0
  fi
  act rm -rf "$dir"
  act install -d -m 0755 "$dir"
  local item
  for item in platform_service forecasting scripts tools web dashboard droplet admin_dashboard RELEASE; do
    if [ -e "$SOURCE/$item" ]; then act cp -a "$SOURCE/$item" "$dir/"; fi
  done
  act chown -R root:root "$dir"
  act chmod -R u=rwX,go=rX "$dir"
  act chmod 0755 "$dir/droplet/scoot-deploy.sh"
  act "$PY" -m venv "$dir/venv"
  act "$dir/venv/bin/pip" install --quiet --disable-pip-version-check --no-cache-dir -r "$dir/platform_service/requirements.txt"
  act touch "$dir/.complete"
}

switch_release() {
  act ln -sfn "$BASE/releases/$1" "$BASE/platform.next"
  act mv -T -f "$BASE/platform.next" "$BASE/platform"
  act ln -sfn "$BASE/platform/droplet/scoot-deploy.sh" "$BASE/bin/scoot-deploy"
  act ln -sfn "$BASE/bin/scoot-deploy" /usr/local/bin/scoot-deploy
}

run_mark() {
  if find "$BASE/releases" -mindepth 2 -maxdepth 2 -name .started 2>/dev/null | grep -q .; then
    printf '%s\n' .started
  else
    printf '%s\n' .complete
  fi
}

prune_releases() {
  local current dir mark
  current=$(readlink -f "$BASE/platform" 2>/dev/null || true)
  [ -d "$BASE/releases" ] || return 0
  mark=$(run_mark)
  for dir in $(find "$BASE/releases" -mindepth 1 -maxdepth 1 -type d | sort -r); do
    [ "$(readlink -f "$dir")" = "$current" ] && continue
    [ -f "$dir/$mark" ] || act rm -rf "$dir"
  done
  for dir in $(find "$BASE/releases" -mindepth 1 -maxdepth 1 -type d -exec test -f "{}/$mark" ';' -print | sort -r | tail -n +$((KEEP_RELEASES + 1))); do
    [ "$(readlink -f "$dir")" = "$current" ] || act rm -rf "$dir"
  done
}

previous_release() {
  local current=$1 name mark
  mark=$(run_mark)
  for name in $(find "$BASE/releases" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r); do
    if [[ "$name" < "$current" ]] && [ -f "$BASE/releases/$name/.complete" ] && [ -f "$BASE/releases/$name/$mark" ]; then
      printf '%s\n' "$name"
      return 0
    fi
  done
}

restart_scheduler() {
  local attempt
  systemctl is-enabled --quiet "$SCHEDULER_UNIT" 2>/dev/null || return 0
  act systemctl restart "$SCHEDULER_UNIT"
  [ "$APPLY" = 1 ] || return 0
  for attempt in $(seq 1 20); do
    if [ "$(systemctl is-active "$SCHEDULER_UNIT" 2>/dev/null || true)" = active ] && [ -S "$SCHEDULER_SOCKET" ]; then
      say "OK    $SCHEDULER_UNIT is active on $SCHEDULER_SOCKET"
      return 0
    fi
    sleep 1
  done
  say "FAIL  $SCHEDULER_UNIT is not active within 20 seconds. Read the log:  journalctl -u $SCHEDULER_UNIT -n 80 --no-pager" >&2
  return 1
}

install_unit() {
  act install -m 0644 "$HERE/scoot-platform.service" "/etc/systemd/system/$UNIT.service"
  act systemctl daemon-reload
  act systemctl enable "$UNIT"
}

nginx_layout() {
  local host=$1 dump
  dump=$(nginx -T 2>/dev/null) || die "nginx -T failed. Nothing was changed."
  if grep -Eq 'include[[:space:]]+/etc/nginx/conf\.d/\*\.conf' <<<"$dump"; then
    NGINX_TARGET=/etc/nginx/conf.d/$host.conf
    NGINX_LINK=
  elif grep -Eq 'include[[:space:]]+/etc/nginx/sites-enabled/\*' <<<"$dump"; then
    NGINX_TARGET=/etc/nginx/sites-available/$host
    NGINX_LINK=/etc/nginx/sites-enabled/$host
  else
    die "nginx.conf includes neither conf.d nor sites-enabled. Use --skip-nginx and set up the web server yourself."
  fi
  if [ ! -f "$NGINX_TARGET" ] && grep -Eq "server_name[^;]*[[:space:]]${host//./\.}[[:space:];]" <<<"$dump"; then
    die "nginx already has a server block for $host in another file. This script does not change it."
  fi
}

render_nginx() {
  local host=$1 kind=$2 template rendered backup=
  nginx_layout "$host"
  if [ -f "/etc/letsencrypt/live/$host/fullchain.pem" ]; then
    template=$HERE/nginx-$kind.https.conf.tpl
  else
    template=$HERE/nginx-$kind.http.conf.tpl
  fi
  rendered=$(sed -e "s|@@HOST@@|$host|g" -e "s|@@API_HOST@@|$CONTROL_HOST|g" -e "s|@@ROOT@@|$PROMO_WWW/current|g" "$template")
  if [ -f "$NGINX_TARGET" ] && [ "$(cat "$NGINX_TARGET")" = "$rendered" ] && { [ -z "$NGINX_LINK" ] || [ -L "$NGINX_LINK" ]; }; then
    say "keep   $NGINX_TARGET (same)"
    return 0
  fi
  if [ "$APPLY" != 1 ]; then
    say "DRY  write $NGINX_TARGET from $(basename "$template")"
    [ -z "$NGINX_LINK" ] || say "DRY  link $NGINX_LINK"
    say "DRY  nginx -t && systemctl reload nginx"
    return 0
  fi
  if [ -f "$NGINX_TARGET" ]; then
    backup=$NGINX_TARGET.previous
    cp -p "$NGINX_TARGET" "$backup"
  fi
  printf '%s
' "$rendered" > "$NGINX_TARGET"
  [ -z "$NGINX_LINK" ] || ln -sfn "$NGINX_TARGET" "$NGINX_LINK"
  if ! nginx -t; then
    if [ -n "$backup" ]; then
      mv -f "$backup" "$NGINX_TARGET"
    else
      rm -f "$NGINX_TARGET"
      [ -z "$NGINX_LINK" ] || rm -f "$NGINX_LINK"
    fi
    die "nginx -t failed with the new block. The block was removed and nginx was not reloaded."
  fi
  say "RUN  nginx -t && systemctl reload nginx"
  systemctl reload nginx
  say "wrote  $NGINX_TARGET"
}

warn_cors() {
  local origins
  has_dashboard || return 0
  origins=,$(env_value PLATFORM_CLIENT_CORS_ORIGINS),
  if [[ "${origins// /}" != *",https://$DASHBOARD_HOST,"* ]]; then
    say "WARN  PLATFORM_CLIENT_CORS_ORIGINS in $ENV_FILE does not list https://$DASHBOARD_HOST. The dashboard cannot load company records until it does. Run  scoot-deploy dashboard$(host_flag) --default-workspace CODE --apply  or add it to the file."
  fi
}

missing_settings() {
  local name value
  for name in PLATFORM_PROJECT_ID GOOGLE_APPLICATION_CREDENTIALS PLATFORM_COMPANY_CREDENTIALS_DIR \
      PLATFORM_STAFF_HASH_SECRET PLATFORM_SIGNING_KEY_ID PLATFORM_SIGNING_KEY PLATFORM_PUBLIC_KEYS \
      PLATFORM_CLIENT_IP_HEADER PLATFORM_CLIENT_IP_TRUSTED_PROXIES PLATFORM_STAFF_URL PLATFORM_INVITE_URL PLATFORM_MAIL_TRANSPORT; do
    [ -n "$(env_value "$name")" ] || printf '%s\n' "$name"
  done
  if [ -z "$(env_value PLATFORM_STAFF_EMAILS)" ] && [ -z "$(env_value PLATFORM_STAFF_DOMAINS)" ]; then
    printf '%s\n' "PLATFORM_STAFF_EMAILS (or PLATFORM_STAFF_DOMAINS)"
  fi
  [ -n "$(env_value PLATFORM_STAFF_BOOTSTRAP_OWNERS)" ] || echo PLATFORM_STAFF_BOOTSTRAP_OWNERS
  if [ "$(env_value PLATFORM_MAIL_ENABLED)" = true ]; then
    for name in BREVO_API_KEY PLATFORM_MAIL_SENDER PLATFORM_BREVO_TEMPLATE_IDS; do
      [ -n "$(env_value "$name")" ] || printf '%s\n' "$name"
    done
  fi
  value=$(env_value GOOGLE_APPLICATION_CREDENTIALS)
  if [ -n "$value" ] && [ ! -f "$value" ]; then
    printf '%s\n' "GOOGLE_APPLICATION_CREDENTIALS (file $value is missing: run install-key central)"
  fi
  value=$(env_value PLATFORM_COMPANY_CREDENTIALS_DIR)
  if [ -n "$value" ] && [ ! -d "$value" ]; then
    printf '%s\n' "PLATFORM_COMPANY_CREDENTIALS_DIR (folder $value is missing)"
  fi
}

start_service() {
  local missing attempt
  if [ "$APPLY" != 1 ] && [ ! -f "$ENV_FILE" ]; then
    say "DRY  check the settings, restart $UNIT, curl -fsS $HEALTH_URL"
    return 0
  fi
  missing=$(missing_settings)
  if [ -n "$missing" ]; then
    say ""
    say "The service was NOT started. These settings in $ENV_FILE are empty or wrong:"
    sed 's/^/  /' <<<"$missing"
    say "Fill them in $ENV_FILE, then run:  $BASE/bin/scoot-deploy start --apply"
    return 2
  fi
  act systemctl restart "$UNIT"
  if [ "$APPLY" != 1 ]; then
    say "DRY  curl -fsS $HEALTH_URL"
    return 0
  fi
  for attempt in $(seq 1 30); do
    if curl -fsS --max-time 3 "$HEALTH_URL" >/dev/null 2>&1; then
      say "OK    $UNIT answers on $HEALTH_URL"
      warn_cors
      restart_scheduler || return 1
      touch "$(readlink -f "$BASE/platform")/.started"
      return 0
    fi
    sleep 1
  done
  say "FAIL  $UNIT did not answer on $HEALTH_URL within 30 seconds." >&2
  say "Read the log:  journalctl -u $UNIT -n 80 --no-pager" >&2
  say "Go back to the previous release:  $BASE/bin/scoot-deploy rollback --apply" >&2
  return 1
}

install_unit_and_site() {
  step "Service unit"
  install_unit
  if [ "$SKIP_NGINX" = 1 ]; then
    step "nginx skipped"
  else
    step "nginx"
    render_nginx "$CONTROL_HOST" control
  fi
}

mark_existing_releases() {
  local keep=$1 dir
  [ "$APPLY" = 1 ] || return 0
  if find "$BASE/releases" -mindepth 2 -maxdepth 2 -name .started 2>/dev/null | grep -q .; then
    dir=$(readlink -f "$BASE/platform")
    [ -f "$dir/.complete" ] && [ ! -f "$dir/.started" ] && touch "$dir/.started"
    return 0
  fi
  for dir in "$BASE"/releases/*/; do
    [ "$(basename "$dir")" = "$keep" ] && [ "$(readlink -f "$dir")" != "$(readlink -f "$BASE/platform")" ] && continue
    [ -f "$dir/.complete" ] && touch "$dir/.started"
  done
  return 0
}

do_deploy() {
  local id previous= code=0 missing earlier unit_before
  need_root
  step "Checks"
  check_resources
  id=$(release_id)
  [ -d "$SOURCE/platform_service" ] && [ -d "$SOURCE/web" ] || die "The package in $SOURCE is incomplete. Unpack it again."
  PY=$(pick_python) || die "Python 3.10 or newer is missing. Install python3, then run this script again."
  say "Release: $id. Python: $PY."
  [ "$SKIP_NGINX" = 1 ] || check_ports
  step "Packages"
  install_packages
  step "User and folders"
  prepare_base
  step "Settings file"
  create_env
  step "Release files and Python packages"
  install_release "$id"
  if [ -L "$BASE/platform" ]; then
    previous=$(basename "$(readlink -f "$BASE/platform")")
    mark_existing_releases "$id"
  else
    install_unit_and_site
  fi
  if [ -n "$previous" ]; then
    if [ -f "$ENV_FILE" ]; then
      missing=$(missing_settings)
      if [ -n "$missing" ]; then
        say ""
        say "Fill these settings in $ENV_FILE, then run this script again. The running service and its release were not changed:"
        sed 's/^/  /' <<<"$missing"
        [ "$APPLY" = 1 ] && exit 1
        say "DRY  the real run would stop here."
        return 0
      fi
    fi
  fi
  step "Switch to the new release"
  switch_release "$id"
  step "Start"
  start_service || code=$?
  if [ "$code" = 2 ] && [ -z "$previous" ]; then
    code=0
  fi
  if [ "$code" != 0 ]; then
    if [ -n "$previous" ] && [ "$previous" != "$id" ] && [ -f "$BASE/releases/$previous/.complete" ]; then
      say "Release $id did not start. Going back to $previous." >&2
      act rm -f "$BASE/releases/$id/.complete"
      switch_release "$previous"
      if start_service; then
        die "Release $id was rolled back to $previous and $previous is running. Fix the cause, build a new package and run deploy --apply again."
      fi
      die "Release $id was marked as failed. Going back to $previous did not give a healthy start either. Read the logs, then run  $BASE/bin/scoot-deploy start --apply  or fix the settings."
    fi
    earlier=$(previous_release "$id")
    if [ -n "$earlier" ]; then
      die "Release $id did not start. It is the release that was already running, so nothing was rolled back. The link stays on $id. Earlier release $earlier is kept. Fix the cause, then run  $BASE/bin/scoot-deploy start --apply  or go back with  $BASE/bin/scoot-deploy rollback --apply."
    fi
    die "Release $id did not start and no earlier release is kept, so nothing was rolled back. The link stays on $id. Fix the cause, then run  $BASE/bin/scoot-deploy start --apply."
  fi
  if [ -n "$previous" ]; then
    unit_before=$(cat "/etc/systemd/system/$UNIT.service" 2>/dev/null || true)
    install_unit_and_site
    if [ "$APPLY" = 1 ] && [ "$unit_before" != "$(cat "/etc/systemd/system/$UNIT.service" 2>/dev/null || true)" ]; then
      start_service || die "The new service unit did not start $UNIT healthy. Release $id is linked. Read the log, then run  $BASE/bin/scoot-deploy start --apply."
    fi
  fi
  prune_releases
  say ""
  say "Done. The dashboard files are installed but scootsales.my is not changed. Next:  $BASE/bin/scoot-deploy dashboard --default-workspace CODE"
  say "Later commands:  $BASE/bin/scoot-deploy status | start | rollback | certificate | dashboard | dashboard-revert"
}

do_rollback() {
  local current previous
  need_root
  [ -L "$BASE/platform" ] || die "No release is installed."
  current=$(basename "$(readlink -f "$BASE/platform")")
  previous=$(previous_release "$current")
  [ -n "$previous" ] || die "No older complete release is kept."
  say "Roll back from $current to $previous."
  switch_release "$previous"
  start_service
}

do_install_key() {
  local kind=${POS[0]:-} project= file dest project_id central_email copilot_email
  need_root
  case "$kind" in
    central)
      file=${POS[1]:-}
      dest=$ETC/central-key.json
      ;;
    company)
      project=${POS[1]:-}
      file=${POS[2]:-}
      [[ "$project" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || die "Give the company project ID, for example: install-key company cos40005 /root/key.json"
      dest=$ETC/company-keys/$project.json
      ;;
    copilot)
      file=${POS[1]:-}
      dest=$COPILOT_KEY_FILE
      id "$COPILOT_USER" >/dev/null 2>&1 || [ "$APPLY" != 1 ] || die "Run copilot-install --apply first."
      ;;
    *) die "Use: install-key central FILE   or   install-key company PROJECT_ID FILE   or   install-key copilot FILE" ;;
  esac
  [ -f "$file" ] || die "The key file '$file' does not exist."
  project_id=$(python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); print(d.get("project_id", "") if d.get("type") == "service_account" else "")' "$file" 2>/dev/null) \
    || die "The file is not a JSON file."
  [ -n "$project_id" ] || die "The file is not a Google service account key."
  if [ "$kind" = company ] && [ "$project_id" != "$project" ]; then
    die "The key belongs to project '$project_id', not '$project'. Nothing was copied."
  fi
  if [ "$kind" = copilot ]; then
    central_email=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1])).get("client_email", ""))' "$ETC/central-key.json" 2>/dev/null || true)
    copilot_email=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1])).get("client_email", ""))' "$file" 2>/dev/null || true)
    if [ -n "$central_email" ] && [ "$copilot_email" = "$central_email" ]; then
      die "This is the central platform key. Scout needs its own budget key. Nothing was copied."
    fi
    act install -d -m 0700 -o "$COPILOT_USER" -g "$COPILOT_USER" "$(dirname "$dest")"
    act install -m 0600 -o "$COPILOT_USER" -g "$COPILOT_USER" "$file" "$dest"
  else
    act install -d -m 0750 -o root -g scoot "$ETC"
    act install -d -m 0700 -o scoot -g scoot "$ETC/company-keys"
    act install -m 0600 -o scoot -g scoot "$file" "$dest"
  fi
  act shred -u "$file"
  if [ "$kind" = central ] && [ -z "$(env_value PLATFORM_PROJECT_ID)" ]; then
    if [ "$APPLY" = 1 ]; then
      set_env PLATFORM_PROJECT_ID "$project_id"
      say "set    PLATFORM_PROJECT_ID=$project_id"
    else
      say "DRY  set PLATFORM_PROJECT_ID=$project_id"
    fi
  fi
}

do_signing_key() {
  local out seed public name
  need_root
  [ -f "$ENV_FILE" ] || die "$ENV_FILE does not exist. Run deploy --apply first."
  for name in PLATFORM_SIGNING_KEY_ID PLATFORM_SIGNING_KEY PLATFORM_PUBLIC_KEYS; do
    [ -z "$(env_value "$name")" ] || die "A signing key is already set. This script never replaces it."
  done
  if [ "$APPLY" != 1 ]; then
    say "DRY  make an Ed25519 signing key and store its three settings in $ENV_FILE (the private part is never shown)"
    return 0
  fi
  [ -x "$BASE/platform/venv/bin/python" ] || die "No release is installed. Run deploy --apply first."
  out=$(cd "$BASE/platform" && PYTHONDONTWRITEBYTECODE=1 ./venv/bin/python -c 'from platform_service.signing import Signer; s = Signer.generate("scoot-1"); print(s.seed()); print(s.public_key())')
  seed=$(sed -n 1p <<<"$out")
  public=$(sed -n 2p <<<"$out")
  set_env PLATFORM_SIGNING_KEY_ID scoot-1
  set_env PLATFORM_SIGNING_KEY "$seed"
  set_env PLATFORM_PUBLIC_KEYS "scoot-1=$public"
  say "Signing key made. Public part (safe to share): PLATFORM_PUBLIC_KEYS=scoot-1=$public"
  say "Add the PLATFORM_PUBLIC_KEYS line to deploy/droplet/.env.control on your PC, then build a new package (the dashboard needs it)."
  say "Keep an offline copy of $ENV_FILE. Without the private part every signed company record stops working."
}

do_create_owner() {
  local email=${POS[0]:-} owners password again
  need_root
  [[ "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+$ ]] || die "Use: create-owner EMAIL"
  email=${email,,}
  [ -f "$ENV_FILE" ] || die "$ENV_FILE does not exist. Run deploy --apply first."
  owners=,$(env_value PLATFORM_STAFF_BOOTSTRAP_OWNERS),
  owners=${owners,,}
  [[ "${owners// /}" == *",$email,"* ]] || die "$email is not in PLATFORM_STAFF_BOOTSTRAP_OWNERS. Nothing was changed."
  [ -f "$(env_value GOOGLE_APPLICATION_CREDENTIALS)" ] || die "The central key is missing. Run install-key central first."
  if [ "$APPLY" != 1 ]; then
    say "DRY  ask for a password, then create or update the Firebase user $email with a verified email"
    return 0
  fi
  [ -x "$BASE/platform/venv/bin/python" ] || die "No release is installed. Run deploy --apply first."
  read -rsp "New password for $email (12 to 128 characters, not shown): " password; echo
  read -rsp "Type it again: " again; echo
  [ "$password" = "$again" ] || die "The two passwords differ. Nothing was changed."
  [ ${#password} -ge 12 ] && [ ${#password} -le 128 ] || die "Use 12 to 128 characters. Nothing was changed."
  if ! ( set -a; . "$ENV_FILE"; set +a; OWNER_EMAIL=$email OWNER_PASSWORD=$password "$BASE/platform/venv/bin/python" -c '
import os
import firebase_admin
from firebase_admin import auth, credentials
firebase_admin.initialize_app(
    credentials.Certificate(os.environ["GOOGLE_APPLICATION_CREDENTIALS"]),
    {"projectId": os.environ["PLATFORM_PROJECT_ID"]},
)
email, password = os.environ["OWNER_EMAIL"], os.environ["OWNER_PASSWORD"]
try:
    user = auth.get_user_by_email(email)
    auth.update_user(user.uid, password=password, email_verified=True, disabled=False)
    print("Firebase user updated.")
except auth.UserNotFoundError:
    auth.create_user(email=email, password=password, email_verified=True)
    print("Firebase user created.")
' ); then
    die "Firebase refused. Check the central key and PLATFORM_PROJECT_ID. Nothing was changed."
  fi
}

brevo_run() {
  local api_key sender
  api_key=$(env_value BREVO_API_KEY)
  sender=$(env_value PLATFORM_MAIL_SENDER)
  cd "$BASE/platform"
  env -i PATH=/usr/bin:/bin BREVO_API_KEY="$api_key" PLATFORM_MAIL_SENDER="$sender" ./venv/bin/python scripts/brevo_templates.py "$@"
}

do_brevo() {
  local arg has_apply=0 ids compact
  need_root_for_brevo
  [ -x "$BASE/platform/venv/bin/python" ] || die "No release is installed. Run deploy --apply first."
  for arg in ${PASS[@]+"${PASS[@]}"}; do
    [ "$arg" = --apply ] && has_apply=1
  done
  if [ "$has_apply" = 0 ]; then
    ( brevo_run ${PASS[@]+"${PASS[@]}"} )
    return 0
  fi
  if ! ids=$( brevo_run "${PASS[@]}" ); then
    die "The Brevo step failed. The settings file was not changed."
  fi
  compact=$("$BASE/platform/venv/bin/python" -c 'import json, sys; print(json.dumps(json.load(sys.stdin), separators=(",", ":")))' <<<"$ids") \
    || die "The template ids are not readable. The settings file was not changed."
  set_env PLATFORM_BREVO_TEMPLATE_IDS "'$compact'"
  say "Saved PLATFORM_BREVO_TEMPLATE_IDS in $ENV_FILE."
}

need_root_for_brevo() {
  [ "$(id -u)" = 0 ] || die "Run this script as root."
  [ -f "$ENV_FILE" ] || die "$ENV_FILE does not exist. Run deploy --apply first."
}

certificate_for() {
  local host=$1 kind=$2 resolved
  if [ -f "/etc/letsencrypt/live/$host/fullchain.pem" ]; then
    say "keep   certificate for $host (exists)"
    render_nginx "$host" "$kind"
    return 0
  fi
  nginx_layout "$host"
  [ -f "$NGINX_TARGET" ] || die "$NGINX_TARGET does not exist. Run deploy --apply first."
  resolved=$(getent hosts "$host" | awk 'NR == 1 { print $1 }') || true
  [ -n "$resolved" ] || die "$host has no DNS address yet. Add the A record, wait a few minutes, then run this again."
  say "DNS gives $host = $resolved. This server has: $(hostname -I)"
  act certbot certonly --webroot -w /var/www/certbot -d "$host" -m "$EMAIL" --agree-tos --no-eff-email --non-interactive --deploy-hook "systemctl reload nginx"
  render_nginx "$host" "$kind"
}

do_certificate() {
  need_root
  [ "$SKIP_NGINX" = 0 ] || die "--skip-nginx and certificate cannot be used together."
  [ -n "$EMAIL" ] || die "Give your email address: certificate --email you@example.com --agree-tos"
  [ "$AGREE" = 1 ] || die "Let's Encrypt needs you to accept its terms (https://letsencrypt.org/repository/). Add --agree-tos to say yes."
  check_ports
  if ! command -v certbot >/dev/null 2>&1; then
    act apt-get update -qq
    act apt-get install -y -qq certbot
  fi
  act install -d -m 0755 /var/www/certbot
  certificate_for "$CONTROL_HOST" control
  say ""
  say "This action only handles $CONTROL_HOST. The certificate of $DASHBOARD_HOST is read and reported by:  scoot-deploy dashboard"
}

site_py() { python3 -I "$HERE/nginx_site.py" "$@"; }

mask() { sed -E '/(password|secret|token|authorization|api[_-]?key)/I s/^(.).*/\1[line hidden: it may hold a secret]/'; }

need_root_always() {
  [ "$(id -u)" = 0 ] || die "Run this action as root. It reads the nginx settings."
}

docker_owner_steps() {
  cat >&2 <<EOF

STOP: port $OTHER_PORT is owned by '$OTHER_OWNER', not by nginx. Nothing was changed.

What this means: a program other than nginx (most likely a Docker container) listens on the
web ports and serves $DASHBOARD_HOST itself. This script does not stop, restart or edit it.
That program may also serve the other server on this droplet. If you stop it, that server
goes down too.

The new dashboard files are ready in $SOURCE/dashboard. Choose one way and do it yourself:

  1. Smallest change: replace the web files inside that container.
     Ask the teammate which folder inside the container holds the Flutter web files.
     Copy the new files in with:  docker cp $SOURCE/dashboard/. CONTAINER:FOLDER/
     A restart from the main branch build brings the old site back. To go back, copy the old files in again.
  2. Bigger change: let nginx own ports 80 and 443. Publish the container only on 127.0.0.1
     (for example 127.0.0.1:8080), then add the host names, the certificate and a proxy
     rule to nginx. Do this only in a planned time window, because ports 80 and 443
     are down for every site while you move them.

Run  docker ps  to see the container name and its port mapping.
EOF
}

other_dashboard_hosts() {
  local link
  {
    printf '%s\n' "$CONTROL_HOST" "$PRIMARY_DASHBOARD_HOST" "${KNOWN_DASHBOARD_HOSTS[@]}"
    for link in "$WWW"/current-*; do
      if [ -L "$link" ]; then printf '%s\n' "${link#"$WWW"/current-}"; fi
    done
  } | awk -v self="$DASHBOARD_HOST" '$0 != self && !seen[$0]++'
}

discover_site() {
  local port owners owner lines report reason
  step "How $DASHBOARD_HOST is served now"
  for port in 80 443; do
    owners=$(port_owners "$port" | tr '\n' ' ' || true)
    say "Port $port is owned by: ${owners:-nobody that ss can show}"
    for owner in $owners; do
      if [ "$owner" != nginx ] && [ -z "$OTHER_OWNER" ]; then
        OTHER_OWNER=$owner
        OTHER_PORT=$port
      fi
    done
  done
  if command -v docker >/dev/null 2>&1; then
    lines=$(docker ps --format '{{.Names}}  {{.Image}}  {{.Ports}}' 2>/dev/null | head -n 20 || true)
    if [ -n "$lines" ]; then
      say "Docker containers that run now (name, image, ports):"
      sed 's/^/  /' <<<"$lines"
    else
      say "Docker: no running container (or docker is not running)."
    fi
  else
    say "Docker: not installed."
  fi
  if [ -n "$OTHER_OWNER" ]; then
    docker_owner_steps
    exit 1
  fi
  command -v nginx >/dev/null 2>&1 || die "nginx is not installed and no other program owns port 80 or 443. Nothing was changed."
  command -v python3 >/dev/null 2>&1 || die "python3 is missing. Install it, then run this action again."
  nginx -t >/dev/null 2>&1 || die "The current nginx configuration fails nginx -t. Fix it first. Nothing was changed."
  nginx -T >"$WORK/nginx.dump" 2>/dev/null || die "nginx -T failed. Nothing was changed."
  say "nginx server blocks that name $DASHBOARD_HOST:"
  report=$(site_py report "$WORK/nginx.dump" "$DASHBOARD_HOST")
  printf '%s\n' "${report:-  (none found)}" | mask
  if ! reason=$(site_py check "$WORK/nginx.dump" "$DASHBOARD_HOST"); then
    die "$reason Nothing was changed. Send us the report above."
  fi
  if ! reason=$(site_py isolated "$WORK/nginx.dump" "$DASHBOARD_HOST" $(other_dashboard_hosts)); then
    die "$reason Nothing was changed."
  fi
  mapfile -t SITE_FILES < <(site_py files "$WORK/nginx.dump" "$DASHBOARD_HOST")
  mapfile -t SITE_CERTS < <(site_py certs "$WORK/nginx.dump" "$DASHBOARD_HOST")
  mapfile -t SITE_ROOTS < <(site_py roots "$WORK/nginx.dump" "$DASHBOARD_HOST")
}

report_certificates() {
  local cert end state name
  step "Certificate"
  if [ ${#SITE_CERTS[@]} -eq 0 ]; then
    say "No ssl_certificate line in the server block (it may come from an include). Look at it yourself:  certbot certificates"
    return 0
  fi
  command -v openssl >/dev/null 2>&1 || { say "openssl is missing. Look at the certificate yourself:  certbot certificates"; return 0; }
  for cert in "${SITE_CERTS[@]}"; do
    if [ ! -f "$cert" ]; then
      say "Certificate $cert: file not found."
      continue
    fi
    end=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | sed 's/^notAfter=//' || true)
    state=ok
    if ! openssl x509 -checkend 0 -noout -in "$cert" >/dev/null 2>&1; then
      state=EXPIRED
    elif ! openssl x509 -checkend "$CERT_WARN_SECONDS" -noout -in "$cert" >/dev/null 2>&1; then
      state="ends in less than 14 days"
    fi
    say "Certificate $cert: ends ${end:-unknown} ($state)"
    if [ "$state" != ok ]; then
      name=$(sed -n 's|^/etc/letsencrypt/live/\([^/]*\)/.*|\1|p' <<<"$cert")
      if [ -n "$name" ]; then
        say "  This script does not renew it. Run this yourself:"
        say "    certbot renew --cert-name $name && nginx -t && systemctl reload nginx"
      else
        say "  This file is not in /etc/letsencrypt/live. Renew it with the tool that made it."
      fi
    fi
  done
}

plan_dashboard() {
  local src=$1 i file root size total=0 dash free probe copilot_flag= zone_flag= current
  current=$(site_current)
  step "Plan"
  if is_primary_host && [ -f "/etc/systemd/system/$COPILOT_UNIT.service" ]; then copilot_flag=--copilot; fi
  ! grep -q 'limit_req_zone .*zone=scoot_copilot:' "$WORK/nginx.dump" || zone_flag=--zone-elsewhere
  for i in "${!SITE_FILES[@]}"; do
    file=${SITE_FILES[$i]}
    [ -f "$file" ] || die "$file is not a file. Nothing was changed."
    site_py rewrite "$file" "$DASHBOARD_HOST" "$current" ${DEFAULT_WORKSPACE:+"$DEFAULT_WORKSPACE"} $copilot_flag $zone_flag >"$WORK/new.$i" || die "Could not prepare the new nginx file for $file. Nothing was changed."
    [ -z "$copilot_flag" ] || zone_flag=--zone-elsewhere
    if cmp -s "$file" "$WORK/new.$i"; then
      say "keep   $file (already serves $current)"
    else
      say "Change in $file (only root, location /, location = /workspace.json, and, for $PRIMARY_DASHBOARD_HOST when $COPILOT_UNIT is installed, location = /health and location = /v1/interpret change; www.$DASHBOARD_HOST becomes a 301 redirect to https://$DASHBOARD_HOST; the certificate lines and all other directives stay):"
      { diff -U1 "$file" "$WORK/new.$i" || true; } | tail -n +3 | mask | sed 's/^/  /'
    fi
  done
  for root in "${SITE_ROOTS[@]}"; do
    case "$root" in "$WWW"|"$WWW"/*) say "keep   web root $root (made by this script, older versions stay in $WWW)"; continue ;; esac
    [ -d "$root" ] || { say "note   web root $root does not exist"; continue; }
    size=$(du -sm "$root" 2>/dev/null | awk '{ print $1 }')
    [ "${size:-0}" -le "$MAX_ROOT_MB" ] || die "The web root $root is ${size} MB. This script copies at most ${MAX_ROOT_MB} MB as a backup. Back it up yourself first. Nothing was changed."
    total=$((total + ${size:-0}))
    say "Web root $root: ${size:-0} MB, copied to the backup."
  done
  if [ -n "$DEFAULT_WORKSPACE" ]; then
    say "Default workspace: $DEFAULT_WORKSPACE. https://$DASHBOARD_HOST/ opens this company. /workspace.json is answered by the platform service at 127.0.0.1:8100."
  else
    say "note   no --default-workspace. /workspace.json would answer 404 and https://$DASHBOARD_HOST/ would show 'This workspace does not exist.' --apply needs  --default-workspace CODE."
  fi
  dash=$(du -sm "$src" | awk '{ print $1 }')
  probe=$BASE
  [ -d "$probe" ] || probe=/
  free=$(df -Pm "$probe" | awk 'NR == 2 { print $4 }')
  if [ "$free" -lt $((total + 2 * dash + 200)) ]; then
    die "Only ${free} MB of disk is free. The backup and the new files need about $((total + 2 * dash + 200)) MB. Nothing was changed."
  fi
}

restore_files() {
  local from=$1 i path
  while IFS=$'\t' read -r i path; do
    [ -n "$i" ] || continue
    cat "$from/conf/$i" >"$path"
    say "restored $path"
  done <"$from/manifest"
}

restore_current() {
  local from=$1 current
  current=$(site_current)
  if [ -f "$from/current.target" ]; then
    [ -d "$(cat "$from/current.target")" ] || die "The folder $(cat "$from/current.target") named in $from is gone. $current was not changed."
    ln -sfn "$(cat "$from/current.target")" "$current.next"
    mv -T -f "$current.next" "$current"
  else
    rm -f "$current"
  fi
}

ensure_origins() {
  local wanted=("https://$PRIMARY_DASHBOARD_HOST") origin current updated url changed=0 url_ok=1
  is_primary_host || wanted+=("https://$DASHBOARD_HOST")
  if [ ! -f "$ENV_FILE" ]; then
    say "note   $ENV_FILE does not exist yet. Run deploy --apply first. Its template lists https://$DASHBOARD_HOST."
    return 0
  fi
  current=$(env_value PLATFORM_CLIENT_CORS_ORIGINS)
  updated=$current
  for origin in "${wanted[@]}"; do
    if [[ ",${current// /}," != *",$origin,"* ]]; then
      updated=${updated:+$updated,}$origin
      changed=1
    fi
  done
  url=$(env_value PLATFORM_DASHBOARD_URL)
  if is_primary_host && [ "$url" != "https://$DASHBOARD_HOST" ]; then url_ok=0; fi
  if [ "$changed" = 0 ] && [ "$url_ok" = 1 ]; then
    say "keep   PLATFORM_CLIENT_CORS_ORIGINS and PLATFORM_DASHBOARD_URL (already right)"
    return 0
  fi
  if [ "$APPLY" != 1 ]; then
    say "DRY  set PLATFORM_CLIENT_CORS_ORIGINS=$updated"
    if is_primary_host; then say "DRY  set PLATFORM_DASHBOARD_URL=https://$DASHBOARD_HOST"; else say "DRY  keep PLATFORM_DASHBOARD_URL=$url (password and sign-in links keep this host)"; fi
    say "DRY  systemctl restart $UNIT (only if it runs)"
    return 0
  fi
  set_env PLATFORM_CLIENT_CORS_ORIGINS "$updated"
  say "set    PLATFORM_CLIENT_CORS_ORIGINS=$updated"
  if is_primary_host; then
    set_env PLATFORM_DASHBOARD_URL "https://$DASHBOARD_HOST"
    say "set    PLATFORM_DASHBOARD_URL=https://$DASHBOARD_HOST"
  else
    say "keep   PLATFORM_DASHBOARD_URL=$url (password and sign-in links keep this host)"
  fi
  if systemctl is-active --quiet "$UNIT"; then
    systemctl restart "$UNIT"
    say "restarted $UNIT to read the new settings"
  fi
}

rollback_targets() {
  local bk name prefix seen=
  while IFS= read -r bk; do
    name=$(basename "$bk")
    [[ "$name" =~ ^(.+)-[0-9]{8}-[0-9]{6}$ ]] || continue
    prefix=${BASH_REMATCH[1]}
    case "$name" in reverted-*) continue ;; esac
    case "$seen" in *"|$prefix|"*) continue ;; esac
    [ -r "$bk/current.target" ] && [ -s "$bk/current.target" ] || continue
    seen="$seen|$prefix|"
    printf '%s\n' "$(readlink -m "$(cat "$bk/current.target")")"
  done < <(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r)
}

prune_dashboards() {
  local link dir linked=
  for link in "$WWW"/current "$WWW"/current-*; do
    if [ -L "$link" ]; then linked="$linked$(readlink -f "$link")"$'\n'; fi
  done
  linked="$linked$(rollback_targets)"$'\n'
  for dir in $(find "$WWW" -mindepth 1 -maxdepth 1 -type d | sort -r | tail -n +$((KEEP_DASHBOARDS + 1))); do
    grep -qxF "$(readlink -f "$dir")" <<<"$linked" || act rm -rf "$dir"
  done
}

workspace_body_is_record() {
  python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); sys.exit(0 if isinstance(d, dict) and all(isinstance(d.get(k), str) for k in ("alg", "keyId", "payload", "signature")) else 1)' "$1" 2>/dev/null
}

check_live_site() {
  local home workspace body=$WORK/workspace.body
  local attempt
  for attempt in 1 2 3 4 5; do
    home=$(curl -ksS -o /dev/null -w '%{http_code}' --max-time 10 --resolve "$DASHBOARD_HOST:443:127.0.0.1" "https://$DASHBOARD_HOST/" 2>/dev/null || true)
    workspace=$(curl -ksS -o "$body" -w '%{http_code}' --max-time 10 --resolve "$DASHBOARD_HOST:443:127.0.0.1" "https://$DASHBOARD_HOST/workspace.json" 2>/dev/null || true)
    if [ "$home" = 200 ] && [ "$workspace" = 200 ] && workspace_body_is_record "$body"; then break; fi
    [ "$attempt" = 5 ] || sleep 2
  done
  if [ "$home" != 200 ]; then
    say "WARN  https://$DASHBOARD_HOST/ answered ${home:-nothing} on this server (expected 200). Look in a browser. To go back:  scoot-deploy dashboard-revert$(host_flag) --apply"
  fi
  if [ "$workspace" = 200 ] && workspace_body_is_record "$body"; then
    [ "$home" != 200 ] || say "OK    https://$DASHBOARD_HOST/ answers 200 and /workspace.json answers 200 with the signed record of '$DEFAULT_WORKSPACE'"
  elif ! curl -fsS --max-time 3 "$HEALTH_URL" >/dev/null 2>&1; then
    say "WARN  /workspace.json answered ${workspace:-nothing} because $UNIT does not answer on $HEALTH_URL yet. https://$DASHBOARD_HOST/ shows 'The company record is unavailable' until it runs. Fill the settings and run:  scoot-deploy start --apply"
  elif [ "$workspace" = 404 ]; then
    say "WARN  /workspace.json answered 404: the platform service does not know the company code '$DEFAULT_WORKSPACE'. Create the company in the Control Centre, or run  scoot-deploy dashboard$(host_flag) --default-workspace CODE --apply  with the right code."
  else
    say "WARN  /workspace.json answered ${workspace:-nothing} and not the signed record of '$DEFAULT_WORKSPACE' (expected 200 with JSON). Look at the log:  journalctl -u $UNIT -n 80 --no-pager. To go back:  scoot-deploy dashboard-revert$(host_flag) --apply"
  fi
}

cleanup_dashboard_action() {
  if [ -n "$WORK" ]; then rm -rf "$WORK"; fi
  if [ -n "$LOCK_DIR" ]; then rm -rf "$LOCK_DIR"; fi
}

lock_action() {
  local name=$1 lock=$BASE/state/$1.lock holder
  trap cleanup_dashboard_action EXIT
  [ "$APPLY" = 1 ] || return 0
  install -d -m 0700 "$BASE/state"
  if ! mkdir -m 0700 "$lock" 2>/dev/null; then
    holder=$(cat "$lock/pid" 2>/dev/null || true)
    die "Another $name action holds the lock $lock${holder:+ (process $holder)}. Wait for it to end. If no such process runs, remove the folder with  rm -rf $lock  and run this again. Nothing was changed."
  fi
  LOCK_DIR=$lock
  printf '%s\n' "$$" >"$lock/pid"
}

do_dashboard() {
  local src=$SOURCE/dashboard stamp bk i file root j changed=0 current
  current=$(site_current)
  need_root_always
  [ -f "$src/index.html" ] || die "The dashboard is not in this package ($src/index.html is missing). Build a package that says 'Company dashboard: yes'."
  if [ "$APPLY" = 1 ] && [ -z "$DEFAULT_WORKSPACE" ]; then
    die "Give the company that https://$DASHBOARD_HOST/ opens:  scoot-deploy dashboard$(host_flag) --default-workspace CODE --apply  (the code is on the company page in the Control Centre). Nothing was changed."
  fi
  lock_action dashboard
  WORK=$(mktemp -d)
  discover_site
  report_certificates
  plan_dashboard "$src"
  if [ "$APPLY" != 1 ]; then
    step "What --apply would do"
    say "DRY  copy the nginx file(s) and the web root of $DASHBOARD_HOST to $BACKUP_DIR/$(backup_prefix)-<time>/"
    say "DRY  copy the dashboard to $WWW/<time> and link $current to it"
    is_primary_host || say "DRY  $PRIMARY_DASHBOARD_HOST keeps its own link $WWW/current and its own nginx file; they are not touched"
    if is_primary_host; then
      say "DRY  write the changed nginx file(s) (root, location /, location = /workspace.json, location = /health, location = /v1/interpret limited to 10 requests per second per address, burst 20), run nginx -t; if it fails: put the backup back and do not reload"
    else
      say "DRY  write the changed nginx file(s) (root, location /, location = /workspace.json; /health and /v1/interpret stay on $PRIMARY_DASHBOARD_HOST), run nginx -t; if it fails: put the backup back and do not reload"
    fi
    say "DRY  systemctl reload nginx"
    ensure_origins
    say "DRY  go back later with:  scoot-deploy dashboard-revert$(host_flag) --apply"
    return 0
  fi
  stamp=$(date +%Y%m%d-%H%M%S)
  bk=$BACKUP_DIR/$(backup_prefix)-$stamp
  [ ! -e "$bk" ] || die "$bk exists. Wait a second, then run this again."
  step "Backup"
  install -d -m 0700 "$BACKUP_DIR" "$bk" "$bk/conf" "$bk/webroot"
  : >"$bk/manifest"
  : >"$bk/webroot.list"
  for i in "${!SITE_FILES[@]}"; do
    file=${SITE_FILES[$i]}
    cp -p "$file" "$bk/conf/$i"
    cmp -s "$file" "$bk/conf/$i" || die "The backup of $file differs from the original. Nothing else was changed."
    printf '%s\t%s\n' "$i" "$file" >>"$bk/manifest"
    say "saved  $file in $bk/conf/$i"
  done
  j=0
  for root in "${SITE_ROOTS[@]}"; do
    case "$root" in "$WWW"|"$WWW"/*) continue ;; esac
    [ -d "$root" ] || continue
    cp -a "$root" "$bk/webroot/$j"
    diff -rq "$root" "$bk/webroot/$j" >/dev/null || die "The backup of $root differs from the original. Nothing else was changed."
    printf '%s\t%s\n' "$j" "$root" >>"$bk/webroot.list"
    say "saved  $root in $bk/webroot/$j"
    j=$((j + 1))
  done
  if [ -L "$current" ]; then readlink "$current" >"$bk/current.target"; fi
  step "Dashboard files"
  install -d -m 0755 "$WWW"
  mkdir -m 0755 "$WWW/$stamp" || die "$WWW/$stamp exists already. Nothing else was changed. Wait a second, then run this again."
  cp -a --no-preserve=ownership "$src/." "$WWW/$stamp/"
  act rm -f "$WWW/$stamp/workspace.json"
  chmod -R u=rwX,go=rX "$WWW/$stamp"
  [ -f "$WWW/$stamp/index.html" ] || die "The copy in $WWW/$stamp has no index.html. The nginx files were not changed."
  [ -f "$WWW/$stamp/privacy/index.html" ] || die "The copy in $WWW/$stamp has no privacy/index.html, so https://$DASHBOARD_HOST/privacy would show the sign-in page. Build the package again with PRIVACY_CONTACT_EMAIL set. The nginx files were not changed."
  ln -sfn "$WWW/$stamp" "$current.next"
  mv -T -f "$current.next" "$current"
  say "linked $current -> $WWW/$stamp"
  step "nginx"
  for i in "${!SITE_FILES[@]}"; do
    file=${SITE_FILES[$i]}
    if cmp -s "$file" "$WORK/new.$i"; then continue; fi
    cat "$WORK/new.$i" >"$file"
    changed=1
    say "wrote  $file"
  done
  if [ "$changed" = 1 ]; then
    if ! nginx -t; then
      restore_files "$bk"
      restore_current "$bk"
      die "nginx -t failed with the new block. The backup is back in place and nginx was NOT reloaded. The backup is in $bk."
    fi
    systemctl reload nginx
    say "reloaded nginx"
  else
    say "keep   nginx files (no change needed, nginx is not reloaded; the new files are served at once)"
  fi
  prune_dashboards
  step "Settings of the platform service"
  ensure_origins
  step "Check"
  check_live_site
  say ""
  say "Open  https://$DASHBOARD_HOST/  (company '$DEFAULT_WORKSPACE') and  https://$DASHBOARD_HOST/w/CODE  (other companies) and test them."
  say "Go back if something is wrong:  scoot-deploy dashboard-revert$(host_flag) --apply"
  say "Backup: $bk"
}

do_dashboard_revert() {
  local bk stamp snap i path j current prefix
  current=$(site_current)
  prefix=$(backup_prefix)
  need_root_always
  lock_action dashboard
  bk=$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name "$prefix-[0-9]*" 2>/dev/null | sort | tail -n 1)
  [ -n "$bk" ] || die "No backup of $DASHBOARD_HOST found in $BACKUP_DIR. Nothing was changed."
  [ -s "$bk/manifest" ] || die "The backup $bk has no file list. Nothing was changed."
  if [ -f "$bk/current.target" ] && [ ! -d "$(cat "$bk/current.target")" ]; then
    die "The backup $bk links $current to $(cat "$bk/current.target"), and that folder is gone. Nothing was changed."
  fi
  step "Revert to $bk"
  while IFS=$'\t' read -r i path; do
    [ -n "$i" ] || continue
    say "restore $path from $bk/conf/$i"
  done <"$bk/manifest"
  if [ -f "$bk/current.target" ]; then
    say "link    $current -> $(cat "$bk/current.target")"
  else
    say "remove  $current (it did not exist before this backup)"
  fi
  say "then nginx -t, and systemctl reload nginx if it passes"
  if [ "$APPLY" != 1 ]; then
    return 0
  fi
  stamp=$(date +%Y%m%d-%H%M%S)
  snap=$BACKUP_DIR/reverted-$prefix-$stamp
  install -d -m 0700 "$snap" "$snap/conf"
  : >"$snap/manifest"
  while IFS=$'\t' read -r i path; do
    [ -n "$i" ] || continue
    cp -p "$path" "$snap/conf/$i"
    printf '%s\t%s\n' "$i" "$path" >>"$snap/manifest"
  done <"$bk/manifest"
  if [ -L "$current" ]; then readlink "$current" >"$snap/current.target"; fi
  restore_files "$bk"
  if [ -s "$bk/webroot.list" ]; then
    while IFS=$'\t' read -r j path; do
      [ -n "$j" ] || continue
      if [ ! -e "$path" ]; then
        cp -a "$bk/webroot/$j" "$path"
        say "restored web root $path"
      fi
    done <"$bk/webroot.list"
  fi
  restore_current "$bk"
  if ! nginx -t; then
    restore_files "$snap"
    restore_current "$snap"
    die "nginx -t failed after the revert. The files from before the revert are back and nginx was NOT reloaded. They are also in $snap."
  fi
  systemctl reload nginx
  say "Reverted and reloaded nginx. The files from before the revert are in $snap."
}

promo_unused() {
  local src=$1 file name
  [ -d "$src/product" ] || return 0
  for file in "$src"/product/*; do
    [ -f "$file" ] || continue
    name=${file#"$src"/product/}
    grep -rqF --include='*.html' --include='*.css' --include='*.js' "product/$name" "$src" || printf '%s\n' "$name"
  done
}

prune_promo() {
  local current dir keep=$KEEP_PROMO_RELEASES
  [ -d "$PROMO_WWW/releases" ] || return 0
  [ "$APPLY" = 1 ] || keep=$((keep - 1))
  current=$(readlink -f "$PROMO_WWW/current" 2>/dev/null || true)
  for dir in $(find "$PROMO_WWW/releases" -mindepth 1 -maxdepth 1 -type d | sort -r | tail -n +$((keep + 1))); do
    [ "$(readlink -f "$dir")" = "$current" ] || act rm -rf "$dir"
  done
}

do_promo() {
  local src=${POS[0]:-} id dest size free probe name port owners owner unused=()
  need_root
  [ -n "$src" ] || die "Give the folder with the built site, for example:  promo /root/site-static"
  [ -f "$src/index.html" ] || die "$src/index.html is missing. Copy the site-static folder made by  npm run export:static. Nothing was changed."
  if [ -n "$EMAIL" ] || [ "$AGREE" = 1 ]; then
    { [ -n "$EMAIL" ] && [ "$AGREE" = 1 ]; } || die "Give both --email EMAIL and --agree-tos to get the certificate. Nothing was changed."
  fi
  [ ! -L "$src" ] || die "$src is a link. Give the real folder. Nothing was changed."
  [ -z "$(find "$src" -mindepth 1 \( -type l -o -name '.*' \) -print -quit)" ] || die "$src holds a link or a hidden file. Upload only the files made by  npm run export:static. Nothing was changed."
  if [ "$SKIP_NGINX" = 1 ]; then
    [ -z "$EMAIL" ] || die "--skip-nginx and --email cannot be used together. Nothing was changed."
  else
    for port in 80 443; do
      owners=$(port_owners "$port")
      for owner in $owners; do
        [ "$owner" = nginx ] || die "Port $port is owned by '$owner', not by nginx. Serve $PROMO_WWW/current with that program, and run promo with --skip-nginx. Nothing was changed."
      done
    done
    command -v nginx >/dev/null 2>&1 || die "nginx is not installed. Nothing was changed."
    nginx -t >/dev/null 2>&1 || die "The current nginx configuration fails nginx -t. Fix it first. Nothing was changed."
    nginx_layout "$PROMO_HOST"
  fi
  lock_action promo
  step "Files for $PROMO_HOST"
  size=$(du -sm "$src" | awk '{ print $1 }')
  probe=$PROMO_WWW
  [ -d "$probe" ] || probe=/
  free=$(df -Pm "$probe" | awk 'NR == 2 { print $4 }')
  say "Site folder $src: ${size} MB. Free disk: ${free} MB."
  [ "$free" -ge $((size + 200)) ] || die "The site needs ${size} MB and 200 MB must stay free. Nothing was changed."
  mapfile -t unused < <(promo_unused "$src")
  id=$(date -u +%Y%m%d-%H%M%S)
  dest=$PROMO_WWW/releases/$id
  [ ! -e "$dest" ] || die "$dest already exists. Run this again in one second."
  act install -d -m 0755 "$PROMO_WWW/releases"
  act cp -rT "$src" "$dest"
  for name in "${unused[@]}"; do
    say "leave out product/$name (no page uses it)"
    act rm -f "$dest/product/$name"
  done
  act chmod -R u=rwX,go=rX "$dest"
  act ln -sfn "$dest" "$PROMO_WWW/current.next"
  act mv -T -f "$PROMO_WWW/current.next" "$PROMO_WWW/current"
  prune_promo
  if [ "$SKIP_NGINX" = 1 ]; then
    say "skip   nginx and certificate (--skip-nginx). Serve $PROMO_WWW/current yourself."
    return 0
  fi
  step "nginx for $PROMO_HOST"
  act install -d -m 0755 /var/www/certbot
  render_nginx "$PROMO_HOST" promo
  if [ -f "/etc/letsencrypt/live/$PROMO_HOST/fullchain.pem" ]; then
    say "Check:  curl -sI https://$PROMO_HOST/   (expect HTTP/1.1 200 and a Content-Security-Policy line)"
    return 0
  fi
  if [ -z "$EMAIL" ]; then
    say "note   $PROMO_HOST has no certificate yet. Until it has one, nginx answers 404 on http."
    say "Next:  scoot-deploy promo $src --email EMAIL --agree-tos --apply"
    return 0
  fi
  step "Certificate for $PROMO_HOST"
  if ! command -v certbot >/dev/null 2>&1; then
    act apt-get update -qq
    act apt-get install -y -qq certbot
  fi
  if [ "$APPLY" = 1 ]; then
    certificate_for "$PROMO_HOST" promo
  else
    say "DRY  certbot certonly --webroot -w /var/www/certbot -d $PROMO_HOST (needs the DNS A record)"
    say "DRY  write the https nginx file from nginx-promo.https.conf.tpl, nginx -t && systemctl reload nginx"
  fi
}

do_public_key() {
  local value
  value=$(env_value PLATFORM_PUBLIC_KEYS)
  [ -n "$value" ] || die "No signing key yet. Run signing-key --apply first."
  say "PLATFORM_PUBLIC_KEYS=$value"
  say "Add this line to deploy/droplet/.env.control on your PC. It is public. Never add PLATFORM_SIGNING_KEY there."
}

do_status() {
  local missing link
  if [ -L "$BASE/platform" ]; then
    say "Current release: $(basename "$(readlink -f "$BASE/platform")")"
    say "Kept releases:   $(find "$BASE/releases" -mindepth 1 -maxdepth 1 -type d -printf '%f ' 2>/dev/null)"
  else
    say "No release installed."
  fi
  say "Service:         $(systemctl is-active "$UNIT" 2>/dev/null || true)"
  if systemctl is-enabled --quiet "$SCHEDULER_UNIT" 2>/dev/null; then
    say "Scheduler:       $(systemctl is-active "$SCHEDULER_UNIT" 2>/dev/null || true)"
  fi
  if curl -fsS --max-time 3 "$HEALTH_URL" >/dev/null 2>&1; then say "Health:          ok"; else say "Health:          no answer"; fi
  if [ -f "/etc/letsencrypt/live/$CONTROL_HOST/fullchain.pem" ]; then say "Certificate:     present for $CONTROL_HOST"; else say "Certificate:     none for $CONTROL_HOST"; fi
  if has_dashboard; then
    if [ -L "$(site_current)" ]; then
      say "Dashboard:       $DASHBOARD_HOST serves $(readlink -f "$(site_current)")"
    else
      say "Dashboard:       in this release, $DASHBOARD_HOST not switched yet (run: scoot-deploy dashboard --default-workspace CODE)"
    fi
    for link in "$WWW"/current-*; do
      if [ -L "$link" ] && [ "$link" != "$(site_current)" ]; then say "Dashboard:       ${link#"$WWW"/current-} serves $(readlink -f "$link")"; fi
    done
    warn_cors
  else
    say "Dashboard:       not in this release"
  fi
  missing=$(missing_settings)
  if [ -n "$missing" ]; then
    say "Empty or wrong settings:"
    sed 's/^/  /' <<<"$missing"
  else
    say "Settings:        all required values are set"
  fi
  say "Log command:     journalctl -u $UNIT -n 80 --no-pager"
  if [ -f "$COPILOT_ENV_FILE" ]; then
    say "Scout service:   $(systemctl is-active "$COPILOT_UNIT" 2>/dev/null || true)"
    if curl -fsS --max-time 3 "$COPILOT_HEALTH_URL" >/dev/null 2>&1; then say "Scout health:    ok"; else say "Scout health:    no answer"; fi
    missing=$(copilot_missing_settings)
    if [ -n "$missing" ]; then
      say "Empty or wrong Scout settings:"
      sed 's/^/  /' <<<"$missing"
    fi
    say "Scout log:      journalctl -u $COPILOT_UNIT -n 80 --no-pager"
  fi
  local company
  for company in "${FORECAST_COMPANIES[@]}"; do
    forecast_target "$company"
    if [ -f "/etc/systemd/system/$FORECAST_UNIT.timer" ]; then
      say "Forecast timer ($FORECAST_PROJECT_ID): $(systemctl is-enabled "$FORECAST_UNIT.timer" 2>/dev/null || true), last run $(systemctl is-failed "$FORECAST_UNIT" 2>/dev/null || true)"
      say "Forecast log:   journalctl -u $FORECAST_UNIT -n 50 --no-pager"
    fi
  done
}

do_headers() {
  [ -f "$HERE/check_headers.py" ] || die "This package has no check_headers.py. Build a new package."
  local hosts=("$CONTROL_HOST" "$PRIMARY_DASHBOARD_HOST") link
  for link in "$WWW"/current-*; do
    if [ -L "$link" ]; then hosts+=("${link#"$WWW"/current-}"); fi
  done
  hosts+=("$DASHBOARD_HOST")
  if [ -f "/etc/letsencrypt/live/$PROMO_HOST/fullchain.pem" ]; then hosts+=("$PROMO_HOST"); fi
  mapfile -t hosts < <(printf '%s
' "${hosts[@]}" | awk '!seen[$0]++')
  python3 -I "$HERE/check_headers.py" "${hosts[@]}" "--control-host=$CONTROL_HOST" "--promo-host=$PROMO_HOST"
}

scheduler_steps() {
  act install -m 0644 "$HERE/scoot-scheduler.service" "/etc/systemd/system/$SCHEDULER_UNIT.service" || return 1
  act systemctl daemon-reload || return 1
  act systemctl restart "$UNIT" || return 1
  act systemctl enable "$SCHEDULER_UNIT" || return 1
  if [ "$APPLY" != 1 ]; then
    say "DRY  systemctl restart $SCHEDULER_UNIT"
    return 0
  fi
  restart_scheduler
}

do_scheduler_install() {
  need_root
  [ -L "$BASE/platform" ] || die "No release is installed. Run deploy --apply first."
  [ -f "$HERE/scoot-scheduler.service" ] || die "This package has no scoot-scheduler.service. Build a new package."
  step "Jobs move out of $UNIT"
  if [ "$APPLY" = 1 ]; then
    set_env PLATFORM_SCHEDULER_ENABLED false
    say "set    PLATFORM_SCHEDULER_ENABLED=false in $ENV_FILE"
  else
    say "DRY  set PLATFORM_SCHEDULER_ENABLED=false in $ENV_FILE"
  fi
  step "Scheduler service"
  if ! scheduler_steps; then
    if [ "$APPLY" = 1 ]; then
      say "FAIL  the scheduler install did not finish. Putting the jobs back inside $UNIT." >&2
      systemctl disable --now "$SCHEDULER_UNIT" >/dev/null 2>&1 || true
      set_env PLATFORM_SCHEDULER_ENABLED true
      systemctl restart "$UNIT" || true
      say "set    PLATFORM_SCHEDULER_ENABLED=true. By hand the same way back is:  systemctl disable --now $SCHEDULER_UNIT; set PLATFORM_SCHEDULER_ENABLED=true in $ENV_FILE; scoot-deploy start --apply" >&2
    fi
    die "scheduler-install failed."
  fi
}

do_start() {
  need_root
  [ -L "$BASE/platform" ] || die "No release is installed. Run deploy --apply first."
  start_service
}

copilot_env_value() {
  [ -f "$COPILOT_ENV_FILE" ] || return 0
  sed -n "s/^$1=//p" "$COPILOT_ENV_FILE" | tail -n 1 | sed -e "s/^['\"]//" -e "s/['\"]\$//"
}

copilot_missing_settings() {
  local name
  for name in FIREBASE_PROJECT_ID COPILOT_THRESHOLD GEMINI_API_KEY; do
    [ -n "$(copilot_env_value "$name")" ] || printf '%s
' "$name"
  done
  [ -n "$(copilot_env_value COPILOT_BUDGET_PROJECT)" ] || printf '%s
' "COPILOT_BUDGET_PROJECT (the central project that keeps the daily assistant budget)"
  [ -f "$COPILOT_KEY_FILE" ] || printf '%s
' "budget key file $COPILOT_KEY_FILE (run install-key copilot FILE --apply)"
  [ "$(copilot_env_value GOOGLE_APPLICATION_CREDENTIALS)" = "$COPILOT_KEY_FILE" ] || printf '%s
' "GOOGLE_APPLICATION_CREDENTIALS (must be exactly $COPILOT_KEY_FILE)"
  [ "$(copilot_env_value ALLOWED_ORIGINS)" = "https://$PRIMARY_DASHBOARD_HOST" ] || printf '%s
' "ALLOWED_ORIGINS (must be exactly https://$PRIMARY_DASHBOARD_HOST)"
  [ "$(copilot_env_value COPILOT_MODEL_ENABLED)" = 0 ] || printf '%s
' "COPILOT_MODEL_ENABLED (must be 0: this droplet has no local model)"
  [ -f "$BASE/platform/tools/voice/dashboard_llm/server/app.py" ] || printf '%s
' "Scout files (the release has none: build a new package, then run deploy --apply)"
}

copilot_route_report() {
  local body
  body=$(curl -ksS --max-time 5 --resolve "$PRIMARY_DASHBOARD_HOST:443:127.0.0.1" "https://$PRIMARY_DASHBOARD_HOST/health" 2>/dev/null || true)
  if grep -q '"ready"' <<<"$body"; then
    say "OK    https://$PRIMARY_DASHBOARD_HOST/health reaches Scout"
  else
    say "note   https://$PRIMARY_DASHBOARD_HOST/health does not reach Scout yet. Run:  scoot-deploy dashboard --default-workspace CODE --apply"
  fi
}

create_copilot_env() {
  local tmp
  if [ -f "$COPILOT_ENV_FILE" ]; then
    say "keep   $COPILOT_ENV_FILE (exists, not changed)"
    return 0
  fi
  if [ "$APPLY" != 1 ]; then
    say "DRY  create $COPILOT_ENV_FILE from copilot.env.tpl (mode 0600; GEMINI_API_KEY stays empty for you to fill)"
    return 0
  fi
  tmp=$(umask 077; mktemp "$ETC/.copilot.env.XXXXXX")
  sed -e "s|@@DASHBOARD_HOST@@|$PRIMARY_DASHBOARD_HOST|g" "$HERE/copilot.env.tpl" > "$tmp"
  chmod 600 "$tmp"
  chown root:root "$tmp"
  mv -f "$tmp" "$COPILOT_ENV_FILE"
  say "made   $COPILOT_ENV_FILE (fill GEMINI_API_KEY and set COPILOT_MODEL_ENABLED=0; see the guide)"
}

do_copilot_install() {
  need_root
  step "Checks"
  check_resources
  [ -f "$HERE/scoot-copilot.service" ] && [ -f "$HERE/copilot.env.tpl" ] || die "This package has no Scout files. Build a new package."
  if [ "$APPLY" = 1 ]; then
    [ -f "$BASE/platform/tools/voice/dashboard_llm/server/app.py" ] || die "The installed release has no Scout files. Run deploy --apply with a new package first."
  fi
  step "Service user"
  id "$COPILOT_USER" >/dev/null 2>&1 || act useradd --system --home-dir /nonexistent --no-create-home --shell /usr/sbin/nologin "$COPILOT_USER"
  step "Settings file"
  create_copilot_env
  step "Service unit"
  act install -m 0644 "$HERE/scoot-copilot.service" "/etc/systemd/system/$COPILOT_UNIT.service"
  act systemctl daemon-reload
  act systemctl enable "$COPILOT_UNIT"
  say ""
  say "Next: fill the settings in $COPILOT_ENV_FILE, then:  scoot-deploy copilot-start --apply"
  say "Then:  scoot-deploy dashboard --default-workspace CODE --apply  adds the paths /health and /v1/interpret to nginx for $PRIMARY_DASHBOARD_HOST."
}

do_copilot_start() {
  local missing attempt
  need_root
  [ -L "$BASE/platform" ] || die "No release is installed. Run deploy --apply first."
  if [ "$APPLY" != 1 ] && [ ! -f "$COPILOT_ENV_FILE" ]; then
    say "DRY  check the settings, restart $COPILOT_UNIT, curl -fsS $COPILOT_HEALTH_URL"
    return 0
  fi
  [ -f "$COPILOT_ENV_FILE" ] || die "$COPILOT_ENV_FILE does not exist. Run copilot-install --apply first."
  missing=$(copilot_missing_settings)
  if [ -n "$missing" ]; then
    say ""
    say "Scout was NOT started. These settings in $COPILOT_ENV_FILE are empty or wrong:"
    sed 's/^/  /' <<<"$missing"
    say "Fill them in $COPILOT_ENV_FILE, then run:  $BASE/bin/scoot-deploy copilot-start --apply"
    return 0
  fi
  act systemctl restart "$COPILOT_UNIT"
  if [ "$APPLY" != 1 ]; then
    say "DRY  curl -fsS $COPILOT_HEALTH_URL"
    return 0
  fi
  for attempt in $(seq 1 20); do
    if curl -fsS --max-time 3 "$COPILOT_HEALTH_URL" >/dev/null 2>&1; then
      say "OK    $COPILOT_UNIT answers on $COPILOT_HEALTH_URL"
      copilot_route_report
      return 0
    fi
    sleep 1
  done
  say "FAIL  $COPILOT_UNIT did not answer on $COPILOT_HEALTH_URL within 20 seconds." >&2
  say "Read the log:  journalctl -u $COPILOT_UNIT -n 80 --no-pager" >&2
  exit 1
}

forecast_target() {
  case "$1" in
    dev) FORECAST_UNIT=scoot-forecast; FORECAST_PROJECT_ID=cos40005 ;;
    hardware) FORECAST_UNIT=scoot-forecast-hardware; FORECAST_PROJECT_ID=hardware-client-sales ;;
    *) die "Give --company dev (cos40005) or --company hardware (hardware-client-sales)." ;;
  esac
  FORECAST_KEY_FILE=$ETC/company-keys/$FORECAST_PROJECT_ID.json
}

do_forecast_install() {
  local requirements=$BASE/platform/forecasting/requirements-job.txt company
  need_root
  step "Checks"
  check_resources
  for company in "${FORECAST_COMPANIES[@]}"; do
    forecast_target "$company"
    [ -f "$HERE/$FORECAST_UNIT.service" ] && [ -f "$HERE/$FORECAST_UNIT.timer" ] || die "This package has no $FORECAST_UNIT units. Build a new package."
  done
  PY=$(command -v python3.12) || die "Python 3.12 is missing. The forecast packages need it. Install python3.12, then run this script again."
  if [ "$APPLY" = 1 ]; then
    [ -f "$requirements" ] || die "The installed release has no forecasting files. Run deploy --apply with a new package first."
  fi
  step "Forecast packages (shared, not rebuilt per release)"
  if [ -x "$FORECAST_VENV/bin/python" ]; then
    say "keep   $FORECAST_VENV (exists)"
  else
    act "$PY" -m venv "$FORECAST_VENV"
  fi
  act "$FORECAST_VENV/bin/pip" install --quiet --disable-pip-version-check --no-cache-dir -r "$requirements"
  step "Units (timers are not switched on or off)"
  for company in "${FORECAST_COMPANIES[@]}"; do
    forecast_target "$company"
    act install -m 0644 "$HERE/$FORECAST_UNIT.service" "/etc/systemd/system/$FORECAST_UNIT.service"
    act install -m 0644 "$HERE/$FORECAST_UNIT.timer" "/etc/systemd/system/$FORECAST_UNIT.timer"
  done
  act systemctl daemon-reload
  say ""
  for company in "${FORECAST_COMPANIES[@]}"; do
    forecast_target "$company"
    say "$FORECAST_PROJECT_ID: scoot-deploy forecast-run --company $company   (dry run, writes nothing)"
    say "  then: scoot-deploy forecast-run --company $company --apply   (one real write)"
    say "  then: systemctl enable --now $FORECAST_UNIT.timer"
  done
}

do_forecast_run() {
  local mode=()
  forecast_target "$FORECAST_COMPANY"
  [ "$(id -u)" = 0 ] || die "Run this action as root. It runs the forecast as the scoot user."
  [ -x "$FORECAST_VENV/bin/python" ] || die "$FORECAST_VENV does not exist. Run forecast-install --apply first."
  [ -f "$FORECAST_KEY_FILE" ] || die "$FORECAST_KEY_FILE does not exist. Install the company key first."
  if [ "$APPLY" = 1 ]; then
    mode=(--apply --confirm "APPLY-$FORECAST_PROJECT_ID")
    say "RUN  forecast for $FORECAST_PROJECT_ID, writing demand_forecasts, forecast_training_runs, retailer_priority_rankings, visit_briefs, ai_insights and the other AI collections"
  else
    say "RUN  forecast for $FORECAST_PROJECT_ID as a dry run (reads Firestore, writes nothing)"
  fi
  cd "$BASE/platform"
  local module status=0
  for module in forecasting.service.push_forecasts forecasting.ai_service.cli; do
    say "STEP $module"
    runuser -u scoot -- env -i PATH=/usr/bin:/bin HOME=/opt/scoot PYTHONDONTWRITEBYTECODE=1 "GOOGLE_APPLICATION_CREDENTIALS=$FORECAST_KEY_FILE" "$FORECAST_VENV/bin/python" -m "$module" --project "$FORECAST_COMPANY" "${mode[@]}" || status=1
  done
  return "$status"
}

main() {
  parse "$@"
  case "$ACTION" in
    deploy) do_deploy ;;
    start) do_start ;;
    headers) do_headers ;;
    scheduler-install) do_scheduler_install ;;
    copilot-install) do_copilot_install ;;
    copilot-start) do_copilot_start ;;
    forecast-install) do_forecast_install ;;
    forecast-run) do_forecast_run ;;
    rollback) do_rollback ;;
    install-key) do_install_key ;;
    signing-key) do_signing_key ;;
    public-key) do_public_key ;;
    create-owner) do_create_owner ;;
    brevo) do_brevo ;;
    certificate) do_certificate ;;
    dashboard) do_dashboard ;;
    dashboard-revert) do_dashboard_revert ;;
    promo) do_promo ;;
    status) do_status ;;
  esac
  if [ "$APPLY" != 1 ] && [ "$ACTION" != brevo ] && [ "$ACTION" != status ] && [ "$ACTION" != forecast-run ]; then
    say ""
    say "This was a dry run. Nothing was changed. Add --apply to do the work."
  fi
}

main "$@"
