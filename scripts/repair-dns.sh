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
# /etc/resolv.conf, wenn sie nicht funktioniert. Geprüft wird die
# IPv4-Auflösung (A-Records), weil apt in einem IPv4-only-Container genau
# diese braucht - AAAA-Antworten allein reichen nicht. Schlägt der erste
# Nameserver fehl (z. B. LAN-DNS aus einem anderen Subnetz), wird ein
# öffentlicher Fallback probiert. Die ursprüngliche Datei wird vorher gesichert.
# Mit --persist-dhclient werden die geprüften Nameserver zusätzlich in
# dhclient.conf festgeschrieben, damit DHCP sie nicht wieder ersetzt.
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
PERSIST_DHCLIENT=0
DHCLIENT_CONF="/etc/dhcp/dhclient.conf"

usage() {
  cat <<'EOF'
Usage: repair-dns.sh --servers "IP [IP ...]" [OPTIONEN]

Optionen:
  --servers "IP ..."           Nameserver, die geschrieben werden (Pflicht)
  --fallback-servers "IP ..."  Fallback, wenn --servers nicht auflösen
                               (Default: 1.1.1.1 9.9.9.9)
  --test-host NAME             Hostname für den Auflösungstest (Default: deb.debian.org)
  --resolv-conf PATH           Ziel-Datei (Default: /etc/resolv.conf, für Tests)
  --persist-dhclient           Aktive Nameserver in dhclient.conf festschreiben,
                               damit DHCP sie nicht wieder überschreibt
  --dhclient-conf PATH         Ziel für --persist-dhclient
                               (Default: /etc/dhcp/dhclient.conf, für Tests)
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
    --persist-dhclient) PERSIST_DHCLIENT=1; shift ;;
    --dhclient-conf)    DHCLIENT_CONF="${2:?--dhclient-conf braucht einen Wert}"; shift 2 ;;
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

# apt läuft in einem IPv4-only-Container mit AI_ADDRCONFIG und braucht daher
# A-Records. "getent hosts" kann auch dann erfolgreich sein, wenn der Resolver
# nur AAAA-Antworten liefert - apt scheitert dann trotzdem mit
# "Temporary failure resolving". Deshalb wird hier die IPv4-Auflösung geprüft,
# sobald das System eine globale IPv4-Adresse hat.
has_global_ipv4() {
  command -v ip >/dev/null 2>&1 || return 0
  ip -4 addr show scope global 2>/dev/null | grep -q 'inet '
}

dns_ok() {
  if has_global_ipv4 && getent ahostsv4 localhost >/dev/null 2>&1; then
    getent ahostsv4 "$TEST_HOST" >/dev/null 2>&1
  else
    getent hosts "$TEST_HOST" >/dev/null 2>&1
  fi
}

# Zeigt bei Fehlschlag, welche Adressfamilie klemmt. Wichtig für die
# Unterscheidung "gar kein DNS" vs. "nur AAAA, aber kein A".
dns_family_diag() {
  msg_error "IPv4/A: $(getent ahostsv4 "$TEST_HOST" 2>&1 | awk 'NR<=2 {print $1}' | paste -sd' ' - || true)"
  msg_error "IPv6/AAAA: $(getent ahostsv6 "$TEST_HOST" 2>&1 | awk 'NR<=2 {print $1}' | paste -sd' ' - || true)"
}

active_servers() {
  awk '/^nameserver[[:space:]]/ {print $2}' "$RESOLV_CONF" 2>/dev/null \
    | grep -vE '^(127\.|::1$)' | head -n3 | paste -sd' ' - || true
}

# Schreib die aktiven Nameserver in dhclient.conf, damit der DHCP-Client sie
# bei jedem Lease nicht wieder durch (womöglich unbrauchbare) Server ersetzt.
# Idempotent über Marker; bestehende Datei bleibt erhalten.
persist_dhclient() {
  local servers="$1" list
  (( PERSIST_DHCLIENT )) || return 0
  [[ -n "$servers" ]] || return 0
  # Außerhalb des Tests nur, wenn dhclient wirklich installiert ist.
  if [[ "$DHCLIENT_CONF" == "/etc/dhcp/dhclient.conf" ]] \
     && ! command -v dhclient >/dev/null 2>&1; then
    return 0
  fi

  list="$(awk '{for (i = 1; i <= NF; i++) printf "%s%s", (i > 1 ? ", " : ""), $i}' <<<"$servers")"
  mkdir -p "$(dirname "$DHCLIENT_CONF")"
  if [[ -f "$DHCLIENT_CONF" ]]; then
    awk '/^# >>> tolaria-dns >>>$/{skip=1;next}
         /^# <<< tolaria-dns <<<$/{skip=0;next}
         !skip' "$DHCLIENT_CONF" > "${DHCLIENT_CONF}.tolaria.tmp"
    mv "${DHCLIENT_CONF}.tolaria.tmp" "$DHCLIENT_CONF"
  fi
  {
    echo '# >>> tolaria-dns >>>'
    echo '# Vom Tolaria-Installer: DHCP darf funktionierende Nameserver nicht'
    echo '# durch unbrauchbare ersetzen (sonst scheitert apt mit'
    echo '# "Temporary failure resolving").'
    echo "supersede domain-name-servers ${list};"
    echo '# <<< tolaria-dns <<<'
  } >> "$DHCLIENT_CONF"
  msg_ok "DHCP überschreibt DNS nicht mehr (supersede: ${servers})."
}

orig_ok=0
if dns_ok; then
  orig_ok=1
fi

if (( ! FORCE && ! SKIP_CHECK && ! PERSIST_DHCLIENT )) && (( orig_ok )); then
  msg_ok "DNS funktioniert (${TEST_HOST} ist per IPv4 auflösbar)."
  exit 0
fi

# Backup der Zieldatei, damit ein fehlgeschlagener Schreibversuch nichts
# kaputt macht (auch bei --resolv-conf in Tests).
if [[ -e "$RESOLV_CONF" ]]; then
  cp -a "$RESOLV_CONF" "${RESOLV_CONF}.tolaria.bak" 2>/dev/null || true
fi

restore_backup() {
  if [[ -f "${RESOLV_CONF}.tolaria.bak" ]]; then
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
  persist_dhclient "$SERVERS"
  msg_ok "DNS repariert (${TEST_HOST} ist per IPv4 auflösbar)."
  exit 0
fi

# Die vorhandene Konfiguration hat funktioniert, nur die gewünschten Server
# nicht: nicht kaputt machen, sondern die funktionierende Konfiguration
# wiederherstellen und festschreiben.
if (( orig_ok )); then
  restore_backup
  persist_dhclient "$(active_servers)"
  msg_ok "Vorhandene DNS-Konfiguration bleibt aktiv ('${SERVERS}' nicht erreichbar)."
  exit 0
fi

if [[ "$FALLBACK_SERVERS" != "$SERVERS" ]]; then
  msg_warn "Nameserver '${SERVERS}' lösen ${TEST_HOST} nicht auf - probiere Fallback '${FALLBACK_SERVERS}'."
  if try_servers "$FALLBACK_SERVERS"; then
    persist_dhclient "$FALLBACK_SERVERS"
    msg_warn "DNS nur mit Fallback-Nameservern repariert. Bei Bedarf --dns/--servers anpassen."
    exit 0
  fi
fi

restore_backup
msg_error "DNS-Auflösung funktioniert weiterhin nicht (${TEST_HOST})."
dns_family_diag
msg_error "Prüfe Gateway/Firewall und ob der DNS-Server erreichbar ist:"
msg_error "  getent ahostsv4 ${TEST_HOST}"
msg_error "  cat ${RESOLV_CONF}"
msg_error "  ip -4 route"
exit 1
