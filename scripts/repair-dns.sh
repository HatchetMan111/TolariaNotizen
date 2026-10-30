#!/usr/bin/env bash
#
# Repariert die DNS-Auflösung im Container (und optional lokal zum Testen).
#
# Hintergrund: Proxmox übernimmt beim Erstellen/Starten eines LXC die
# Nameserver des Hosts. Läuft auf dem Host systemd-resolved, steht dort oft
# "nameserver 127.0.0.53". Dieser Stub-Resolver ist im Container nicht
# erreichbar -> jede Namensauflösung scheitert mit
#   "Temporary failure resolving 'deb.debian.org'".
#
# Dieses Skript prüft die Auflösung und schreibt nur dann eine neue
# /etc/resolv.conf, wenn sie nicht funktioniert. Schlägt der erste Nameserver
# fehl (z. B. LAN-DNS aus einem anderen Subnetz), wird ein öffentlicher
# Fallback probiert. Die ursprüngliche Datei wird vorher gesichert.
#
# Usage:
#   repair-dns.sh --servers "1.1.1.1 9.9.9.9"
#   repair-dns.sh --servers "192.168.1.1" --fallback-servers "1.1.1.1"
#   repair-dns.sh --servers "1.1.1.1" --resolv-conf /tmp/resolv.test --skip-check
#
# Exit-Codes:
#   0  DNS war bereits in Ordnung oder wurde erfolgreich repariert
#   1  DNS funktioniert auch nach dem Schreiben nicht
#   2  Aufruffehler (fehlende/ungültige Argumente)
#
set -euo pipefail

TEST_HOST="deb.debian.org"
RESOLV_CONF="/etc/resolv.conf"
SERVERS=""
FALLBACK_SERVERS="1.1.1.1 9.9.9.9"
FORCE=0
SKIP_CHECK=0

usage() {
  cat <<'EOF'
Usage: repair-dns.sh --servers "IP [IP ...]" [OPTIONEN]

Optionen:
  --servers "IP ..."           Nameserver, die geschrieben werden (Pflicht)
  --fallback-servers "IP ..."  Fallback, wenn --servers nicht auflösen
                               (Default: 1.1.1.1 9.9.9.9)
  --test-host NAME             Hostname für den Auflösungstest (Default: deb.debian.org)
  --resolv-conf PATH           Ziel-Datei (Default: /etc/resolv.conf, für Tests)
  --force                      Auch schreiben, wenn die Auflösung bereits funktioniert
  --skip-check                 Auflösungstest überspringen (nur für Tests)
  --help, -h                   diese Hilfe
EOF
}

msg_info()  { echo "[INFO]  $*"; }
msg_ok()    { echo "[OK]    $*"; }
msg_warn()  { echo "[WARN]  $*"; }
msg_error() { echo "[ERROR] $*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --servers)          SERVERS="${2:?--servers braucht einen Wert}"; shift 2 ;;
    --fallback-servers) FALLBACK_SERVERS="${2:?--fallback-servers braucht einen Wert}"; shift 2 ;;
    --test-host)        TEST_HOST="${2:?--test-host braucht einen Wert}"; shift 2 ;;
    --resolv-conf)      RESOLV_CONF="${2:?--resolv-conf braucht einen Wert}"; shift 2 ;;
    --force)            FORCE=1; shift ;;
    --skip-check)       SKIP_CHECK=1; shift ;;
    --help|-h)          usage; exit 0 ;;
    *) msg_error "Unbekannte Option: $1"; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$SERVERS" ]]; then
  msg_error "--servers fehlt."
  usage >&2
  exit 2
fi

# Nur IP-Adressen (IPv4/IPv6) akzeptieren - keine Shell-Injection über die
# Nameserver-Liste, und apt/resolver bekommen garantiert gültige Einträge.
validate_servers() {
  local label="$1" value="$2" ns
  local -a arr
  read -r -a arr <<< "$value"
  if (( ${#arr[@]} == 0 )); then
    msg_error "${label} enthält keine Namen."
    exit 2
  fi
  for ns in "${arr[@]}"; do
    if [[ ! "$ns" =~ ^[0-9A-Fa-f:.]+$ ]]; then
      msg_error "Ungültiger Nameserver in ${label}: '$ns' (erwartet IPv4/IPv6)."
      exit 2
    fi
  done
}

validate_servers "--servers" "$SERVERS"
validate_servers "--fallback-servers" "$FALLBACK_SERVERS"

dns_ok() {
  getent hosts "$TEST_HOST" >/dev/null 2>&1
}

if (( ! FORCE && ! SKIP_CHECK )) && dns_ok; then
  msg_ok "DNS funktioniert (${TEST_HOST} ist auflösbar)."
  exit 0
fi

# Backup nur der echten Systemdatei, und nur einmal pro Änderung.
if [[ "$RESOLV_CONF" == "/etc/resolv.conf" && -e "$RESOLV_CONF" ]]; then
  cp -a "$RESOLV_CONF" "${RESOLV_CONF}.tolaria.bak" 2>/dev/null || true
fi

restore_backup() {
  if [[ "$RESOLV_CONF" == "/etc/resolv.conf" && -f "${RESOLV_CONF}.tolaria.bak" ]]; then
    cp -a "${RESOLV_CONF}.tolaria.bak" "$RESOLV_CONF" 2>/dev/null \
      && msg_warn "Ursprüngliche ${RESOLV_CONF} wiederhergestellt."
  fi
}

# Schreibt die Datei atomar. mktemp + mv ersetzt auch einen Symlink (z. B.
# systemd-resolved stub) durch eine reguläre Datei.
write_resolv() {
  local servers="$1" ns tmp
  local -a arr
  read -r -a arr <<< "$servers"

  if ! tmp="$(mktemp "${RESOLV_CONF}.XXXXXX" 2>/dev/null)"; then
    msg_error "Kann ${RESOLV_CONF} nicht schreiben (keine Berechtigung?)."
    return 1
  fi

  {
    for ns in "${arr[@]}"; do
      printf 'nameserver %s\n' "$ns"
    done
    printf 'options timeout:2 attempts:2\n'
  } > "$tmp"

  chmod 644 "$tmp"
  if ! mv -f "$tmp" "$RESOLV_CONF"; then
    rm -f "$tmp"
    msg_error "Konnte ${RESOLV_CONF} nicht ersetzen (evtl. bind-gemountet?)."
    return 1
  fi
  msg_info "Nameserver geschrieben: ${servers} (${RESOLV_CONF})"
  return 0
}

try_servers() {
  local servers="$1"
  if ! write_resolv "$servers"; then
    return 1
  fi
  if (( SKIP_CHECK )); then
    return 0
  fi
  dns_ok
}

if try_servers "$SERVERS"; then
  msg_ok "DNS repariert (${TEST_HOST} ist auflösbar)."
  exit 0
fi

if [[ "$FALLBACK_SERVERS" != "$SERVERS" ]]; then
  msg_warn "Nameserver '${SERVERS}' lösen ${TEST_HOST} nicht auf - probiere Fallback '${FALLBACK_SERVERS}'."
  if try_servers "$FALLBACK_SERVERS"; then
    msg_warn "DNS nur mit Fallback-Nameservern repariert. Bei Bedarf --dns/--servers anpassen."
    exit 0
  fi
fi

restore_backup
msg_error "DNS-Auflösung funktioniert weiterhin nicht (${TEST_HOST})."
msg_error "Prüfe Gateway/Firewall und ob der DNS-Server erreichbar ist:"
msg_error "  getent hosts ${TEST_HOST}"
msg_error "  cat ${RESOLV_CONF}"
msg_error "  ip -4 route"
exit 1
