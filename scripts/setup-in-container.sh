#!/usr/bin/env bash
#
# Läuft IM LXC (vom Host-Installer per `pct exec` gestartet).
# Baut Tolaria Web, richtet Git-Vault, systemd und nginx ein.
#
set -euo pipefail
set +x
umask 077
# Ein per Tarball installiertes Node liegt unter /usr/local/bin und muss bei
# einem erneuten Lauf vor /usr/bin/node gefunden werden.
export PATH="/usr/local/bin:/usr/local/sbin:${PATH}"

APP="tolaria"
SETUP_VERSION="2026-10-31.7"
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
  if [[ -f /etc/hosts ]] && grep -qF '# >>> tolaria-apt-hosts >>>' /etc/hosts; then
    echo ""
    msg_error "--- /etc/hosts (apt-Pin-Block) ---"
    grep -A6 -F '# >>> tolaria-apt-hosts >>>' /etc/hosts 2>&1 || true
  fi
  if [[ -f /root/tolaria-apt-update.log ]]; then
    echo ""
    msg_error "--- apt-Update-Log (letzte 40 Zeilen) ---"
    tail -n 40 /root/tolaria-apt-update.log 2>&1 || true
  fi
  if [[ -f /root/tolaria-apt-proxy.log ]]; then
    echo ""
    msg_error "--- apt-Proxy-Log (letzte 20 Zeilen) ---"
    tail -n 20 /root/tolaria-apt-proxy.log 2>&1 || true
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
  debian-archive-keyring nginx apache2-utils openssl procps iproute2
)
APT_OPTS=(
  -o Acquire::Retries=5
  -o Acquire::http::Timeout=30
  -o Acquire::https::Timeout=30
  -o DPkg::Lock::Timeout=120
)
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
msg_info "Setup-Version: ${SETUP_VERSION}"
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

# Diese Optionen gelten für JEDEN apt-Aufruf im Container, auch für
# apt-get-Aufrufe innerhalb des NodeSource-Setup-Skripts. Ohne ForceIPv4
# kann apt in einem IPv4-only-Container AAAA-Antworten bevorzugen; die
# reduzierte Parallelität schont einen flakigen Resolver zusätzlich.
APT_CONF="/etc/apt/apt.conf.d/99tolaria-network"
if [[ -d /etc/apt/apt.conf.d ]]; then
  cat > "$APT_CONF" <<'EOF'
Acquire::ForceIPv4 "true";
Acquire::Retries "5";
Acquire::http::Timeout "30";
Acquire::https::Timeout "30";
Acquire::http::Pipeline-Depth "0";
Acquire::Queue-Mode "access";
EOF
  chmod 644 "$APT_CONF"
fi

# ---------------------------------------------------------------------------
# apt-Hosts vorab auflösen
# ---------------------------------------------------------------------------
# In manchen LXC-Netzen antwortet der Resolver bei einzelnen Anfragen sauber,
# scheitert aber unter der Last vieler paralleler apt-Downloads (NAT/Conntrack,
# Rate-Limits). "Temporary failure resolving" trotz funktionierendem getent
# ist dann die Folge. Die apt-Hosts werden deshalb für die Dauer der
# Paketinstallation in /etc/hosts gepinnt und danach wieder entfernt.
#
# Wichtig: Das Pinning darf NICHT davon abhängen, dass apt-hosts-pin.sh im
# Container angekommen ist. Genau daran ist ein realer Lauf gescheitert: Das
# (noch alte) Host-Skript hat die Datei nicht mitgepusht, das (neue) Setup
# fand sie nicht und fiel still auf DNS zurück. Deshalb gibt es hier einen
# eingebauten Fallback, der /etc/hosts selbst schreibt.
# >>> tolaria-inline-pin >>>
APT_HOSTS_PIN="${PKG_DIR}/apt-hosts-pin.sh"
APT_HOSTS_PINNED=0
APT_HOSTS_FILE="${APT_HOSTS_FILE:-/etc/hosts}"
NSSWITCH_FILE="${NSSWITCH_FILE:-/etc/nsswitch.conf}"
APT_PROXY_PL="${PKG_DIR}/apt-proxy.pl"
APT_PROXY_PORT="${APT_PROXY_PORT:-3142}"
APT_PROXY_CONF="/etc/apt/apt.conf.d/99tolaria-proxy"
APT_PROXY_PID=""
APT_PROXY_ACTIVE=0
APT_HOSTS_BEGIN="# >>> tolaria-apt-hosts >>>"
APT_HOSTS_END="# <<< tolaria-apt-hosts <<<"
APT_HOSTS_LIST="deb.debian.org security.debian.org deb.nodesource.com"

apt_hosts_remove_block() {
  [[ -f "$APT_HOSTS_FILE" ]] || return 0
  grep -qF "$APT_HOSTS_BEGIN" "$APT_HOSTS_FILE" || return 0
  local tmp
  tmp="$(mktemp "${APT_HOSTS_FILE}.tolaria.XXXXXX")" || return 1
  awk -v b="$APT_HOSTS_BEGIN" -v e="$APT_HOSTS_END" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip
  ' "$APT_HOSTS_FILE" > "$tmp"
  cat "$tmp" > "$APT_HOSTS_FILE"
  rm -f "$tmp"
}

apt_hosts_pin_inline() {
  local h ip tail_hex
  local -a ips=() entries=()
  for h in $APT_HOSTS_LIST; do
    mapfile -t ips < <(getent ahostsv4 "$h" 2>/dev/null \
      | awk '{print $1}' | awk '!seen[$0]++' | head -n2)
    if (( ${#ips[@]} == 0 )); then
      msg_warn "Konnte ${h} nicht auflösen - kein Pin für diesen Host."
      continue
    fi
    for ip in "${ips[@]}"; do entries+=("$ip $h"); done
  done
  (( ${#entries[@]} > 0 )) || return 1
  apt_hosts_remove_block || return 1
  # /etc/hosts endet nicht immer mit einem Zeilenumbruch. Ohne diese Prüfung
  # würde der Marker an die letzte Zeile angeklebt und nie wieder erkannt.
  if [[ -s "$APT_HOSTS_FILE" ]]; then
    tail_hex="$(tail -c 1 "$APT_HOSTS_FILE" | od -An -t x1 | tr -d ' \n')"
    [[ "$tail_hex" == "0a" ]] || printf '\n' >> "$APT_HOSTS_FILE"
  fi
  {
    printf '%s\n' "$APT_HOSTS_BEGIN"
    printf '%s\n' "${entries[@]}"
    printf '%s\n' "$APT_HOSTS_END"
  } >> "$APT_HOSTS_FILE"
  # apt liest /etc/hosts beim Download als _apt; Modus 600 würde den Pin
  # für apt unsichtbar machen, obwohl getent als root ihn sieht.
  chmod 644 "$APT_HOSTS_FILE" 2>/dev/null || true
  msg_ok "apt-Hosts gepinnt (eingebauter Fallback): ${entries[*]}"
}

# Prüft, dass der Pin wirklich greift: getent muss den gepinnten Eintrag aus
# /etc/hosts zurückgeben, nicht nur irgendeine DNS-Antwort.
apt_hosts_verified() {
  local ip
  ip="$(getent ahostsv4 deb.debian.org 2>/dev/null | awk 'NR==1 {print $1}')"
  [[ -n "$ip" ]] || return 1
  grep -qxF "${ip} deb.debian.org" "$APT_HOSTS_FILE"
}

# Stellt sicher, dass die Namensauflösung /etc/hosts überhaupt liest.
# In manchen Containern steht in nsswitch.conf "hosts: resolve ..." oder
# "hosts: dns files"; dann liefert getent eine DNS-Antwort und der Pin wird
# zwar als "verifiziert" erkannt (gleiche IP), apt fragt aber weiter DNS und
# scheitert unter Last. Ein Sentinel-Hostname macht das sichtbar.
ensure_hosts_lookup() {
  local sentinel="tolaria-hosts-check.invalid"
  local tmp ok=0

  # Ohne getent können wir die Auflösung nicht prüfen; dann lieber nichts
  # an nsswitch.conf ändern.
  command -v getent >/dev/null 2>&1 || return 0

  if [[ ! -f "$APT_HOSTS_FILE" ]]; then
    : > "$APT_HOSTS_FILE" || return 1
  fi
  if [[ ! -f "$NSSWITCH_FILE" ]]; then
    printf 'hosts: files dns\n' > "$NSSWITCH_FILE" || return 1
  fi

  printf '127.0.0.1 %s\n' "$sentinel" >> "$APT_HOSTS_FILE" || return 1
  if getent ahostsv4 "$sentinel" 2>/dev/null | awk 'NR==1 {print $1}' | grep -qx '127.0.0.1'; then
    ok=1
  fi
  tmp="$(mktemp "${APT_HOSTS_FILE}.tolaria.XXXXXX")" || return 1
  if ! awk -v s="$sentinel" '$NF != s' "$APT_HOSTS_FILE" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  cat "$tmp" > "$APT_HOSTS_FILE"
  rm -f "$tmp"
  (( ok )) && return 0

  msg_warn "Namensauflösung ignoriert /etc/hosts - setze in ${NSSWITCH_FILE} 'hosts: files dns'."
  cp -a "$NSSWITCH_FILE" "${NSSWITCH_FILE}.tolaria.bak" 2>/dev/null || true
  tmp="$(mktemp "${NSSWITCH_FILE}.tolaria.XXXXXX")" || return 1
  if ! awk '
    /^[[:space:]]*hosts:/ {
      if (!done) { print "hosts: files dns"; done = 1 }
      next
    }
    { print }
    END { if (!done) print "hosts: files dns" }
  ' "$NSSWITCH_FILE" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  cat "$tmp" > "$NSSWITCH_FILE"
  rm -f "$tmp"

  printf '127.0.0.1 %s\n' "$sentinel" >> "$APT_HOSTS_FILE" || return 1
  if getent ahostsv4 "$sentinel" 2>/dev/null | awk 'NR==1 {print $1}' | grep -qx '127.0.0.1'; then
    ok=1
  fi
  tmp="$(mktemp "${APT_HOSTS_FILE}.tolaria.XXXXXX")" || return 1
  if ! awk -v s="$sentinel" '$NF != s' "$APT_HOSTS_FILE" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  cat "$tmp" > "$APT_HOSTS_FILE"
  rm -f "$tmp"

  if (( ok )); then
    msg_ok "Namensauflösung liest /etc/hosts (${NSSWITCH_FILE} korrigiert)."
    return 0
  fi
  msg_error "Namensauflösung ignoriert /etc/hosts weiterhin - Host-Pinning kann apt nicht retten."
  return 1
}

pin_apt_hosts() {
  APT_HOSTS_PINNED=0
  ensure_hosts_lookup || msg_warn "Hosts-Pinning läuft ohne garantierte /etc/hosts-Auflösung."
  if [[ -f "$APT_HOSTS_PIN" ]]; then
    if ! bash "$APT_HOSTS_PIN" pin; then
      msg_warn "apt-hosts-pin.sh ist fehlgeschlagen - nutze eingebauten Fallback."
      apt_hosts_pin_inline || true
    fi
  else
    msg_warn "apt-hosts-pin.sh fehlt (veraltetes Packaging?) - nutze eingebauten Fallback."
    apt_hosts_pin_inline || true
  fi
  if apt_hosts_verified; then
    APT_HOSTS_PINNED=1
    msg_ok "apt-Hosts verifiziert - apt braucht für die Installation kein DNS."
  else
    msg_warn "apt-Hosts konnten nicht verifiziert werden - apt nutzt DNS (anfällig)."
  fi
  (( APT_HOSTS_PINNED ))
}

unpin_apt_hosts() {
  APT_HOSTS_PINNED=0
  if [[ -f "$APT_HOSTS_PIN" ]]; then
    bash "$APT_HOSTS_PIN" unpin >/dev/null 2>&1 || true
  fi
  # Immer zusätzlich inline aufräumen: So bleibt auch bei einer defekten
  # oder veralteten apt-hosts-pin.sh kein Marker in /etc/hosts zurück.
  apt_hosts_remove_block >/dev/null 2>&1 || true
}

# Letzte Verteidigungslinie: Ein lokaler Proxy, der die gepinnten IPs selbst
# anspricht. Damit ist apt complete unabhängig davon, ob es /etc/hosts liest.
start_apt_proxy() {
  (( APT_PROXY_ACTIVE )) && return 0
  APT_PROXY_ACTIVE=0
  command -v perl >/dev/null 2>&1 \
    || { msg_warn "perl fehlt - apt-Proxy nicht verfügbar."; return 1; }
  [[ -f "$APT_PROXY_PL" ]] \
    || { msg_warn "apt-proxy.pl fehlt (veraltetes Packaging?) - kein apt-Proxy."; return 1; }

  local map="$PKG_DIR/apt-hosts.map"
  awk -v b="$APT_HOSTS_BEGIN" -v e="$APT_HOSTS_END" '
    $0 == b { inblock = 1; next }
    $0 == e { inblock = 0; next }
    inblock && NF >= 2 { print $2, $1 }
  ' "$APT_HOSTS_FILE" > "$map"
  if [[ ! -s "$map" ]]; then
    msg_warn "Kein Host-Mapping für den apt-Proxy - nutze direkte Verbindungen."
    return 1
  fi

  perl "$APT_PROXY_PL" --port "$APT_PROXY_PORT" --map "$map" \
    >/root/tolaria-apt-proxy.log 2>&1 &
  APT_PROXY_PID=$!
  sleep 0.3
  if ! kill -0 "$APT_PROXY_PID" 2>/dev/null; then
    msg_warn "apt-Proxy startet nicht: $(tail -n1 /root/tolaria-apt-proxy.log 2>/dev/null || true)"
    APT_PROXY_PID=""
    return 1
  fi

  {
    printf 'Acquire::http::Proxy "http://127.0.0.1:%s";\n' "$APT_PROXY_PORT"
    printf 'Acquire::https::Proxy "http://127.0.0.1:%s";\n' "$APT_PROXY_PORT"
  } > "$APT_PROXY_CONF"
  chmod 644 "$APT_PROXY_CONF"
  APT_PROXY_ACTIVE=1
  msg_ok "apt-Proxy aktiv (127.0.0.1:${APT_PROXY_PORT}, $(wc -l < "$map") Hosts)."
}

stop_apt_proxy() {
  if [[ -n "$APT_PROXY_PID" ]]; then
    kill "$APT_PROXY_PID" 2>/dev/null || true
    wait "$APT_PROXY_PID" 2>/dev/null || true
    APT_PROXY_PID=""
  fi
  rm -f "$APT_PROXY_CONF"
  APT_PROXY_ACTIVE=0
}

cleanup_apt() {
  stop_apt_proxy
  unpin_apt_hosts
}
# <<< tolaria-inline-pin <<<
trap cleanup_apt EXIT

# ---------------------------------------------------------------------------
# Pakete
# ---------------------------------------------------------------------------
msg_info "Aktualisiere Paketlisten und installiere Systempakete ..."
export DEBIAN_FRONTEND=noninteractive

if pin_apt_hosts; then
  start_apt_proxy || msg_warn "apt-Proxy nicht verfügbar - apt nutzt direkte Verbindungen."
else
  msg_warn "Weiter ohne verifizierten Pin - apt nutzt DNS (anfällig)."
fi

# apt-get update kann mit Exit 0 enden, obwohl ALLE Indexe nicht geladen
# wurden ("W: Failed to fetch ... Some index files failed to download").
# Deshalb wird die Ausgabe geprüft und der Fall explizit behandelt.
apt_update_once() {
  apt-get update "${APT_OPTS[@]}" >"$APT_LOG" 2>&1
}

apt_log_has_fetch_errors() {
  [[ -s "$APT_LOG" ]] && grep -qE 'Failed to fetch|Temporary failure resolving|Could not resolve' "$APT_LOG"
}

# Eine Stelle für alle apt-Diagnosen, damit Fehlerberichte vergleichbar sind.
# Proxy-Werte werden bewusst nicht ausgegeben (können Zugangsdaten enthalten).
apt_diag() {
  msg_error "--- apt-Diagnose ---"
  msg_error "Nameserver: ${TOLARIA_DNS_SERVERS}"
  msg_error "IPv4/A: $(getent ahostsv4 deb.debian.org 2>&1 | awk 'NR<=2 {print $1}' | paste -sd' ' - || true)"
  msg_error "IPv6/AAAA: $(getent ahostsv6 deb.debian.org 2>&1 | awk 'NR<=2 {print $1}' | paste -sd' ' - || true)"
  msg_error "Pin aktiv: ${APT_HOSTS_PINNED}"
  msg_error "hosts-Rechte: $(stat -c '%a %U:%G %n' "$APT_HOSTS_FILE" 2>/dev/null || echo 'nicht lesbar')"
  cp -a "$APT_HOSTS_FILE" /root/tolaria-hosts.debug 2>/dev/null || true
  if id -u _apt >/dev/null 2>&1; then
    if runuser -u _apt -- test -r "$APT_HOSTS_FILE" 2>/dev/null; then
      msg_error "_apt kann ${APT_HOSTS_FILE} lesen: ja"
    else
      msg_error "_apt kann ${APT_HOSTS_FILE} lesen: NEIN (apt ignoriert den Pin)"
    fi
    runuser -u _apt -- getent ahostsv4 deb.debian.org 2>&1 \
      | awk 'NR<=2 {print "  _apt getent: " $1}' || true
  fi
  if [[ -f "$APT_HOSTS_FILE" ]] && grep -qF "$APT_HOSTS_BEGIN" "$APT_HOSTS_FILE"; then
    msg_error "--- /etc/hosts (Pin-Block) ---"
    grep -A6 -F "$APT_HOSTS_BEGIN" "$APT_HOSTS_FILE" 2>/dev/null || true
  fi
  msg_error "--- apt-Proxy (nur gesetzte Schlüssel) ---"
  apt-config dump 2>/dev/null | awk '/Proxy/ {print "  " $1 " <gesetzt>"}' || true
  msg_error "Lokaler apt-Proxy aktiv: ${APT_PROXY_ACTIVE}"
  if [[ -f /root/tolaria-apt-proxy.log ]]; then
    tail -n 10 /root/tolaria-apt-proxy.log 2>/dev/null || true
  fi
  msg_error "--- /etc/resolv.conf ---"
  cat /etc/resolv.conf 2>/dev/null || true
  msg_error "--- letzte ${APT_LOG##*/}-Zeilen ---"
  tail -n 40 "$APT_LOG" 2>/dev/null || true
}

update_ok=0
if retry 3 5 apt_update_once; then
  update_ok=1
fi
if (( update_ok == 0 )) && (( APT_PROXY_ACTIVE )); then
  msg_warn "apt-Update über den lokalen Proxy fehlgeschlagen - stoppe Proxy und versuche direkt ..."
  stop_apt_proxy
  if retry 2 5 apt_update_once; then
    update_ok=1
  fi
fi
if (( update_ok == 0 )) && (( APT_HOSTS_PINNED )); then
  msg_warn "apt-get update mit verifiziertem Host-Pinning fehlgeschlagen - teste DNS als Gegenprobe ..."
  unpin_apt_hosts
  if retry 2 5 apt_update_once; then
    update_ok=1
  fi
fi

if (( update_ok == 0 )); then
  apt_diag
  msg_error "apt-get update ist fehlgeschlagen (DNS, Proxy oder Mirror-Problem)."
  msg_error "Ein oben sichtbarer Pin-Block schließt DNS als Hauptursache weitgehend aus."
  exit 1
fi

if apt_log_has_fetch_errors; then
  msg_warn "apt-get update meldet Fetch-Fehler - prüfe, ob die Pakete trotzdem auflösbar sind ..."
  if apt-get install -y --simulate --no-install-recommends "${APT_OPTS[@]}" "${APT_PACKAGES[@]}" >/dev/null 2>&1; then
    msg_warn "Paketauflösung funktioniert trotz Fetch-Warnungen - fahre fort."
  else
    apt_diag
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
    apt_diag
    msg_error "DNS-Reparatur vor dem Paketdownload fehlgeschlagen."
    exit 1
  fi
fi

install_ok=0
if retry 3 10 apt_install_packages; then
  install_ok=1
fi
if (( install_ok == 0 )); then
  msg_warn "Erster Installationsversuch fehlgeschlagen - aktualisiere Listen und versuche es erneut ..."
  # Pin nicht vorschnell entfernen: Wenn er verifiziert ist, ist DNS nicht die
  # Ursache. Erst mit Pin neu laden und erneut installieren.
  retry 2 10 apt_update_once || msg_warn "apt-get update beim zweiten Versuch fehlgeschlagen."
  if retry 3 10 apt_install_packages; then
    install_ok=1
  fi
fi

# Letzter Ausweg: Der gepinnte Mirror-IP-Block kann selbst unerreichbar sein
# (z. B. blockiertes Fastly-Subnetz). Dann zurück auf DNS.
if (( install_ok == 0 )) && (( APT_HOSTS_PINNED )); then
  msg_warn "Mit gepinnten Hosts weiterhin Fehler - letzter Versuch über DNS ..."
  stop_apt_proxy
  unpin_apt_hosts
  retry 2 10 apt_update_once || msg_warn "apt-get update über DNS fehlgeschlagen."
  if apt-get install -y --no-install-recommends --fix-missing "${APT_OPTS[@]}" "${APT_PACKAGES[@]}"; then
    install_ok=1
  fi
fi

# Manche Container haben ein /etc/hosts, das _apt nicht lesen darf. getent
# als root sieht den Pin dann, apt als _apt aber nicht. Der Pin wird dafür
# erneut gesetzt und apt ohne Sandbox-User gestartet.
if (( install_ok == 0 )) && (( APT_HOSTS_PINNED == 0 )); then
  msg_warn "Letzter Versuch: Pin erneut setzen und apt ohne _apt-Sandbox ausführen ..."
  if pin_apt_hosts; then
    apt-get update "${APT_OPTS[@]}" -o APT::Sandbox::User=root >"$APT_LOG" 2>&1 \
      || msg_warn "apt-get update ohne _apt-Sandbox fehlgeschlagen."
    if apt-get install -y --no-install-recommends "${APT_OPTS[@]}" \
         -o APT::Sandbox::User=root "${APT_PACKAGES[@]}"; then
      install_ok=1
    fi
  fi
fi

if (( install_ok == 0 )); then
  apt_diag
  msg_error "Systempakete konnten nicht installiert werden."
  msg_error "Häufigste Ursachen: DNS/Internet/Proxy im Container, blockierter Mirror"
  msg_error "oder ein veraltetes Paket-Index. Details siehe ${APT_LOG}."
  exit 1
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
# CA-Bundle und Debian-Keyring
# ---------------------------------------------------------------------------
# Der NodeSource-Repo-Zugriff läuft über HTTPS. Fehlt das CA-Bundle oder ist
# der Keyring unvollständig, scheitert apt mit "No system certificates" bzw.
# NO_PUBKEY und installiert anschließend das alte Debian-Node statt 22.
msg_info "Prüfe CA-Bundle und Debian-Keyring ..."
if ! retry 2 5 apt-get install -y --reinstall --no-install-recommends \
      "${APT_OPTS[@]}" ca-certificates debian-archive-keyring; then
  msg_warn "Reinstall von ca-certificates/debian-archive-keyring fehlgeschlagen."
fi
if command -v update-ca-certificates >/dev/null 2>&1; then
  update-ca-certificates --fresh >/dev/null 2>&1 \
    || msg_warn "update-ca-certificates meldet einen Fehler."
fi
if [[ -s /etc/ssl/certs/ca-certificates.crt ]]; then
  msg_ok "CA-Bundle vorhanden ($(wc -c < /etc/ssl/certs/ca-certificates.crt) Bytes)."
else
  msg_error "CA-Bundle fehlt: /etc/ssl/certs/ca-certificates.crt"
  msg_error "NodeSource (HTTPS) kann ohne CA-Bundle nicht funktionieren."
  msg_error "Im Container prüfen: dpkg -l ca-certificates; update-ca-certificates --fresh"
  exit 1
fi
if retry 2 5 apt_update_once; then
  msg_ok "Paketlisten nach Keyring-Update aktualisiert."
else
  msg_warn "apt-get update nach Keyring-Update fehlgeschlagen."
fi

# ---------------------------------------------------------------------------
# Node 22.14+ und pnpm 10.33.0
# ---------------------------------------------------------------------------
# NodeSource ist der bevorzugte Weg, aber apts HTTPS-Methode kann in
# Containern an CA-/GPG-Problemen scheitern. Der offizielle Node-Tarball
# umgeht apt vollständig; curl prüft das Zertifikat gegen das CA-Bundle.
install_node_tarball() {
  local prefix="${NODE_PREFIX:-/usr/local}"
  local base="https://nodejs.org/dist/latest-v22.x"
  local sums="/tmp/tolaria-node-SHASUMS256.txt"
  local file ip
  local -a curl_opts=()

  command -v curl >/dev/null 2>&1 || { msg_error "curl fehlt für den Node-Tarball."; return 1; }
  command -v tar >/dev/null 2>&1 || { msg_error "tar fehlt für den Node-Tarball."; return 1; }
  command -v sha256sum >/dev/null 2>&1 || { msg_error "sha256sum fehlt."; return 1; }

  # nodejs.org per IPv4 pinnen, damit auch dieser Download kein DNS braucht.
  ip="$(getent ahostsv4 nodejs.org 2>/dev/null | awk 'NR==1 {print $1}')"
  if [[ -z "$ip" ]]; then
    msg_error "nodejs.org ist nicht per IPv4 auflösbar."
    return 1
  fi
  curl_opts=(--resolve "nodejs.org:443:${ip}")

  download_node_file() {
    local url="$1" out="$2" max_time="$3"
    if retry 3 5 curl -fsSL --max-time "$max_time" \
         "${curl_opts[@]}" "$url" -o "$out"; then
      return 0
    fi
    msg_warn "Download über die gepinnte IP fehlgeschlagen - versuche normalen DNS-Weg."
    retry 3 5 curl -fsSL --max-time "$max_time" "$url" -o "$out"
  }

  msg_info "Lade Node.js-22-Tarball von nodejs.org (${ip}) ..."
  if ! download_node_file "${base}/SHASUMS256.txt" "$sums" 60; then
    msg_error "SHASUMS256.txt konnte nicht geladen werden."
    return 1
  fi
  file="$(awk '$2 ~ /^node-v[0-9]+\.[0-9]+\.[0-9]+-linux-x64\.tar\.gz$/ {print $2}' "$sums" | tail -n1)"
  if [[ -z "$file" ]]; then
    msg_error "Kein linux-x64-Tarball in SHASUMS256.txt gefunden."
    return 1
  fi
  if ! download_node_file "${base}/${file}" "/tmp/${file}" 300; then
    msg_error "Node-Tarball konnte nicht geladen werden: ${file}"
    return 1
  fi
  if ! (cd /tmp && awk -v f="$file" '$2 == f' "$sums" | sha256sum -c -); then
    msg_error "SHA256-Prüfung des Node-Tarballs fehlgeschlagen."
    rm -f "/tmp/${file}" "$sums"
    return 1
  fi

  mkdir -p "$prefix"
  if ! tar -xzf "/tmp/${file}" -C "$prefix" --strip-components=1 --no-same-owner; then
    msg_error "Node-Tarball konnte nicht entpackt werden."
    rm -f "/tmp/${file}" "$sums"
    return 1
  fi
  rm -f "/tmp/${file}" "$sums"
  export PATH="${prefix}/bin:${PATH}"
  hash -r
  command -v node >/dev/null 2>&1 || { msg_error "node nach Tarball-Installation nicht gefunden."; return 1; }
  msg_ok "Node.js $(node --version) aus Tarball installiert (${prefix})."
}

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
  if pin_apt_hosts; then
    start_apt_proxy || msg_warn "apt-Proxy für NodeSource nicht verfügbar - nutze direkte Verbindungen."
  else
    msg_warn "NodeSource-Pin nicht verifiziert - nutze DNS."
  fi
  # curl (NodeSource-Setup) und das Setup-Skript selbst sollen denselben
  # lokalen Proxy nutzen wie apt. Sonst hängt der nächste Schritt wieder an DNS.
  if (( APT_PROXY_ACTIVE )); then
    export http_proxy="http://127.0.0.1:${APT_PROXY_PORT}"
    export https_proxy="$http_proxy"
    export no_proxy="localhost,127.0.0.1"
  fi
  if retry 3 5 curl -fsSL --max-time 60 https://deb.nodesource.com/setup_22.x -o /tmp/nodesource_setup.sh; then
    if bash /tmp/nodesource_setup.sh; then
      rm -f /tmp/nodesource_setup.sh
      if ! retry 3 10 apt-get install -y "${APT_OPTS[@]}" nodejs; then
        msg_warn "NodeSource-apt-Installation fehlgeschlagen - versuche den offiziellen Tarball."
      fi
    else
      rm -f /tmp/nodesource_setup.sh
      msg_warn "NodeSource-Setup ist fehlgeschlagen - versuche den offiziellen Tarball."
    fi
  else
    msg_warn "NodeSource-Setup konnte nicht geladen werden - versuche den offiziellen Tarball."
  fi
  unset http_proxy https_proxy no_proxy
  unpin_apt_hosts
else
  msg_ok "Node.js $(node --version) bereits vorhanden."
fi

# Falls NodeSource nur das alte Debian-Node geliefert hat: offiziellen
# Node-22-Tarball installieren. Das ist unabhängig von apt/GPG/HTTPS-apt.
node_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
node_minor="$(node -p 'process.versions.node.split(".")[1]' 2>/dev/null || echo 0)"
if (( node_major < 22 || (node_major == 22 && node_minor < 14) )); then
  msg_warn "Node.js $(node --version 2>/dev/null || echo '<fehlt>') ist zu alt - installiere den offiziellen Node-22-Tarball."
  install_node_tarball || { msg_error "Node.js 22.14+ konnte nicht installiert werden."; exit 1; }
  node_major="$(node -p 'process.versions.node.split(".")[0]')"
  node_minor="$(node -p 'process.versions.node.split(".")[1]')"
  if (( node_major < 22 || (node_major == 22 && node_minor < 14) )); then
    msg_error "Node.js $(node --version) ist weiterhin zu alt."
    exit 1
  fi
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
    PATH="/usr/local/bin:/usr/bin:/bin" \
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
    PATH="/usr/local/bin:/usr/bin:/bin" \
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

NODE_BIN="$(command -v node || true)"
[[ -n "$NODE_BIN" ]] || { msg_error "node ist nicht im PATH - systemd-Unit kann nicht geschrieben werden."; exit 1; }
# Bei einer Tarball-Installation liegt node unter /usr/local/bin/node, nicht
# unter /usr/bin/node. Die Unit muss deshalb den tatsächlichen Pfad nutzen.
sed "s|^ExecStart=/usr/bin/node|ExecStart=${NODE_BIN}|" \
  "${PKG_DIR}/tolaria.service" > /etc/systemd/system/tolaria.service
chown root:root /etc/systemd/system/tolaria.service
chmod 644 /etc/systemd/system/tolaria.service
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
