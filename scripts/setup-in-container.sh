#!/usr/bin/env bash
#
# Läuft IM LXC (vom Host-Installer per `pct exec` gestartet).
# Baut Tolaria Web, richtet Git-Vault, systemd und nginx ein.
#
set -euo pipefail
set +x
umask 077

APP="tolaria"
BUILD_LOG="/root/tolaria-build.log"
PKG_DIR="/root/tolaria-packaging"
INSTALL_ENV="${PKG_DIR}/install.env"

# ---------------------------------------------------------------------------
# Logging / Fehlerkette
# ---------------------------------------------------------------------------
msg_info()  { echo "[INFO]  $*"; }
msg_ok()    { echo "[OK]    $*"; }
msg_warn()  { echo "[WARN]  $*"; }
msg_error() { echo "[ERROR] $*" >&2; }

on_error() {
  local exit_code="$1" lineno="$2" cmd="$3"
  set +e
  set +x
  if [[ -n "${TOLARIA_TOKEN:-}" ]]; then cmd="${cmd//"$TOLARIA_TOKEN"/<redacted>}"; fi
  if [[ -n "${AUTH_PASS:-}" ]]; then cmd="${cmd//"$AUTH_PASS"/<redacted>}"; fi
  if ((${#cmd} > 2000)); then
    cmd="${cmd:0:2000}... [gekürzt]"
  fi
  echo ""
  msg_error "════════════ SETUP IM CONTAINER FEHLGESCHLAGEN ════════════"
  msg_error "Befehl    : $cmd"
  msg_error "Zeile     : $lineno"
  msg_error "Exit-Code : $exit_code"
  msg_error "Build-Log : $BUILD_LOG"
  echo ""
  msg_error "--- Stacktrace ---"
  local i=0
  while caller "$i"; do ((i++)) || true; done
  echo ""
  msg_error "--- systemctl status ${APP} ---"
  systemctl status "${APP}" --no-pager --full 2>&1 || true
  echo ""
  msg_error "--- journalctl -u ${APP} (letzte 200 Zeilen) ---"
  journalctl -u "${APP}" --no-pager -n 200 2>&1 || true
  echo ""
  msg_error "--- nginx -t ---"
  nginx -t 2>&1 || true
  echo ""
  msg_error "--- nginx error.log (letzte 100 Zeilen) ---"
  tail -n 100 /var/log/nginx/error.log 2>&1 || true
  echo ""
  msg_error "--- Speicher / Disk ---"
  free -m 2>&1 || true
  df -h / /opt /var 2>&1 || true
  echo ""
  msg_error "--- Build-Artefakte ---"
  ls -la /opt/tolaria/src/apps/web/dist 2>&1 | head -40 || true
  ls -la /opt/tolaria/src/node_modules/.tmp/tolaria-server 2>&1 | head -20 || true
  echo ""
  msg_error "Bitte diese Ausgabe UND ${BUILD_LOG} mitschicken."
  exit "$exit_code"
}

exec > >(tee -i "$BUILD_LOG") 2>&1
chmod 600 "$BUILD_LOG" 2>/dev/null || true
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

# ---------------------------------------------------------------------------
# Installationsvariablen
# ---------------------------------------------------------------------------
if [[ ! -f "$INSTALL_ENV" ]]; then
  msg_error "Installationsvariablen fehlen: $INSTALL_ENV"
  exit 1
fi
set -a
# shellcheck disable=SC1090
source "$INSTALL_ENV"
set +a

: "${APP:?APP fehlt}"
: "${PORT:?PORT fehlt}"
: "${SERVER_PORT:?SERVER_PORT fehlt}"
: "${UPSTREAM_REPO:?UPSTREAM_REPO fehlt}"
: "${UPSTREAM_REF:?UPSTREAM_REF fehlt}"
: "${TOLARIA_TOKEN:?TOLARIA_TOKEN fehlt}"
: "${AUTH_USER:?AUTH_USER fehlt}"
: "${AUTH_PASS:?AUTH_PASS fehlt}"

[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT > 0 && PORT < 65536 )) || { msg_error "PORT ungültig"; exit 1; }
[[ "$SERVER_PORT" =~ ^[0-9]+$ ]] && (( SERVER_PORT > 0 && SERVER_PORT < 65536 )) || { msg_error "SERVER_PORT ungültig"; exit 1; }
[[ ${#TOLARIA_TOKEN} -ge 16 ]] || { msg_error "TOLARIA_TOKEN ist kürzer als 16 Zeichen"; exit 1; }
[[ "$TOLARIA_TOKEN" =~ ^[A-Za-z0-9._~+/=-]+$ ]] || { msg_error "TOLARIA_TOKEN enthält nicht unterstützte Zeichen"; exit 1; }
[[ "$AUTH_USER" =~ ^[A-Za-z0-9._-]+$ ]] || { msg_error "AUTH_USER ungültig"; exit 1; }
[[ -n "$AUTH_PASS" ]] || { msg_error "AUTH_PASS ist leer"; exit 1; }
[[ "$AUTH_PASS" =~ ^[A-Za-z0-9._~@%+=:,/-]+$ ]] || { msg_error "AUTH_PASS enthält nicht unterstützte Zeichen"; exit 1; }
[[ "$UPSTREAM_REF" =~ ^[A-Za-z0-9._/][A-Za-z0-9._/-]*$ ]] || { msg_error "UPSTREAM_REF ungültig"; exit 1; }

msg_info "Setup für ${APP} (Web-Port ${PORT}, Server 127.0.0.1:${SERVER_PORT})"
msg_info "Build-Log: ${BUILD_LOG}"

# ---------------------------------------------------------------------------
# Pakete
# ---------------------------------------------------------------------------
msg_info "Aktualisiere Paketlisten und installiere Systempakete ..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg git build-essential python3 \
  nginx apache2-utils openssl procps iproute2
msg_ok "Systempakete installiert."

# ---------------------------------------------------------------------------
# Node 22.14+ und pnpm 10.33.0
# ---------------------------------------------------------------------------
need_node=0
if ! command -v node >/dev/null 2>&1; then
  need_node=1
else
  node_major="$(node -p 'process.versions.node.split(".")[0]')"
  node_minor="$(node -p 'process.versions.node.split(".")[1]')"
  if (( node_major < 22 || (node_major == 22 && node_minor < 14) )); then
    need_node=1
  fi
fi

if [[ "$need_node" == "1" ]]; then
  msg_info "Installiere Node.js 22.x von NodeSource ..."
  curl -fsSL https://deb.nodesource.com/setup_22.x -o /tmp/nodesource_setup.sh
  bash /tmp/nodesource_setup.sh
  apt-get install -y nodejs
else
  msg_ok "Node.js $(node --version) bereits vorhanden."
fi

node_major="$(node -p 'process.versions.node.split(".")[0]')"
node_minor="$(node -p 'process.versions.node.split(".")[1]')"
if (( node_major < 22 || (node_major == 22 && node_minor < 14) )); then
  msg_error "Node.js $(node --version) ist zu alt. Tolaria braucht >= 22.14."
  exit 1
fi
msg_ok "Node.js $(node --version)"

# Bewusst npm statt corepack: der corepack-Shim würde als tolaria erneut
# herunterladen und kann in nicht-interaktiven Läufen auf einen Prompt warten.
if ! command -v npm >/dev/null 2>&1; then
  msg_error "npm fehlt (Node.js-Installation unvollständig)."
  exit 1
fi
msg_info "Installiere pnpm 10.33.0 global ..."
npm install -g --no-fund --no-audit pnpm@10.33.0
pnpm_version="$(pnpm --version)"
[[ "$pnpm_version" == "10.33.0" ]] || { msg_error "pnpm-Version ist ${pnpm_version}, erwartet 10.33.0"; exit 1; }
msg_ok "pnpm ${pnpm_version}"

# ---------------------------------------------------------------------------
# Benutzer und Verzeichnisse
# ---------------------------------------------------------------------------
if ! id -u "$APP" >/dev/null 2>&1; then
  msg_info "Lege Systembenutzer ${APP} an ..."
  useradd --create-home --shell /bin/bash --user-group "$APP"
fi
install -d -m 755 -o "$APP" -g "$APP" /opt/tolaria
install -d -m 750 -o "$APP" -g "$APP" /var/lib/tolaria
install -d -m 750 -o "$APP" -g "$APP" /var/lib/tolaria/data
install -d -m 750 -o root -g www-data /etc/tolaria
msg_ok "Benutzer ${APP} und Verzeichnisse vorbereitet."

# ---------------------------------------------------------------------------
# Upstream-Quellcode (idempotent aktualisieren)
# ---------------------------------------------------------------------------
if [[ -d /opt/tolaria/src/.git ]]; then
  msg_info "Aktualisiere Tolaria-Quellcode auf ${UPSTREAM_REF} ..."
  git -C /opt/tolaria/src remote set-url origin "$UPSTREAM_REPO"
  git -C /opt/tolaria/src fetch --depth 1 origin "$UPSTREAM_REF"
  git -C /opt/tolaria/src reset --hard FETCH_HEAD
  git -C /opt/tolaria/src clean -fdx -e node_modules >/dev/null 2>&1 || true
else
  msg_info "Klone Tolaria (${UPSTREAM_REF}) ..."
  rm -rf /opt/tolaria/src
  if ! git clone --depth 1 --branch "$UPSTREAM_REF" "$UPSTREAM_REPO" /opt/tolaria/src 2>/dev/null; then
    msg_warn "Direkter Branch/Tag-Clone fehlgeschlagen - versuche Commit/Ref über fetch."
    rm -rf /opt/tolaria/src
    git clone --depth 1 "$UPSTREAM_REPO" /opt/tolaria/src
    git -C /opt/tolaria/src fetch --depth 1 origin "$UPSTREAM_REF"
    git -C /opt/tolaria/src checkout -f FETCH_HEAD
  fi
fi
git config --global --add safe.directory /opt/tolaria/src >/dev/null 2>&1 || true
chown -R "$APP:$APP" /opt/tolaria/src
msg_ok "Quellcode: $(git -C /opt/tolaria/src rev-parse --short HEAD) (${UPSTREAM_REF})"

# ---------------------------------------------------------------------------
# Git-Vault seeden (nie überschreiben)
# ---------------------------------------------------------------------------
msg_info "Prüfe/seede Git-Vault /var/lib/tolaria/vault.git ..."
VAULT_OWNER="$APP" VAULT_GROUP="$APP" \
  bash "${PKG_DIR}/seed-vault.sh" /var/lib/tolaria/vault.git /opt/tolaria/src/demo-vault-v2
msg_ok "Git-Vault bereit."

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
msg_info "Installiere pnpm-Abhängigkeiten (kann einige Minuten dauern) ..."
runuser -u "$APP" -- env \
  HOME="/home/$APP" \
  HUSKY=0 \
  CI=1 \
  NODE_OPTIONS="--max-old-space-size=4096" \
  bash -lc 'cd /opt/tolaria/src && pnpm install --frozen-lockfile'

msg_info "Baue Tolaria Web (tsc + vite) ..."
runuser -u "$APP" -- env \
  HOME="/home/$APP" \
  CI=1 \
  NODE_OPTIONS="--max-old-space-size=4096" \
  bash -lc 'cd /opt/tolaria/src && pnpm build:web'

DIST_DIR="/opt/tolaria/src/apps/web/dist"
[[ -s "$DIST_DIR/index.html" ]] || { msg_error "Build unvollständig: ${DIST_DIR}/index.html fehlt."; exit 1; }
msg_ok "Web-Build erzeugt: ${DIST_DIR}"

# nginx (www-data) muss den Build lesen können; umask 077 hat restriktive Rechte erzeugt.
chmod 755 /opt/tolaria /opt/tolaria/src /opt/tolaria/src/apps /opt/tolaria/src/apps/web "$DIST_DIR"
chmod -R a+rX "$DIST_DIR"

# Laufzeit-Bundle-Verzeichnis für run.ts (schreibt beim Start dorthin)
install -d -m 750 -o "$APP" -g "$APP" /opt/tolaria/src/node_modules/.tmp
install -d -m 750 -o "$APP" -g "$APP" /opt/tolaria/src/node_modules/.tmp/tolaria-server

# ---------------------------------------------------------------------------
# Web-Konfiguration in die gebauten HTML-Dateien injizieren
# ---------------------------------------------------------------------------
msg_info "Injiziere /tolaria-config.js in die Web-Builds ..."
python3 "${PKG_DIR}/inject-web-config.py" "$DIST_DIR"
msg_ok "Web-Konfiguration injiziert."

# ---------------------------------------------------------------------------
# Server-Umgebung, Config-JS, systemd
# ---------------------------------------------------------------------------
msg_info "Schreibe Server-Umgebung und Web-Konfiguration ..."
{
  printf 'TOLARIA_SERVER_TOKEN=%s\n' "$TOLARIA_TOKEN"
  printf 'TOLARIA_SERVER_HOST=127.0.0.1\n'
  printf 'TOLARIA_SERVER_PORT=%s\n' "$SERVER_PORT"
  printf 'TOLARIA_VAULT_REMOTE_URL=/var/lib/tolaria/vault.git\n'
  printf 'TOLARIA_SERVER_DATA_DIR=/var/lib/tolaria/data\n'
  printf 'TOLARIA_VAULT_FETCH_INTERVAL_MS=0\n'
  printf 'NODE_ENV=production\n'
} > /etc/tolaria/tolaria.env
chown root:root /etc/tolaria/tolaria.env
chmod 600 /etc/tolaria/tolaria.env

# Das echte Bearer-Token steht im Browser-Bundle. Die Datei ist nur über
# nginx + Basic Auth erreichbar (siehe nginx/tolaria.conf).
python3 - "$TOLARIA_TOKEN" > /etc/tolaria/tolaria-config.js <<'PY'
import json
import sys

token = sys.argv[1]
print("window.TOLARIA_REMOTE_URL = window.location.origin;")
print("window.TOLARIA_REMOTE_TOKEN = " + json.dumps(token) + ";")
PY
chown root:www-data /etc/tolaria/tolaria-config.js
chmod 640 /etc/tolaria/tolaria-config.js

install -m 644 -o root -g root "${PKG_DIR}/tolaria.service" /etc/systemd/system/tolaria.service
systemctl daemon-reload
systemctl enable tolaria >/dev/null 2>&1
msg_ok "systemd-Unit installiert und aktiviert."

# ---------------------------------------------------------------------------
# nginx + Basic Auth
# ---------------------------------------------------------------------------
msg_info "Richte nginx und Basic Auth ein ..."
if [[ ! -f /etc/nginx/.htpasswd-tolaria ]]; then
  htpasswd -bc /etc/nginx/.htpasswd-tolaria "$AUTH_USER" "$AUTH_PASS"
else
  htpasswd -b /etc/nginx/.htpasswd-tolaria "$AUTH_USER" "$AUTH_PASS" \
    || htpasswd -bc /etc/nginx/.htpasswd-tolaria "$AUTH_USER" "$AUTH_PASS"
fi
chown root:www-data /etc/nginx/.htpasswd-tolaria
chmod 640 /etc/nginx/.htpasswd-tolaria

sed -e "s|__PORT__|${PORT}|g" \
    -e "s|__SERVER_PORT__|${SERVER_PORT}|g" \
    "${PKG_DIR}/tolaria.conf" > /etc/nginx/sites-available/tolaria.conf
chmod 644 /etc/nginx/sites-available/tolaria.conf
ln -sfn /etc/nginx/sites-available/tolaria.conf /etc/nginx/sites-enabled/tolaria.conf
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl enable nginx >/dev/null 2>&1
systemctl restart nginx
msg_ok "nginx konfiguriert (Port ${PORT})."

# ---------------------------------------------------------------------------
# Zugangsdaten für den Betreiber
# ---------------------------------------------------------------------------
CONTAINER_IP="$(ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
[[ -n "$CONTAINER_IP" ]] || CONTAINER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[[ -n "$CONTAINER_IP" ]] || CONTAINER_IP="<LXC-IP>"
{
  printf 'URL=http://%s:%s\n' "$CONTAINER_IP" "$PORT"
  printf 'USER=%s\n' "$AUTH_USER"
  printf 'PASSWORD=%s\n' "$AUTH_PASS"
  printf 'SERVER_TOKEN_FILE=/etc/tolaria/tolaria.env\n'
  printf 'NOTE=Basic Auth schützt UI und /tolaria-config.js. /v1/ nutzt das Bearer-Token aus /etc/tolaria/tolaria.env.\n'
} > /root/tolaria-credentials.txt
chmod 600 /root/tolaria-credentials.txt

# ---------------------------------------------------------------------------
# Start und Verifikation
# ---------------------------------------------------------------------------
msg_info "Starte ${APP} ..."
systemctl restart tolaria

server_ok=0
for i in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:${SERVER_PORT}/healthz" >/dev/null 2>&1; then
    server_ok=1
    break
  fi
  sleep 2
done
if [[ "$server_ok" != "1" ]]; then
  msg_error "Tolaria-Server antwortet nach 120 s nicht auf /healthz."
  exit 1
fi
msg_ok "Tolaria-Server: /healthz OK"

curl -fsS -H "Authorization: Bearer ${TOLARIA_TOKEN}" \
  "http://127.0.0.1:${SERVER_PORT}/v1/vault" >/dev/null
msg_ok "Tolaria-Server: /v1/vault mit Bearer-Token OK"

curl -fsS -u "${AUTH_USER}:${AUTH_PASS}" "http://127.0.0.1:${PORT}/" >/dev/null
msg_ok "nginx: Web-UI mit Basic Auth OK"

curl -fsS -u "${AUTH_USER}:${AUTH_PASS}" "http://127.0.0.1:${PORT}/tolaria-config.js" >/dev/null
msg_ok "nginx: /tolaria-config.js mit Basic Auth OK"

curl -fsS -H "Authorization: Bearer ${TOLARIA_TOKEN}" \
  "http://127.0.0.1:${PORT}/v1/vault" >/dev/null
msg_ok "nginx: /v1/vault Proxy mit Bearer-Token OK"

curl -fsS "http://127.0.0.1:${PORT}/healthz" >/dev/null
msg_ok "nginx: /healthz öffentlich OK"

echo ""
msg_ok "Setup abgeschlossen."
msg_info "Zugangsdaten: /root/tolaria-credentials.txt"
msg_info "Update: Host-Einzeiler erneut ausführen (Vault bleibt erhalten)."
