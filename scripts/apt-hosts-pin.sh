#!/usr/bin/env bash
#
# Pinnt die von apt/NodeSource benötigten Hosts kurzzeitig in /etc/hosts.
#
# Hintergrund: In manchen LXC-Netzen antwortet der Resolver auf einzelne
# Anfragen korrekt, scheitert aber unter der Last vieler paralleler
# apt-Downloads (NAT/Conntrack, Rate-Limits). apt meldet dann
# "Temporary failure resolving", obwohl "getent ahostsv4" funktioniert.
# Ein Eintrag in /etc/hosts umgeht den Resolver für die Dauer der
# Paketinstallation vollständig.
#
# Der Block wird über Marker verwaltet und mit "unpin" wieder entfernt,
# damit keine veralteten IP-Adressen zurückbleiben.
#
# Usage:
#   apt-hosts-pin.sh pin
#   apt-hosts-pin.sh unpin
#   apt-hosts-pin.sh pin --hosts-file /tmp/hosts --hosts "example.org"
#
# Exit-Codes:
#   0  erfolgreich (auch wenn nichts zu tun war)
#   1  kein Host auflösbar (nur bei "pin")
#   2  Aufruffehler
#
set -euo pipefail

HOSTS_FILE="/etc/hosts"
HOSTS="deb.debian.org security.debian.org deb.nodesource.com"
RETRIES=3
MARK_BEGIN="# >>> tolaria-apt-hosts >>>"
MARK_END="# <<< tolaria-apt-hosts <<<"

msg_info()  { echo "[INFO]  $*"; }
msg_ok()    { echo "[OK]    $*"; }
msg_warn()  { echo "[WARN]  $*"; }
msg_error() { echo "[ERROR] $*" >&2; }

usage() {
  cat <<'EOF'
Usage: apt-hosts-pin.sh pin|unpin [OPTIONEN]

Aktionen:
  pin                          Hosts auflösen und Block in /etc/hosts schreiben
  unpin                        Block wieder entfernen (idempotent)

Optionen:
  --hosts-file PATH            Zieldatei (Default: /etc/hosts, für Tests)
  --hosts "NAME [NAME ...]"    Hostnamen (Default: deb.debian.org
                               security.debian.org deb.nodesource.com)
  --retries N                  Auflöseversuche pro Host (Default: 3)
  --help, -h                   diese Hilfe
EOF
}

ACTION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    pin|unpin)     ACTION="$1"; shift ;;
    --hosts-file)  HOSTS_FILE="${2:?--hosts-file braucht einen Wert}"; shift 2 ;;
    --hosts)       HOSTS="${2:?--hosts braucht einen Wert}"; shift 2 ;;
    --retries)     RETRIES="${2:?--retries braucht einen Wert}"; shift 2 ;;
    --help|-h)     usage; exit 0 ;;
    *) msg_error "Unbekannte Option: $1"; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$ACTION" ]]; then
  msg_error "Aktion 'pin' oder 'unpin' fehlt."
  usage >&2
  exit 2
fi
[[ "$RETRIES" =~ ^[0-9]+$ ]] && (( RETRIES >= 1 )) \
  || { msg_error "--retries muss eine positive Zahl sein."; exit 2; }

# Entfernt den Block in-place. /etc/hosts ist im LXC häufig ein Bind-Mount,
# deshalb kein mv (das würde mit EBUSY scheitern).
remove_block() {
  [[ -f "$HOSTS_FILE" ]] || return 0
  grep -qF "$MARK_BEGIN" "$HOSTS_FILE" || return 0
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip
  ' "$HOSTS_FILE" > "${HOSTS_FILE}.tolaria.tmp"
  cat "${HOSTS_FILE}.tolaria.tmp" > "$HOSTS_FILE"
  rm -f "${HOSTS_FILE}.tolaria.tmp"
}

pin() {
  local h ip attempt entries=()
  for h in $HOSTS; do
    ip=""
    for ((attempt = 1; attempt <= RETRIES; attempt++)); do
      ip="$(getent ahostsv4 "$h" 2>/dev/null | awk 'NR==1 {print $1}')"
      [[ -n "$ip" ]] && break
      (( attempt < RETRIES )) && sleep 1
    done
    if [[ -n "$ip" ]]; then
      entries+=("$ip $h")
    else
      msg_warn "Konnte ${h} nicht auflösen - kein Pin für diesen Host."
    fi
  done

  remove_block
  if (( ${#entries[@]} == 0 )); then
    msg_warn "Kein Host auflösbar - /etc/hosts bleibt unverändert."
    return 1
  fi

  {
    echo "$MARK_BEGIN"
    printf '%s\n' "${entries[@]}"
    echo "$MARK_END"
  } >> "$HOSTS_FILE"
  msg_ok "apt-Hosts gepinnt: ${entries[*]}"
}

if [[ "$ACTION" == "unpin" ]]; then
  remove_block
  msg_ok "apt-Host-Pinning entfernt (${HOSTS_FILE})."
  exit 0
fi

pin
