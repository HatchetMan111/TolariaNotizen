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
  msg_error "--- DNS / Netzwerk ---"
  cat /etc/resolv.conf 2>&1 || true
  getent ahostsv4 deb.debian.org 2>&1 || echo "IPv4-Auflösung fehlgeschlagen"
  getent ahostsv6 deb.debian.org 2>&1 || echo "IPv6-Auflösung fehlgeschlagen"
  ip -4 route 2>&1 || true
  ip -4 addr show dev eth0 2>&1 || true
  if [[ -f /etc/dhcp/dhclient.conf ]]; then
    grep -n 'tolaria-dns\|domain-name-servers' /etc/dhcp/dhclient.conf 2>&1 || true
  fi
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
CTID="${CTID:-<CTID>}"
TOLARIA_DNS_SERVERS="${TOLARIA_DNS_SERVERS:-1.1.1.1 9.9.9.9}"
FORCE_BUILD="${FORCE_BUILD:-0}"

[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT > 0 && PORT < 65536 )) || { msg_error "PORT ungültig"; exit 1; }
[[ "$SERVER_PORT" =~ ^[0-9]+$ ]] && (( SERVER_PORT > 0 && SERVER_PORT < 65536 )) || { msg_error "SERVER_PORT ungültig"; exit 1; }
[[ ${#TOLARIA_TOKEN} -ge 16 ]] || { msg_error "TOLARIA_TOKEN ist kürzer als 16 Zeichen"; exit 1; }
[[ "$TOLARIA_TOKEN" =~ ^[A-Za-z0-9._~+/=-]+$ ]] || { msg_error "TOLARIA_TOKEN enthält nicht unterstützte Zeichen"; exit 1; }
[[ "$AUTH_USER" =~ ^[A-Za-z0-9._-]+$ ]] || { msg_error "AUTH_USER ungültig"; exit 1; }
[[ -n "$AUTH_PASS" ]] || { msg_error "AUTH_PASS ist leer"; exit 1; }
[[ "$AUTH_PASS" =~ ^[A-Za-z0-9._~@%+=:,/-]+$ ]] || { msg_error "AUTH_PASS enthält nicht unterstützte Zeichen"; exit 1; }
[[ "$UPSTREAM_REF" =~ ^[A-Za-z0-9._/][A-Za-z0-9._/-]*$ ]] || { msg_error "UPSTREAM_REF ungültig"; exit 1; }

APT_PACKAGES=(
  ca-certificates curl gnupg git build-essential python3
  nginx apache2-utils openssl procps iproute2
)
APT_OPTS=(-o Acquire::Retries=5 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30)
APT_LOG="/root/tolaria-apt-update.log"

# In einem Container ohne globales IPv6 wartet apt sonst lange auf AAAA-
# Verbindungen. deb.debian.org ist dual-stack; IPv4 reicht hier.
if command -v ip >/dev/null 2>&1 && ! ip -6 addr show scope global 2>/dev/null | grep -q 'inet6 '; then
  APT_OPTS+=(-o Acquire::ForceIPv4=true)
fi

retry() {
  local attempts="$1" delay="$2"; shift 2
  local i
  for ((i = 1; i <= attempts; i++)); do
    if "$@"; then
      return 0
    fi
    if (( i < attempts )); then
      msg_warn "Versuch ${i}/${attempts} fehlgeschlagen - neuer Versuch in ${delay}s ..."
      sleep "$delay"
    fi
  done
  return 1
}

msg_info "Setup für ${APP} (Web-Port ${PORT}, Server 127.0.0.1:${SERVER_PORT})"
msg_info "Build-Log: ${BUILD_LOG}"

# ---------------------------------------------------------------------------
# DNS prüfen und gegen DHCP-Überschreiben absichern
# ---------------------------------------------------------------------------
REPAIR_DNS="${PKG_DIR}/repair-dns.sh"

dns_guard() {
  if [[ -f "$REPAIR_DNS" ]]; then
    bash "$REPAIR_DNS" --servers "$TOLARIA_DNS_SERVERS" --persist-dhclient
  else
    getent ahostsv4 deb.debian.org >/dev/null 2>&1
  fi
}

msg_info "Prüfe DNS-Auflösung (IPv4/A-Records, apt) ..."
if ! dns_guard; then
  msg_error "DNS-Auflösung funktioniert nicht - apt-get würde mit"
  msg_error "\"Temporary failure resolving ...\" scheitern."
  msg_error "Prüfe besonders die IPv4-Auflösung:"
  msg_error "  getent ahostsv4 deb.debian.org"
  msg_error "  cat /etc/resolv.conf"
  msg_error "Wichtig: apt braucht IPv4/A-Records - reine AAAA-Antworten genügen nicht."
  msg_error "Auf dem Proxmox-Host:"
  msg_error "  pct set ${CTID} --nameserver \"${TOLARIA_DNS_SERVERS}\""
  msg_error "  pct reboot ${CTID}"
  msg_error "Funktionierenden Resolver ggf. erzwingen: --dns \"<IP>\""
  msg_error "Danach den Installer erneut ausführen."
  exit 1
fi

# repair-dns.sh kann auf den öffentlichen Fallback ausgewichen sein. Die
# tatsächlich aktiven Nameserver werden deshalb aus /etc/resolv.conf gelesen
# und für dhclient festgeschrieben (--persist-dhclient im Aufruf oben).
EFFECTIVE_DNS="$(awk '/^nameserver[[:space:]]/ {printf "%s ", $2}' /etc/resolv.conf 2>/dev/null \
  | sed 's/[[:space:]]*$//')"
if [[ -z "$EFFECTIVE_DNS" ]]; then
  EFFECTIVE_DNS="$TOLARIA_DNS_SERVERS"
fi
TOLARIA_DNS_SERVERS="$EFFECTIVE_DNS"

# ---------------------------------------------------------------------------
# apt-Hosts vorab auflösen
# ---------------------------------------------------------------------------
# In manchen LXC-Netzen antwortet der Resolver bei einzelnen Anfragen sauber,
# scheitert aber unter der Last vieler paralleler apt-Downloads (NAT/Conntrack,
# Rate-Limits). "Temporary failure resolving" trotz funktionierendem getent
# ist dann die Folge. Die apt-Hosts werden deshalb für die Dauer der
# Paketinstallation in /etc/hosts gepinnt und danach wieder entfernt.
APT_HOSTS_PIN="${PKG_DIR}/apt-hosts-pin.sh"
APT_HOSTS_PINNED=0

pin_apt_hosts() {
  APT_HOSTS_PINNED=0
  [[ -f "$APT_HOSTS_PIN" ]] || return 0
  if bash "$APT_HOSTS_PIN" pin; then
    APT_HOSTS_PINNED=1
  else
    msg_warn "Host-Pinning fehlgeschlagen - apt nutzt DNS."
  fi
}

unpin_apt_hosts() {
  APT_HOSTS_PINNED=0
  [[ -f "$APT_HOSTS_PIN" ]] || return 0
  bash "$APT_HOSTS_PIN" unpin >/dev/null 2>&1 || true
}
trap 'unpin_apt_hosts' EXIT

# ---------------------------------------------------------------------------
# Pakete
# ---------------------------------------------------------------------------
msg_info "Aktualisiere Paketlisten und installiere Systempakete ..."
export DEBIAN_FRONTEND=noninteractive

pin_apt_hosts

# apt-get update kann mit Exit 0 enden, obwohl ALLE Indexe nicht geladen
# wurden ("W: Failed to fetch ... Some index files failed to download").
# Deshalb wird die Ausgabe geprüft und der Fall explizit behandelt.
apt_update_once() {
  apt-get update "${APT_OPTS[@]}" >"$APT_LOG" 2>&1
}

apt_log_has_fetch_errors() {
  [[ -s "$APT_LOG" ]] && grep -qE 'Failed to fetch|Temporary failure resolving|Could not resolve' "$APT_LOG"
}

update_ok=0
if retry 3 5 apt_update_once; then
  update_ok=1
fi
if (( update_ok == 0 )) && (( APT_HOSTS_PINNED )); then
  msg_warn "apt-get update mit vorab aufgelösten Hosts fehlgeschlagen - versuche ohne Pin ..."
  unpin_apt_hosts
  if retry 2 5 apt_update_once; then
    update_ok=1
  fi
fi

if (( update_ok == 0 )); then
  cat "$APT_LOG" 2>/dev/null || true
  msg_error "apt-get update ist fehlgeschlagen (DNS, Proxy oder Mirror-Problem)."
  msg_error "Nameserver: ${TOLARIA_DNS_SERVERS}"
  msg_error "IPv4/A: $(getent ahostsv4 deb.debian.org 2>&1 | awk 'NR<=2 {print $1}' | paste -sd' ' - || true)"
  msg_error "IPv6/AAAA: $(getent ahostsv6 deb.debian.org 2>&1 | awk 'NR<=2 {print $1}' | paste -sd' ' - || true)"
  cat /etc/resolv.conf 2>/dev/null || true
  exit 1
fi

if apt_log_has_fetch_errors; then
  msg_warn "apt-get update meldet Fetch-Fehler - prüfe, ob die Pakete trotzdem auflösbar sind ..."
  if apt-get install -y --simulate --no-install-recommends "${APT_OPTS[@]}" "${APT_PACKAGES[@]}" >/dev/null 2>&1; then
    msg_warn "Paketauflösung funktioniert trotz Fetch-Warnungen - fahre fort."
  else
    cat "$APT_LOG"
    msg_error "Paketlisten unvollständig und Pakete nicht auflösbar."
    msg_error "Prüfe DNS/Proxy/Internet im Container und führe den Installer erneut aus."
    exit 1
  fi
fi

# Vor dem Download erneut prüfen: ein DHCP-Lease oder ein flakiger Resolver
# kann die Auflösung zwischen Update und Install wieder kaputt machen.
apt_install_packages() {
  apt-get install -y --no-install-recommends "${APT_OPTS[@]}" "${APT_PACKAGES[@]}"
}

if ! getent ahostsv4 deb.debian.org >/dev/null 2>&1; then
  msg_warn "IPv4-Auflösung vor dem Paketdownload gestört - repariere erneut ..."
  if ! dns_guard; then
    msg_error "DNS-Reparatur vor dem Paketdownload fehlgeschlagen."
    cat /etc/resolv.conf 2>/dev/null || true
    exit 1
  fi
fi

if ! retry 3 10 apt_install_packages; then
  msg_warn "Erster Installationsversuch fehlgeschlagen - aktualisiere Listen und versuche es mit --fix-missing erneut ..."
  if (( APT_HOSTS_PINNED )); then
    msg_warn "Entferne Host-Pinning und versuche die Auflösung wieder über DNS ..."
    unpin_apt_hosts
  fi
  retry 2 10 apt-get update "${APT_OPTS[@]}" >>"$APT_LOG" 2>&1 || msg_warn "apt-get update beim zweiten Versuch fehlgeschlagen."
  if ! apt-get install -y --no-install-recommends --fix-missing "${APT_OPTS[@]}" "${APT_PACKAGES[@]}"; then
    msg_error "Systempakete konnten nicht installiert werden."
    msg_error "Nameserver: ${TOLARIA_DNS_SERVERS}"
    msg_error "IPv4/A: $(getent ahostsv4 deb.debian.org 2>&1 | awk 'NR<=2 {print $1}' | paste -sd' ' - || true)"
    msg_error "IPv6/AAAA: $(getent ahostsv6 deb.debian.org 2>&1 | awk 'NR<=2 {print $1}' | paste -sd' ' - || true)"
    cat /etc/resolv.conf 2>/dev/null || true
    msg_error "Häufigste Ursache: DNS/Internet/Proxy im Container (siehe ${APT_LOG})."
    exit 1
  fi
fi
unpin_apt_hosts
msg_ok "Systempakete installiert."

# --fix-missing kann fehlende Pakete stillschweigend überspringen. Deshalb
# wird explizit geprüft, dass die später benötigten Werkzeuge da sind.
missing_cmds=()
for cmd in nginx git htpasswd curl openssl python3 gpg make; do
  command -v "$cmd" >/dev/null 2>&1 || missing_cmds+=("$cmd")
done
if (( ${#missing_cmds[@]} > 0 )); then
  msg_error "Nach der Paketinstallation fehlen: ${missing_cmds[*]}"
  msg_error "Erneut ausführen oder im Container manuell nachinstallieren."
  exit 1
fi

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
  pin_apt_hosts
  if ! retry 3 5 curl -fsSL --max-time 60 https://deb.nodesource.com/setup_22.x -o /tmp/nodesource_setup.sh; then
    msg_error "NodeSource-Setup konnte nicht geladen werden (https://deb.nodesource.com)."
    msg_error "Prüfe DNS/Internet/Proxy im Container."
    exit 1
  fi
  bash /tmp/nodesource_setup.sh
  rm -f /tmp/nodesource_setup.sh
  if ! retry 3 10 apt-get install -y "${APT_OPTS[@]}" nodejs; then
    msg_error "Node.js konnte nicht installiert werden."
    exit 1
  fi
  unpin_apt_hosts
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
if ! retry 3 10 npm install -g --no-fund --no-audit pnpm@10.33.0; then
  msg_error "pnpm konnte nicht über npm installiert werden (Registry erreichbar?)."
  exit 1
fi
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
DIST_DIR="/opt/tolaria/src/apps/web/dist"
NEED_BUILD=1

if [[ -d /opt/tolaria/src/.git ]]; then
  CURRENT_REV="$(git -C /opt/tolaria/src rev-parse HEAD 2>/dev/null || true)"
  msg_info "Aktualisiere Tolaria-Quellcode auf ${UPSTREAM_REF} ..."
  git -C /opt/tolaria/src remote set-url origin "$UPSTREAM_REPO"
  if ! git -C /opt/tolaria/src fetch --depth 1 origin "$UPSTREAM_REF"; then
    msg_error "git fetch ist fehlgeschlagen (GitHub erreichbar? DNS/Proxy?)."
    exit 1
  fi
  TARGET_REV="$(git -C /opt/tolaria/src rev-parse FETCH_HEAD)"

  if [[ "$FORCE_BUILD" != "1" && -n "$CURRENT_REV" && "$CURRENT_REV" == "$TARGET_REV" \
        && -s "$DIST_DIR/index.html" && -d /opt/tolaria/src/node_modules ]]; then
    NEED_BUILD=0
    msg_ok "Upstream unverändert ($(git -C /opt/tolaria/src rev-parse --short HEAD)) - Build wird übersprungen."
  else
    git -C /opt/tolaria/src reset --hard FETCH_HEAD
    git -C /opt/tolaria/src clean -fdx -e node_modules >/dev/null 2>&1 || true
  fi
else
  msg_info "Klone Tolaria (${UPSTREAM_REF}) ..."
  rm -rf /opt/tolaria/src
  if ! git clone --depth 1 --branch "$UPSTREAM_REF" "$UPSTREAM_REPO" /opt/tolaria/src 2>/dev/null; then
    msg_warn "Direkter Branch/Tag-Clone fehlgeschlagen - versuche Commit/Ref über fetch."
    rm -rf /opt/tolaria/src
    if ! git clone --depth 1 "$UPSTREAM_REPO" /opt/tolaria/src; then
      msg_error "git clone ist fehlgeschlagen (GitHub erreichbar? DNS/Proxy?)."
      exit 1
    fi
    git -C /opt/tolaria/src fetch --depth 1 origin "$UPSTREAM_REF"
    git -C /opt/tolaria/src checkout -f FETCH_HEAD
  fi
fi
git config --global --add safe.directory /opt/tolaria/src >/dev/null 2>&1 || true
if [[ "$NEED_BUILD" == "1" ]]; then
  # Nur bei Änderungen nötig; spart bei Updates ohne neuen Commit viel Zeit.
  chown -R "$APP:$APP" /opt/tolaria/src
fi
msg_ok "Quellcode: $(git -C /opt/tolaria/src rev-parse --short HEAD) (${UPSTREAM_REF})"

# ---------------------------------------------------------------------------
# Git-Vault seeden (nie überschreiben)
# ---------------------------------------------------------------------------
msg_info "Prüfe/seede Git-Vault /var/lib/tolaria/vault.git ..."
VAULT_OWNER="$APP" VAULT_GROUP="$APP" \
  bash "${PKG_DIR}/seed-vault.sh" /var/lib/tolaria/vault.git /opt/tolaria/src/demo-vault-v2
msg_ok "Git-Vault bereit."

# ---------------------------------------------------------------------------
# Build (nur bei neuem Commit, fehlendem Build oder --force-build)
# ---------------------------------------------------------------------------
if [[ "$NEED_BUILD" == "1" ]]; then
  free_mb="$(df -Pm /opt/tolaria 2>/dev/null | awk 'NR==2 {print $4}')"
  if [[ "$free_mb" =~ ^[0-9]+$ ]] && (( free_mb < 3072 )); then
    msg_error "Zu wenig freier Platz für den Build: ${free_mb} MB (benötigt: >= 3072 MB)."
    msg_error "Disk vergrößern (pct resize ${CTID} rootfs +4G) und Installer erneut ausführen."
    exit 1
  fi

  msg_info "Installiere pnpm-Abhängigkeiten (kann einige Minuten dauern) ..."
  if ! runuser -u "$APP" -- env \
    HOME="/home/$APP" \
    HUSKY=0 \
    CI=1 \
    NODE_OPTIONS="--max-old-space-size=4096" \
    bash -lc 'cd /opt/tolaria/src && pnpm install --frozen-lockfile'; then
    msg_error "pnpm install ist fehlgeschlagen (Registry/Netzwerk oder Lockfile)."
    exit 1
  fi

  msg_info "Baue Tolaria Web (tsc + vite) ..."
  if ! runuser -u "$APP" -- env \
    HOME="/home/$APP" \
    CI=1 \
    NODE_OPTIONS="--max-old-space-size=4096" \
    bash -lc 'cd /opt/tolaria/src && pnpm build:web'; then
    msg_error "pnpm build:web ist fehlgeschlagen (siehe ${BUILD_LOG})."
    exit 1
  fi

  [[ -s "$DIST_DIR/index.html" ]] || { msg_error "Build unvollständig: ${DIST_DIR}/index.html fehlt."; exit 1; }
  msg_ok "Web-Build erzeugt: ${DIST_DIR}"
else
  msg_info "Build übersprungen (unveränderter Commit). Mit --force-build erzwingen."
fi

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
HTPASSWD_FILE="/etc/nginx/.htpasswd-tolaria"
# Passwort über stdin statt via -b (steht sonst kurz in der Prozessliste).
# Bevorzugt bcrypt; Fallback auf das APR1-Standardformat, falls crypt fehlt.
if [[ -f "$HTPASSWD_FILE" ]]; then
  printf '%s\n' "$AUTH_PASS" | htpasswd -i -B "$HTPASSWD_FILE" "$AUTH_USER" 2>/dev/null \
    || printf '%s\n' "$AUTH_PASS" | htpasswd -i "$HTPASSWD_FILE" "$AUTH_USER"
else
  printf '%s\n' "$AUTH_PASS" | htpasswd -i -B -c "$HTPASSWD_FILE" "$AUTH_USER" 2>/dev/null \
    || printf '%s\n' "$AUTH_PASS" | htpasswd -i -c "$HTPASSWD_FILE" "$AUTH_USER"
fi
chown root:www-data "$HTPASSWD_FILE"
chmod 640 "$HTPASSWD_FILE"

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
