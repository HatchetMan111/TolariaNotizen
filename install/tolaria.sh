#!/usr/bin/env bash
#
# Tolaria Proxmox LXC Installer - im Stil der Proxmox VE Community Scripts
#
# App:      Tolaria - lokale Markdown-Wissensbasis / Second Brain
# Upstream: https://github.com/refactoringhq/tolaria
# Stack:    Tauri/React Web-Build + Tolaria-Server (Node 22) + Git-Vault + nginx
# Host:     DIESES SKRIPT LÄUFT AUF DEM PROXMOX-HOST (nicht im Container!)
#
# Usage:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/TolariaNotizen/main/install/tolaria.sh)"
#   CT_ID=150 CORES=4 RAM=6144 DISK=12 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/TolariaNotizen/main/install/tolaria.sh)"
#   bash tolaria.sh --ctid 150 --cores 4 --memory 6144 --disk 12 --debug
#
# WICHTIG: Tolaria Web ist Upstream-Alpha. Der erste Build dauert je nach Host
# und Internet 10-25 Minuten und braucht die unten stehenden Ressourcen.
#
set -euo pipefail
umask 077

# ---------------------------------------------------------------------------
# Variablen (oben, Community-Scripts-konform - alles hier anpassbar)
# ---------------------------------------------------------------------------
APP="tolaria"
APP_TITLE="Tolaria"
INSTALLER_VERSION="2026-10-31.6"
PORT="${PORT:-8080}"                            # nginx / Web-UI
SERVER_PORT="8787"                              # Tolaria-Server, nur 127.0.0.1
UPSTREAM_REPO="https://github.com/refactoringhq/tolaria.git"
UPSTREAM_REF="${TOLARIA_REF:-main}"
INSTALLER_RAW="${TOLARIA_RAW_BASE:-https://raw.githubusercontent.com/HatchetMan111/TolariaNotizen/main}"
# Packaging wird bevorzugt als ein atomarer Tarball geladen. Einzelne
# Raw-Dateien können unterschiedlich lange im CDN-Cache liegen; dann passen
# Host-Skript und Container-Skripte nicht zusammen (genau das ist bei einem
# realen Lauf passiert). Der Tarball enthält dagegen einen konsistenten Stand.
INSTALLER_REPO_SLUG="${TOLARIA_REPO_SLUG:-HatchetMan111/TolariaNotizen}"
PACKAGING_REF="${TOLARIA_PACKAGING_REF:-main}"
PACKAGING_TARBALL="${TOLARIA_PACKAGING_TARBALL:-}"

DEFAULT_CORES="${CORES:-4}"                     # vCPU (Build ist CPU-hungrig)
DEFAULT_RAM="${RAM:-6144}"                      # MB (tsc + vite brauchen Luft)
DEFAULT_SWAP="${SWAP:-4096}"                    # MB
DEFAULT_DISK="${DISK:-12}"                      # GB
DEFAULT_BRIDGE="${BRIDGE:-vmbr0}"
DEFAULT_TEMPLATE_STORE="${TEMPLATE_STORE:-local}"
DEFAULT_OS="debian-12-standard"
UNPRIVILEGED="1"
FEATURES=""                                     # kein Docker/nesting nötig
HOSTNAME_ARG="${CT_HOSTNAME:-$APP}"
AUTH_USER="${AUTH_USER:-tolaria}"
AUTH_PASS="${AUTH_PASS:-}"
DNS_SERVERS="${DNS_SERVERS:-}"                  # optional, z. B. "192.168.1.1 1.1.1.1"
FALLBACK_DNS_SERVERS="1.1.1.1 9.9.9.9"
FORCE_BUILD="${FORCE_BUILD:-0}"

DEBUG="${DEBUG:-0}"
DRY_RUN=0
LOG_FILE="/tmp/${APP}-install-$(date +%F-%H%M%S).log"
SCRIPT_ARGS="$*"

# ---------------------------------------------------------------------------
# Logging / Farben (Community-Scripts-Stil)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' \
  C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m'
else
  C_RESET="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE=""
fi

msg_info()  { echo -e "${C_BLUE}[INFO]${C_RESET}  $*"; }
msg_ok()    { echo -e "${C_GREEN}[OK]${C_RESET}    $*"; }
msg_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
msg_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }

usage() {
  cat <<EOF
${APP_TITLE} Proxmox LXC Installer

Usage:
  bash tolaria.sh [OPTIONEN]
  CT_ID=150 bash tolaria.sh
  wget -qO /tmp/tolaria.sh '${INSTALLER_RAW}/install/tolaria.sh?cb='\$(date +%s) && bash /tmp/tolaria.sh

Hinweis: Der Cache-Buster ('?cb=...') verhindert, dass ein veraltetes
Skript aus dem GitHub-CDN ausgeführt wird.

Optionen:
  --ctid ID            Container-ID (Default: nächste freie ID via 'pvesh get /cluster/nextid')
  --hostname NAME      Hostname (Default: ${APP})
  --cores N            vCPU (Default: ${DEFAULT_CORES})
  --memory MB          RAM in MB (Default: ${DEFAULT_RAM})
  --swap MB            Swap in MB (Default: ${DEFAULT_SWAP})
  --disk GB            Disk in GB (Default: ${DEFAULT_DISK})
  --storage NAME       RootFS-Storage (Default: auto, bevorzugt local-lvm)
  --template-store N   Template-Storage (Default: ${DEFAULT_TEMPLATE_STORE})
  --bridge NAME        Netzwerk-Bridge (Default: ${DEFAULT_BRIDGE})
  --port PORT          Web-UI-Port (Default: ${PORT})
  --auth-user USER     Basic-Auth-Benutzer (Default: tolaria)
  --auth-password PW   Basic-Auth-Passwort (Default: zufällig, wird angezeigt)
  --dns "IP [IP]"      Nameserver im Container (Default: Host-DNS, sonst 1.1.1.1/9.9.9.9)
  --ref REF            Upstream-Branch/Tag (Default: ${UPSTREAM_REF})
  --password PW        Root-Passwort des Containers (Default: zufällig)
  --ssh-key PATH       SSH Public Key in den Container übernehmen (optional)
  --force-build        Build auch bei unverändertem Upstream-Commit neu ausführen
  --debug, -x          Trace bis zur Secret-Erzeugung + maximale Fehlerkette
  --dry-run            Nur Plan/Argumente ausgeben, nichts verändern
  --help, -h           diese Hilfe

Umgebung:
  TOLARIA_PACKAGING_REF       Branch/Tag/Commit für den Packaging-Tarball (Default: main)
  TOLARIA_PACKAGING_TARBALL   Eigene Tarball-URL oder lokaler Pfad
  TOLARIA_PACKAGING_DIR       Lokaler Checkout statt Download

Nach der Installation:
  Web UI: http://<LXC-IP>:${PORT}
  Login:  siehe Ausgabe (Basic Auth)
EOF
}

# ---------------------------------------------------------------------------
# DNS-Ermittlung
# ---------------------------------------------------------------------------
# Proxmox schreibt beim Start die Host-Nameserver in /etc/resolv.conf des CT.
# Steht dort der systemd-resolved-Stub 127.0.0.53, kann der Container nichts
# auflösen. Deshalb ermitteln wir hier echte, nicht-lokale Nameserver.
detect_dns_servers() {
  local ns=""
  if [[ -n "$DNS_SERVERS" ]]; then
    printf '%s\n' "$DNS_SERVERS"
    return 0
  fi

  # systemd-resolved: echte Upstream-Server stehen in der Runtime-Datei.
  if [[ -r /run/systemd/resolve/resolv.conf ]]; then
    ns="$(awk '/^nameserver/ {print $2}' /run/systemd/resolve/resolv.conf 2>/dev/null \
      | grep -vE '^(127\.|::1$)' | head -n3 | paste -sd' ' - || true)"
  fi

  # Fallback: resolvectl (Ubuntu/Debian mit systemd-resolved).
  if [[ -z "$ns" ]] && command -v resolvectl >/dev/null 2>&1; then
    ns="$(resolvectl dns 2>/dev/null \
      | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
      | grep -vE '^127\.' | head -n3 | paste -sd' ' - || true)"
  fi

  # Fallback: /etc/resolv.conf, aber ohne Loopback-Stubs.
  if [[ -z "$ns" && -r /etc/resolv.conf ]]; then
    ns="$(awk '/^nameserver/ {print $2}' /etc/resolv.conf 2>/dev/null \
      | grep -vE '^(127\.|::1$)' | head -n3 | paste -sd' ' - || true)"
  fi

  if [[ -z "$ns" ]]; then
    ns="$FALLBACK_DNS_SERVERS"
  fi
  printf '%s\n' "$ns"
}

# ---------------------------------------------------------------------------
# Fehlerkette: Befehl, Zeile, Exit-Code, Caller, Container-Logs
# ---------------------------------------------------------------------------
on_error() {
  local exit_code="$1" lineno="$2" cmd="$3"
  set +e
  set +x
  if [[ -n "${TOLARIA_TOKEN:-}" ]]; then cmd="${cmd//"$TOLARIA_TOKEN"/<redacted>}"; fi
  if [[ -n "${AUTH_PASS:-}" ]]; then cmd="${cmd//"$AUTH_PASS"/<redacted>}"; fi
  if [[ -n "${ROOT_PASSWORD:-}" ]]; then cmd="${cmd//"$ROOT_PASSWORD"/<redacted>}"; fi
  local safe_args="$SCRIPT_ARGS"
  if [[ -n "${TOLARIA_TOKEN:-}" ]]; then safe_args="${safe_args//"$TOLARIA_TOKEN"/<redacted>}"; fi
  if [[ -n "${AUTH_PASS:-}" ]]; then safe_args="${safe_args//"$AUTH_PASS"/<redacted>}"; fi
  if [[ -n "${ROOT_PASSWORD:-}" ]]; then safe_args="${safe_args//"$ROOT_PASSWORD"/<redacted>}"; fi
  if ((${#cmd} > 2000)); then
    cmd="${cmd:0:2000}... [gekürzt, vollständiger Befehl im Log]"
  fi
  echo ""
  msg_error "════════════ INSTALLATION FEHLGESCHLAGEN ════════════"
  msg_error "Befehl    : $cmd"
  msg_error "Zeile     : $lineno"
  msg_error "Exit-Code : $exit_code"
  msg_error "Args      : $safe_args"
  msg_error "Logdatei  : $LOG_FILE (komplette stdout/stderr-Kette)"
  echo ""
  msg_error "--- Stacktrace (neuester Aufruf zuerst) ---"
  local i=0
  while caller "$i"; do ((i++)) || true; done
  echo ""
  if command -v pct >/dev/null 2>&1 && [[ -n "${CTID:-}" ]]; then
    msg_error "--- pct status ${CTID} ---"
    pct status "${CTID}" 2>&1 || true
    echo ""
    msg_error "--- pct config ${CTID} ---"
    pct config "${CTID}" 2>&1 || true
    echo ""
    if pct status "${CTID}" 2>/dev/null | grep -q running; then
      msg_error "--- DNS / Netzwerk im Container ---"
      pct exec "${CTID}" -- bash -c 'cat /etc/resolv.conf' 2>&1 || true
      pct exec "${CTID}" -- bash -c 'getent ahostsv4 deb.debian.org || echo "IPv4-Aufloesung fehlgeschlagen"' 2>&1 || true
      pct exec "${CTID}" -- bash -c 'getent ahostsv6 deb.debian.org || echo "IPv6-Aufloesung fehlgeschlagen"' 2>&1 || true
      pct exec "${CTID}" -- bash -c 'ip -4 route 2>/dev/null; ip -4 addr show dev eth0 2>/dev/null' 2>&1 || true
      pct exec "${CTID}" -- bash -c 'if [ -f /etc/dhcp/dhclient.conf ]; then grep -n "tolaria-dns\|domain-name-servers" /etc/dhcp/dhclient.conf || true; fi' 2>&1 || true
      pct exec "${CTID}" -- bash -c 'if [ -f /etc/hosts ]; then grep -A6 -F "# >>> tolaria-apt-hosts >>>" /etc/hosts || true; fi' 2>&1 || true
      pct exec "${CTID}" -- bash -c 'if [ -f /root/tolaria-apt-update.log ]; then tail -n 30 /root/tolaria-apt-update.log || true; fi' 2>&1 || true
      echo ""
      msg_error "--- systemctl status ${APP} ---"
      pct exec "${CTID}" -- systemctl status "${APP}" --no-pager --full 2>&1 || true
      echo ""
      msg_error "--- journalctl -u ${APP} (letzte 200 Zeilen) ---"
      pct exec "${CTID}" -- journalctl -u "${APP}" --no-pager -n 200 2>&1 || true
      echo ""
      msg_error "--- nginx -t ---"
      pct exec "${CTID}" -- nginx -t 2>&1 || true
      echo ""
      msg_error "--- nginx error.log (letzte 100 Zeilen) ---"
      pct exec "${CTID}" -- bash -lc 'tail -n 100 /var/log/nginx/error.log' 2>&1 || true
      echo ""
      msg_error "--- Speicher / Disk im Container ---"
      pct exec "${CTID}" -- bash -lc 'free -m; df -h / /opt /var' 2>&1 || true
      echo ""
      msg_error "--- letzter Build-Log (falls vorhanden) ---"
      pct exec "${CTID}" -- bash -lc 'test -f /root/tolaria-build.log && tail -n 200 /root/tolaria-build.log' 2>&1 || true
    fi
    msg_error "Secrets für Debugging (root-only): /root/tolaria-packaging/install.env"
  fi
  echo ""
  msg_error "Re-run mit vollem Trace:"
  msg_error "  DEBUG=1 bash tolaria.sh $SCRIPT_ARGS"
  msg_error "  oder: bash -x tolaria.sh $SCRIPT_ARGS"
  msg_error "Bitte bei Fehlermeldungen IMMER die komplette Logdatei ($LOG_FILE) mitschicken."
  exit "$exit_code"
}

# ---------------------------------------------------------------------------
# Argumente
# ---------------------------------------------------------------------------
CTID="${CT_ID:-${CTID:-}}"
STORAGE_ARG=""
TEMPLATE_STORE="$DEFAULT_TEMPLATE_STORE"
BRIDGE="$DEFAULT_BRIDGE"
ROOT_PASSWORD=""
SSH_KEY=""
HOSTNAME_EXPLICIT=0
REF="$UPSTREAM_REF"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid)            CTID="${2:?--ctid braucht einen Wert}"; shift 2 ;;
    --hostname)        HOSTNAME_ARG="${2:?--hostname braucht einen Wert}"; HOSTNAME_EXPLICIT=1; shift 2 ;;
    --cores)           DEFAULT_CORES="${2:?--cores braucht einen Wert}"; shift 2 ;;
    --memory)          DEFAULT_RAM="${2:?--memory braucht einen Wert}"; shift 2 ;;
    --swap)            DEFAULT_SWAP="${2:?--swap braucht einen Wert}"; shift 2 ;;
    --disk)            DEFAULT_DISK="${2:?--disk braucht einen Wert}"; shift 2 ;;
    --storage)         STORAGE_ARG="${2:?--storage braucht einen Wert}"; shift 2 ;;
    --template-store)  TEMPLATE_STORE="${2:?--template-store braucht einen Wert}"; shift 2 ;;
    --bridge)          BRIDGE="${2:?--bridge braucht einen Wert}"; shift 2 ;;
    --port)            PORT="${2:?--port braucht einen Wert}"; shift 2 ;;
    --auth-user)       AUTH_USER="${2:?--auth-user braucht einen Wert}"; shift 2 ;;
    --auth-password)   AUTH_PASS="${2:?--auth-password braucht einen Wert}"; shift 2 ;;
    --dns)             DNS_SERVERS="${2:?--dns braucht einen Wert}"; shift 2 ;;
    --ref)             REF="${2:?--ref braucht einen Wert}"; shift 2 ;;
    --password)        ROOT_PASSWORD="${2:?--password braucht einen Wert}"; shift 2 ;;
    --ssh-key)         SSH_KEY="${2:?--ssh-key braucht einen Wert}"; shift 2 ;;
    --force-build)     FORCE_BUILD=1; shift ;;
    --debug|-x)        DEBUG="1"; shift ;;
    --dry-run)         DRY_RUN=1; shift ;;
    --help|-h)         usage; exit 0 ;;
    *) msg_error "Unbekannte Option: $1"; usage; exit 1 ;;
  esac
done

# Werte validieren
[[ "$DEFAULT_CORES" =~ ^[1-9][0-9]*$ ]] || { msg_error "CORES muss eine positive Zahl sein."; exit 1; }
[[ "$DEFAULT_RAM" =~ ^[1-9][0-9]*$ ]] || { msg_error "RAM muss eine positive Zahl sein."; exit 1; }
[[ "$DEFAULT_SWAP" =~ ^[0-9]+$ ]] || { msg_error "SWAP muss eine Zahl sein (0 erlaubt)."; exit 1; }
[[ "$DEFAULT_DISK" =~ ^[1-9][0-9]*$ ]] || { msg_error "DISK muss eine positive Zahl sein."; exit 1; }
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT > 0 && PORT < 65536 )) || { msg_error "PORT ungültig: $PORT"; exit 1; }
[[ "$AUTH_USER" =~ ^[A-Za-z0-9._-]+$ ]] || { msg_error "AUTH_USER ungültig: $AUTH_USER"; exit 1; }
if [[ -n "$AUTH_PASS" ]]; then
  [[ "$AUTH_PASS" =~ ^[A-Za-z0-9._~@%+=:,/-]+$ ]] \
    || { msg_error "AUTH_PASS enthält nicht unterstützte Zeichen. Erlaubt: A-Z a-z 0-9 . _ ~ @ % + = : , / -"; exit 1; }
fi
[[ "$REF" =~ ^[A-Za-z0-9._/][A-Za-z0-9._/-]*$ ]] || { msg_error "REF ungültig: $REF"; exit 1; }
[[ "$PACKAGING_REF" =~ ^[A-Za-z0-9._/-]+$ ]] || { msg_error "TOLARIA_PACKAGING_REF ungültig: $PACKAGING_REF"; exit 1; }
[[ "$FORCE_BUILD" =~ ^[01]$ ]] || { msg_error "FORCE_BUILD muss 0 oder 1 sein."; exit 1; }
if [[ -n "$DNS_SERVERS" ]]; then
  read -r -a DNS_ARRAY <<< "$DNS_SERVERS"
  (( ${#DNS_ARRAY[@]} <= 3 )) || { msg_error "--dns erlaubt maximal 3 Nameserver."; exit 1; }
  for ns in "${DNS_ARRAY[@]}"; do
    [[ "$ns" =~ ^[0-9A-Fa-f:.]+$ ]] \
      || { msg_error "Ungültiger Nameserver in --dns: '$ns' (erwartet IPv4/IPv6)."; exit 1; }
  done
fi

CT_DNS="$(detect_dns_servers)"
# Erkannte Werte defensiv prüfen: pct create/set akzeptiert nur IPs.
read -r -a CT_DNS_ARRAY <<< "$CT_DNS"
CT_DNS_VALID=1
for ns in "${CT_DNS_ARRAY[@]}"; do
  [[ "$ns" =~ ^[0-9A-Fa-f:.]+$ ]] || CT_DNS_VALID=0
done
if (( ${#CT_DNS_ARRAY[@]} == 0 )) || [[ "$CT_DNS_VALID" != "1" ]]; then
  msg_warn "Ermittelte Nameserver sind unbrauchbar ('${CT_DNS}') - nutze ${FALLBACK_DNS_SERVERS}."
  CT_DNS="$FALLBACK_DNS_SERVERS"
fi

if [[ "$DRY_RUN" == "1" ]]; then
  cat <<EOF
${APP_TITLE} - Dry Run (es wird nichts verändert)

  CT-ID            : ${CTID:-<nächste freie ID via pvesh get /cluster/nextid>}
  Hostname         : ${HOSTNAME_ARG}
  Ressourcen       : ${DEFAULT_CORES} vCPU / ${DEFAULT_RAM} MB RAM / ${DEFAULT_SWAP} MB Swap / ${DEFAULT_DISK} GB Disk
  Storage          : ${STORAGE_ARG:-auto (local-lvm bevorzugt)}
  Template-Store   : ${TEMPLATE_STORE}
  Bridge           : ${BRIDGE}
  Web-UI-Port      : ${PORT}
  Tolaria-Server   : 127.0.0.1:${SERVER_PORT}
  Nameserver (CT)  : ${CT_DNS}
  Upstream         : ${UPSTREAM_REPO} @ ${REF}
  Basic-Auth-User  : ${AUTH_USER}
  Build erzwingen  : ${FORCE_BUILD}
  Installer-Repo   : ${INSTALLER_RAW}
  Installer-Version: ${INSTALLER_VERSION}
  Packaging        : ${PACKAGING_TARBALL:-Tarball ${INSTALLER_REPO_SLUG} @ ${PACKAGING_REF}}

Ablauf:
  1. Template ${DEFAULT_OS} sicherstellen
  2. LXC erstellen/wiederverwenden, onboot=1, unprivileged=${UNPRIVILEGED}
  3. DNS im CT prüfen und bei Bedarf reparieren (systemd-resolved-Stub)
  4. Node 22 + pnpm 10.33 + nginx + git im CT installieren
  5. Upstream klonen, pnpm install, pnpm build:web (übersprungen, wenn Commit unverändert)
  6. Vault /var/lib/${APP}/vault.git seeden (demo-vault-v2)
  7. tolaria.service + nginx + Basic Auth einrichten
  8. Service/HTTP/Proxy verifizieren, URL + Zugang ausgeben

Dauer: erster Lauf inkl. pnpm install und pnpm build:web 10-25 Minuten.
Hinweis: Ein echter LXC-Start ist nur auf einem Proxmox-VE-Host möglich.
EOF
  exit 0
fi

# Log ab hier mitschreiben (vollständige Kette)
exec > >(tee -i "$LOG_FILE") 2>&1
chmod 600 "$LOG_FILE" 2>/dev/null || true
msg_info "Installer-Version: ${INSTALLER_VERSION}"
msg_info "Logdatei: $LOG_FILE"
msg_info "Container-Nameserver: ${CT_DNS}"
if [[ "$DEBUG" == "1" ]]; then
  echo "--- DEBUG: set -x aktiv ---"
  set -x
fi

# Trap erst nach dem Parsen setzen, damit SCRIPT_ARGS die echten Args enthält.
# shellcheck disable=SC2064
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

# ---------------------------------------------------------------------------
# Pre-Checks (muss auf dem Proxmox-Host als root laufen)
# ---------------------------------------------------------------------------
msg_info "Prüfe Voraussetzungen (Proxmox-Host, root, Tools) ..."
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  msg_error "Bitte als root auf dem Proxmox-Host ausführen (sudo -i)."
  exit 1
fi
for bin in pct pveam pvesh pvesm wget curl openssl tar; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    msg_error "Benötigtes Tool fehlt: $bin - läuft das Skript wirklich auf einem Proxmox-VE-Host?"
    exit 1
  fi
done
if [[ "$DEFAULT_RAM" -lt 4096 ]]; then
  msg_warn "RAM=${DEFAULT_RAM} MB < 4096 MB - der TypeScript/Vite-Build kann OOMen. Empfohlen: 6144 MB."
fi
if [[ "$DEFAULT_DISK" -lt 10 ]]; then
  msg_warn "DISK=${DEFAULT_DISK} GB < 10 GB - node_modules + pnpm-Store + Build brauchen mehr."
fi
if command -v ip >/dev/null 2>&1 && ! ip link show "$BRIDGE" >/dev/null 2>&1; then
  msg_warn "Bridge '${BRIDGE}' existiert nicht auf diesem Host. Mit --bridge <name> anpassen."
fi
# Der Hinweis "Sum of all thin volume sizes exceeds ..." aus dem pct-create-Log
# ist ein echtes Risiko: ein voller Thin-Pool kann ALLE Container korrumpieren.
if command -v lvs >/dev/null 2>&1; then
  thin_full="$(LC_ALL=C lvs --noheadings -o lv_name,data_percent 2>/dev/null \
    | awk '$2 != "" && $2 + 0 >= 85 {printf "%s(%.0f%%) ", $1, $2}' || true)"
  if [[ -n "$thin_full" ]]; then
    msg_warn "Thin-Pool(s) fast voll: ${thin_full}- vor der Installation Platz schaffen (lvs/df -h prüfen)."
  fi
fi
msg_ok "Host-Checks bestanden."

# ---------------------------------------------------------------------------
# CT-ID: immer die nächste freie ID nehmen (außer explizit gesetzt)
# ---------------------------------------------------------------------------
if [[ -z "$CTID" ]]; then
  msg_info "Ermittle nächste freie CT-ID ..."
  CTID="$(pvesh get /cluster/nextid)"
  msg_ok "Nächste freie CT-ID: $CTID"
else
  msg_info "CT-ID vorgegeben: $CTID"
fi

[[ "$CTID" =~ ^[1-9][0-9]*$ ]] || { msg_error "Ungültige CT-ID: $CTID"; exit 1; }

HOSTNAME_FINAL="$HOSTNAME_ARG"
if [[ ! "$HOSTNAME_FINAL" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || (( ${#HOSTNAME_FINAL} > 63 )); then
  msg_error "Ungültiger Hostname: $HOSTNAME_FINAL (1-63 Zeichen: Buchstaben, Zahlen, Bindestrich; nicht am Rand)"
  exit 1
fi

# ---------------------------------------------------------------------------
# Storage-Erkennung
# ---------------------------------------------------------------------------
detect_storage() {
  local s
  s="$(pvesm status --content rootdir 2>/dev/null | awk 'NR>1 && /active/ {print $1}' | grep -x "local-lvm" || true)"
  if [[ -n "$s" ]]; then echo "$s"; return 0; fi
  s="$(pvesm status --content rootdir 2>/dev/null | awk 'NR>1 && /active/ {print $1}' | head -n1 || true)"
  if [[ -n "$s" ]]; then echo "$s"; return 0; fi
  echo "local-lvm"
}
if [[ -z "$STORAGE_ARG" ]]; then
  STORAGE_ARG="$(detect_storage)"
  msg_info "RootFS-Storage (auto): $STORAGE_ARG"
else
  msg_info "RootFS-Storage (vorgegeben): $STORAGE_ARG"
fi
if ! pvesm status --content rootdir 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$STORAGE_ARG"; then
  msg_error "Storage '${STORAGE_ARG}' ist unbekannt oder unterstützt kein rootdir."
  msg_error "Verfügbare Storages mit rootdir:"
  pvesm status --content rootdir 2>&1 || true
  exit 1
fi

# ---------------------------------------------------------------------------
# Template sicherstellen
# ---------------------------------------------------------------------------
msg_info "Aktualisiere Template-Liste (pveam update) ..."
pveam update >/dev/null 2>&1 || msg_warn "pveam update fehlgeschlagen - weiter mit vorhandener Liste."

msg_info "Suche neuestes ${DEFAULT_OS}-Template auf ${TEMPLATE_STORE} ..."
TEMPLATE_FILE="$(pveam available --section system 2>/dev/null \
  | grep -o "${DEFAULT_OS}[^ ]*\\.tar\\.zst" | sort -V | tail -n1 || true)"
if [[ -z "$TEMPLATE_FILE" ]]; then
  msg_error "Kein Template für ${DEFAULT_OS} gefunden. Verfügbare Debian-Templates:"
  pveam available --section system 2>&1 | grep -i debian || true
  exit 1
fi
TEMPLATE_REF="${TEMPLATE_STORE}:vztmpl/${TEMPLATE_FILE}"
msg_info "Template: $TEMPLATE_REF"
if ! pveam list "$TEMPLATE_STORE" 2>/dev/null | grep -Fq "$TEMPLATE_FILE"; then
  msg_info "Lade Template herunter (kann dauern) ..."
  pveam download "$TEMPLATE_STORE" "$TEMPLATE_FILE"
else
  msg_ok "Template bereits vorhanden - Download übersprungen (idempotent)."
fi

# ---------------------------------------------------------------------------
# Packaging-Dateien: aus Repo laden (oder lokal für Tests)
# ---------------------------------------------------------------------------
# Bewusst VOR dem Container-Start: so scheitert ein kaputter Download, bevor
# ein halbfertiger Container zurückbleibt. repair-dns.sh wird direkt danach
# gebraucht, um DNS im CT zu prüfen/reparieren.
PKG_DIR="$(mktemp -d /tmp/tolaria-packaging.XXXXXX)"
cleanup() {
  rm -rf "$PKG_DIR" 2>/dev/null || true
}
trap cleanup EXIT

PACKAGING_FILES=(
  "scripts/setup-in-container.sh"
  "scripts/inject-web-config.py"
  "scripts/seed-vault.sh"
  "scripts/repair-dns.sh"
  "scripts/apt-hosts-pin.sh"
  "scripts/apt-proxy.pl"
  "systemd/tolaria.service"
  "nginx/tolaria.conf"
)

# >>> tolaria-packaging-fetch >>>
# Cache-Buster: raw.githubusercontent.com und codeload.github.com liefern
# "main" über ein CDN. Ohne eindeutige URL kann ein Lauf noch die vorherige
# Version sehen (genau das hat den gemeldeten Fehlschlag verursacht).
cache_busted_url() {
  local url="$1"
  if [[ "$url" == *\?* ]]; then
    printf '%s&cb=%s' "$url" "$(date +%s)"
  else
    printf '%s?cb=%s' "$url" "$(date +%s)"
  fi
}

download_packaging_file() {
  local url="$1" out="$2"
  if [[ -f "$url" ]]; then
    cp -- "$url" "$out"
  elif [[ "$url" == file://* ]]; then
    cp -- "${url#file://}" "$out"
  else
    wget -q --no-cache --header='Cache-Control: no-cache' \
      -O "$out" --timeout=30 --tries=3 "$url"
  fi
}

try_packaging_tarball_url() {
  local url="$1" tar_file extract top rel tar_source

  tar_file="$PKG_DIR/.packaging.tar.gz"
  extract="$PKG_DIR/.extract"
  rm -rf "$extract" "$tar_file"
  mkdir -p "$extract"

  tar_source="$url"
  if [[ "$url" == http* ]]; then
    tar_source="$(cache_busted_url "$url")"
  fi
  if ! download_packaging_file "$tar_source" "$tar_file"; then
    return 1
  fi
  if ! tar -xzf "$tar_file" -C "$extract" 2>/dev/null; then
    return 1
  fi

  # GitHub-Tarballs haben ein Top-Level-Verzeichnis; lokale Test-Tarballs
  # eventuell nicht. Beides unterstützen.
  if [[ ! -d "$extract/scripts" ]]; then
    top="$(find "$extract" -mindepth 1 -maxdepth 1 -type d | head -n1 || true)"
    [[ -n "$top" ]] && extract="$top"
  fi

  for rel in "${PACKAGING_FILES[@]}"; do
    if [[ ! -s "$extract/$rel" ]]; then
      return 1
    fi
    cp -- "$extract/$rel" "$PKG_DIR/$(basename "$rel")"
  done
  rm -rf "$extract" "$tar_file"
  PACKAGING_SOURCE="$url"
}

fetch_packaging_tarball() {
  local ref_path

  if [[ -n "$PACKAGING_TARBALL" ]]; then
    try_packaging_tarball_url "$PACKAGING_TARBALL"
    return
  fi

  if [[ "$PACKAGING_REF" == refs/* ]]; then
    try_packaging_tarball_url "https://codeload.github.com/${INSTALLER_REPO_SLUG}/tar.gz/${PACKAGING_REF}"
    return
  fi

  # Commit-SHA: codeload akzeptiert ihn direkt.
  if [[ "$PACKAGING_REF" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
    try_packaging_tarball_url "https://codeload.github.com/${INSTALLER_REPO_SLUG}/tar.gz/${PACKAGING_REF}" \
      && return 0
  fi

  # Branch und Tag sind ohne API nicht unterscheidbar: beide probieren.
  for ref_path in "refs/heads/${PACKAGING_REF}" "refs/tags/${PACKAGING_REF}"; do
    try_packaging_tarball_url "https://codeload.github.com/${INSTALLER_REPO_SLUG}/tar.gz/${ref_path}" \
      && return 0
  done

  msg_warn "Kein Tarball für Ref '${PACKAGING_REF}' gefunden (Branch/Tag/Commit geprüft)."
  return 1
}

fetch_packaging_raw() {
  local rel url out
  for rel in "${PACKAGING_FILES[@]}"; do
    url="$(cache_busted_url "${INSTALLER_RAW}/${rel}")"
    out="$PKG_DIR/$(basename "$rel")"
    if ! download_packaging_file "$url" "$out"; then
      msg_error "Download fehlgeschlagen: $url"
      return 1
    fi
    if [[ ! -s "$out" ]]; then
      msg_error "Download ist leer: $url"
      return 1
    fi
  done
}
# <<< tolaria-packaging-fetch <<<

msg_info "Lade Packaging-Dateien ..."
if [[ -n "${TOLARIA_PACKAGING_DIR:-}" ]]; then
  for rel in "${PACKAGING_FILES[@]}"; do
    src="${TOLARIA_PACKAGING_DIR}/${rel}"
    [[ -f "$src" ]] || { msg_error "Packaging-Datei fehlt: $src"; exit 1; }
    cp -- "$src" "$PKG_DIR/$(basename "$rel")"
  done
  msg_ok "Packaging aus lokalem Verzeichnis: $TOLARIA_PACKAGING_DIR"
else
  PACKAGING_SOURCE=""
  if fetch_packaging_tarball; then
    msg_ok "Packaging als konsistenter Tarball geladen: ${PACKAGING_SOURCE}"
  else
    PACKAGING_SOURCE=""
    msg_warn "Tarball nicht verfügbar - weiche auf einzelne Raw-Dateien aus (Cache-Buster aktiv)."
    if ! fetch_packaging_raw; then
      msg_error "Packaging konnte nicht geladen werden."
      msg_error "Prüfe Internet/DNS auf dem Proxmox-Host oder setze TOLARIA_PACKAGING_DIR auf einen lokalen Checkout."
      exit 1
    fi
    msg_ok "Packaging als einzelne Raw-Dateien geladen (${INSTALLER_RAW})."
  fi
fi

# Zwei Dateien sind für den weiteren Ablauf zwingend. Ein früher, klarer
# Fehler ist besser als ein halb installierter Container.
for rel in "scripts/setup-in-container.sh" "scripts/repair-dns.sh"; do
  [[ -s "$PKG_DIR/$(basename "$rel")" ]] \
    || { msg_error "Packaging unvollständig: $rel fehlt."; exit 1; }
done
bash -n "$PKG_DIR/setup-in-container.sh" \
  || { msg_error "Packaging fehlerhaft: setup-in-container.sh hat einen Syntaxfehler."; exit 1; }

# Versions-Handshake: Host-Skript und Container-Setup müssen aus demselben
# Stand kommen. Sonst läuft z. B. ein neues Setup mit alten Erwartungen (oder
# umgekehrt), und Fehlermeldungen beziehen sich auf Code, der gar nicht aktiv ist.
setup_version="$(sed -n 's/^SETUP_VERSION="\([^"]*\)"$/\1/p' "$PKG_DIR/setup-in-container.sh" | head -n1)"
if [[ -z "$setup_version" ]]; then
  msg_error "Packaging ist zu alt (kein SETUP_VERSION-Marker)."
  msg_error "Bitte den Einzeiler mit '?cb=\$(date +%s)' neu laden."
  exit 1
fi
if [[ "$setup_version" != "$INSTALLER_VERSION" ]]; then
  msg_error "Versionskonflikt: Host-Skript ${INSTALLER_VERSION}, Packaging ${setup_version}."
  msg_error "Das ist meist ein CDN-Cache. Bitte den Einzeiler mit '?cb=\$(date +%s)' neu laden."
  exit 1
fi
msg_ok "Versionen passen: Installer/Packaging ${INSTALLER_VERSION}."

# ---------------------------------------------------------------------------
# Container erstellen (idempotent: existiert die CT-ID, wiederverwenden)
# ---------------------------------------------------------------------------
# Ab hier entstehen Secrets (Root-Passwort, Token, Basic-Auth). xtrace wird
# dauerhaft pausiert, damit --debug keine Passwörter in das Install-Log schreibt.
if [[ "$DEBUG" == "1" ]]; then
  msg_info "Debug: set -x wird vor der Secret-Erzeugung pausiert (keine Secrets im Log)."
  set +x
fi

if pct status "$CTID" >/dev/null 2>&1; then
  msg_warn "Container $CTID existiert bereits - wird wiederverwendet (idempotent, kein Neu-Erstellen)."
  EXISTING_HOST="$(pct config "$CTID" 2>/dev/null | awk '/^hostname:/ {print $2}' || true)"
  msg_info "Bestehender Hostname: ${EXISTING_HOST:-unbekannt}"
  if [[ "$HOSTNAME_EXPLICIT" == "1" && -n "$EXISTING_HOST" && "$EXISTING_HOST" != "$HOSTNAME_FINAL" ]]; then
    msg_info "Setze Hostname auf $HOSTNAME_FINAL ..."
    pct set "$CTID" --hostname "$HOSTNAME_FINAL"
  elif [[ "$HOSTNAME_EXPLICIT" == "0" && -n "$EXISTING_HOST" && "$EXISTING_HOST" != "$HOSTNAME_FINAL" ]]; then
    msg_warn "CT heißt '${EXISTING_HOST}', nicht '${HOSTNAME_FINAL}'. Name bleibt erhalten; mit --hostname änderbar."
  fi
  pct set "$CTID" --onboot 1
else
  if [[ -z "$ROOT_PASSWORD" ]]; then
    ROOT_PASSWORD="$(openssl rand -hex 12)"
  fi
  if [[ -n "$SSH_KEY" && ! -f "$SSH_KEY" ]]; then
    msg_error "SSH-Key nicht gefunden: $SSH_KEY"
    exit 1
  fi
  msg_info "Erstelle LXC $CTID (hostname=${HOSTNAME_FINAL}, cores=${DEFAULT_CORES}, ram=${DEFAULT_RAM}MB, disk=${DEFAULT_DISK}G) ..."
  CREATE_ARGS=(
    "$CTID" "$TEMPLATE_REF"
    --hostname "$HOSTNAME_FINAL"
    --cores "$DEFAULT_CORES"
    --memory "$DEFAULT_RAM"
    --swap "$DEFAULT_SWAP"
    --rootfs "${STORAGE_ARG}:${DEFAULT_DISK}"
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp"
    --ostype debian
    --unprivileged "$UNPRIVILEGED"
    --nameserver "$CT_DNS"
    --onboot 1
    --start 0
    --password "$ROOT_PASSWORD"
  )
  if [[ -n "$FEATURES" ]]; then
    CREATE_ARGS+=(--features "$FEATURES")
  fi
  if [[ -n "$SSH_KEY" ]]; then
    CREATE_ARGS+=(--ssh-public-keys "$SSH_KEY")
  fi
  pct create "${CREATE_ARGS[@]}"
  msg_ok "Container $CTID erstellt (Name: $HOSTNAME_FINAL, onboot=1, unprivileged=$UNPRIVILEGED)."
fi

msg_info "Starte Container $CTID ..."
if [[ "$(pct status "$CTID" 2>/dev/null | awk '{print $2}')" != "running" ]]; then
  pct start "$CTID"
fi
for i in $(seq 1 60); do
  if pct exec "$CTID" -- true >/dev/null 2>&1; then break; fi
  sleep 2
  if [[ "$i" -eq 60 ]]; then
    msg_error "Container $CTID reagiert nicht auf 'pct exec'."
    exit 1
  fi
done
msg_ok "Container $CTID läuft."

msg_info "Warte auf das Container-Netzwerk (Default-Route) ..."
network_ok=0
for i in $(seq 1 30); do
  if pct exec "$CTID" -- ip -4 route 2>/dev/null | grep -q '^default'; then
    network_ok=1
    break
  fi
  sleep 2
done
if [[ "$network_ok" == "1" ]]; then
  msg_ok "Container-Netzwerk ist bereit."
else
  msg_warn "Keine Default-Route nach 60 s sichtbar - prüfe Bridge/DHCP (pct config ${CTID}, ip addr)."
fi

# ---------------------------------------------------------------------------
# DNS im Container: prüfen und bei Bedarf reparieren
# ---------------------------------------------------------------------------
# Genau hier ist der häufigste Installationsfehler: Der CT hat eine Route,
# aber /etc/resolv.conf zeigt (via Proxmox übernommen) auf 127.0.0.53.
# Ohne diesen Schritt scheitert apt-get mit "Temporary failure resolving".
msg_info "Prüfe DNS-Auflösung im Container ..."
pct push "$CTID" "$PKG_DIR/repair-dns.sh" /root/tolaria-repair-dns.sh
pct exec "$CTID" -- chmod 755 /root/tolaria-repair-dns.sh

dns_was_broken=0
if ! pct exec "$CTID" -- getent ahostsv4 deb.debian.org >/dev/null 2>&1; then
  dns_was_broken=1
fi

if ! pct exec "$CTID" -- bash /root/tolaria-repair-dns.sh --servers "$CT_DNS" --persist-dhclient; then
  msg_error "DNS-Auflösung im Container funktioniert nicht - Installation abgebrochen."
  msg_error "Aktuelle /etc/resolv.conf im Container:"
  pct exec "$CTID" -- cat /etc/resolv.conf 2>&1 || true
  msg_error ""
  msg_error "Manuelle Reparatur auf dem Proxmox-Host:"
  msg_error "  pct set ${CTID} --nameserver \"${CT_DNS}\""
  msg_error "  pct exec ${CTID} -- bash -c 'printf \"nameserver ${CT_DNS%% *}\\n\" > /etc/resolv.conf'"
  msg_error "  pct reboot ${CTID}"
  msg_error "Wichtig: apt braucht IPv4/A-Records; reine AAAA-Antworten genügen nicht."
  msg_error "Falls das LAN keinen öffentlichen DNS erlaubt: --dns \"<LAN-DNS>\" verwenden."
  exit 1
fi

# Nameserver dauerhaft in der CT-Config hinterlegen, damit ein Reboot des
# Containers die reparierte /etc/resolv.conf nicht wieder überschreibt.
# Das gilt auch dann, wenn DNS im Moment funktioniert: Ein späterer
# DHCP-Lease kann die Datei erneut mit unbrauchbaren Servern füllen.
# Wichtig: repair-dns.sh kann auf den Fallback ausgewichen sein. Deshalb
# werden die Nameserver aus der jetzt funktionierenden /etc/resolv.conf
# gelesen und nicht blind die ursprünglich ermittelten $CT_DNS gesetzt.
msg_info "Hinterlege Nameserver dauerhaft in der CT-Config ..."
CT_DNS_EFFECTIVE="$(pct exec "$CTID" -- awk '/^nameserver[[:space:]]/ {printf "%s ", $2}' /etc/resolv.conf 2>/dev/null \
  | tr -d '\r\n' | sed 's/[[:space:]]*$//')"
if [[ -z "$CT_DNS_EFFECTIVE" ]]; then
  msg_warn "Konnte Nameserver nicht aus dem Container lesen - nutze '${CT_DNS}'."
  CT_DNS_EFFECTIVE="$CT_DNS"
fi
if [[ "$CT_DNS_EFFECTIVE" != "$CT_DNS" ]]; then
  msg_warn "Im Container aktiv: '${CT_DNS_EFFECTIVE}' (angefragt: '${CT_DNS}')."
fi
if pct set "$CTID" --nameserver "$CT_DNS_EFFECTIVE"; then
  CT_DNS="$CT_DNS_EFFECTIVE"
  if [[ "$dns_was_broken" == "1" ]]; then
    msg_ok "DNS repariert (Nameserver: ${CT_DNS})."
  else
    msg_ok "DNS im Container war in Ordnung und ist dauerhaft hinterlegt (${CT_DNS})."
  fi
else
  msg_warn "pct set --nameserver fehlgeschlagen - /etc/resolv.conf bleibt bis zum nächsten Start repariert."
  msg_warn "Manuell: pct set ${CTID} --nameserver \"${CT_DNS_EFFECTIVE}\""
fi

# ---------------------------------------------------------------------------
# Secrets: bei Re-Run bestehende übernehmen, sonst neu erzeugen
# ---------------------------------------------------------------------------
read_existing_token() {
  pct exec "$CTID" -- bash -c \
    'if [ -f /etc/tolaria/tolaria.env ]; then . /etc/tolaria/tolaria.env; printf "%s" "${TOLARIA_SERVER_TOKEN:-}"; fi' \
    2>/dev/null || true
}
read_existing_auth_user() {
  pct exec "$CTID" -- bash -c \
    'if [ -f /root/tolaria-credentials.txt ]; then sed -n "s/^USER=//p" /root/tolaria-credentials.txt | head -n1; fi' \
    2>/dev/null || true
}
read_existing_auth_pass() {
  pct exec "$CTID" -- bash -c \
    'if [ -f /root/tolaria-credentials.txt ]; then sed -n "s/^PASSWORD=//p" /root/tolaria-credentials.txt | head -n1; fi' \
    2>/dev/null || true
}

TOLARIA_TOKEN="$(read_existing_token | tr -d '\r\n')"
if [[ -z "$TOLARIA_TOKEN" ]]; then
  TOLARIA_TOKEN="$(openssl rand -hex 32)"
  msg_info "Neuer Tolaria-Server-Token erzeugt (32 Byte)."
else
  msg_ok "Bestehender Tolaria-Server-Token wird wiederverwendet."
fi
[[ "$TOLARIA_TOKEN" =~ ^[A-Za-z0-9._~+/=-]+$ ]] \
  || { msg_error "Der Tolaria-Token enthält nicht unterstützte Zeichen (erwartet: A-Z a-z 0-9 . _ ~ + / = -)."; exit 1; }
(( ${#TOLARIA_TOKEN} >= 16 )) \
  || { msg_error "Der Tolaria-Token ist kürzer als 16 Zeichen."; exit 1; }

if [[ "$AUTH_USER" == "tolaria" ]]; then
  EXISTING_AUTH_USER="$(read_existing_auth_user | tr -d '\r\n')"
  if [[ -n "$EXISTING_AUTH_USER" ]]; then AUTH_USER="$EXISTING_AUTH_USER"; fi
fi
if [[ -z "$AUTH_PASS" ]]; then
  AUTH_PASS="$(read_existing_auth_pass | tr -d '\r\n')"
fi
if [[ -z "$AUTH_PASS" ]]; then
  AUTH_PASS="$(openssl rand -hex 16)"
  msg_info "Neues Basic-Auth-Passwort erzeugt."
else
  msg_ok "Bestehendes Basic-Auth-Passwort wird wiederverwendet."
fi

# Auch übernommene Werte müssen die Setup-Validierung bestehen.
[[ "$AUTH_USER" =~ ^[A-Za-z0-9._-]+$ ]] \
  || { msg_error "Der Basic-Auth-Benutzer enthält nicht unterstützte Zeichen: $AUTH_USER"; exit 1; }
[[ "$AUTH_PASS" =~ ^[A-Za-z0-9._~@%+=:,/-]+$ ]] \
  || { msg_error "Das Basic-Auth-Passwort enthält nicht unterstützte Zeichen. Erlaubt: A-Z a-z 0-9 . _ ~ @ % + = : , / -"; exit 1; }

# ---------------------------------------------------------------------------
# Installationsvariablen (Packaging wurde bereits vor dem CT-Start geladen)
# ---------------------------------------------------------------------------
[[ -n "${PKG_DIR:-}" && -d "$PKG_DIR" ]] \
  || { msg_error "Packaging-Verzeichnis fehlt (interner Fehler)."; exit 1; }

INSTALL_ENV="$PKG_DIR/install.env"
{
  printf 'CTID=%q\n' "$CTID"
  printf 'APP=%q\n' "$APP"
  printf 'PORT=%q\n' "$PORT"
  printf 'SERVER_PORT=%q\n' "$SERVER_PORT"
  printf 'UPSTREAM_REPO=%q\n' "$UPSTREAM_REPO"
  printf 'UPSTREAM_REF=%q\n' "$REF"
  printf 'TOLARIA_TOKEN=%q\n' "$TOLARIA_TOKEN"
  printf 'AUTH_USER=%q\n' "$AUTH_USER"
  printf 'AUTH_PASS=%q\n' "$AUTH_PASS"
  printf 'TOLARIA_DNS_SERVERS=%q\n' "$CT_DNS"
  printf 'FORCE_BUILD=%q\n' "$FORCE_BUILD"
} > "$INSTALL_ENV"
chmod 600 "$INSTALL_ENV"

msg_info "Kopiere Packaging + Installationsvariablen in den Container ..."
pct exec "$CTID" -- mkdir -p /root/tolaria-packaging
for rel in "${PACKAGING_FILES[@]}"; do
  base="$(basename "$rel")"
  pct push "$CTID" "$PKG_DIR/$base" "/root/tolaria-packaging/$base"
done
pct exec "$CTID" -- chmod 755 /root/tolaria-packaging/repair-dns.sh /root/tolaria-packaging/apt-hosts-pin.sh
pct exec "$CTID" -- chmod 700 /root/tolaria-packaging/setup-in-container.sh /root/tolaria-packaging/seed-vault.sh
pct push "$CTID" "$INSTALL_ENV" "/root/tolaria-packaging/install.env"
pct exec "$CTID" -- chmod 600 /root/tolaria-packaging/install.env
msg_ok "Packaging im Container: /root/tolaria-packaging"

# ---------------------------------------------------------------------------
# Installation IM Container
# ---------------------------------------------------------------------------
msg_info "Installiere ${APP_TITLE} im Container (Node-Build, Vault, systemd, nginx) ..."
msg_info "Erster Lauf: 10-25 Minuten. Bei unverändertem Upstream-Commit wird der Build übersprungen. Build-Log: /root/tolaria-build.log (im CT)."
pct exec "$CTID" -- bash /root/tolaria-packaging/setup-in-container.sh

# install.env enthält Secrets und wird nach Erfolg entfernt.
pct exec "$CTID" -- rm -f /root/tolaria-packaging/install.env

# ---------------------------------------------------------------------------
# Verifikation vom Host aus
# ---------------------------------------------------------------------------
msg_info "Verifiziere Service und Web-UI ..."
for i in $(seq 1 60); do
  if pct exec "$CTID" -- systemctl is-active --quiet "$APP" 2>/dev/null \
     && pct exec "$CTID" -- curl -fsS "http://127.0.0.1:${SERVER_PORT}/healthz" >/dev/null 2>&1 \
     && pct exec "$CTID" -- curl -fsS -u "${AUTH_USER}:${AUTH_PASS}" "http://127.0.0.1:${PORT}/" >/dev/null 2>&1; then
    break
  fi
  sleep 2
  if [[ "$i" -eq 60 ]]; then
    msg_error "Verifikation nach 120 s fehlgeschlagen."
    exit 1
  fi
done
pct exec "$CTID" -- curl -fsS -u "${AUTH_USER}:${AUTH_PASS}" \
  "http://127.0.0.1:${PORT}/tolaria-config.js" >/dev/null
pct exec "$CTID" -- curl -fsS -H "Authorization: Bearer ${TOLARIA_TOKEN}" \
  "http://127.0.0.1:${PORT}/v1/vault" >/dev/null
msg_ok "Service läuft (systemctl is-active ${APP} = active)."
msg_ok "Web UI antwortet (HTTP 200 auf localhost:${PORT})."
msg_ok "Config-JS ist Basic-Auth-geschützt und erreichbar."
msg_ok "API-Proxy antwortet (GET /v1/vault mit Bearer-Token über nginx)."

# Container-IP ermitteln
CONTAINER_IP="$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}')"
if [[ -z "$CONTAINER_IP" ]]; then
  CONTAINER_IP="$(pct exec "$CTID" -- bash -lc "ip -4 -o addr show dev eth0 | awk '{print \$4}' | cut -d/ -f1 | head -n1" 2>/dev/null || true)"
fi
if [[ -z "$CONTAINER_IP" ]]; then
  CONTAINER_IP="<LXC-IP>"
  msg_warn "Container-IP konnte nicht ermittelt werden."
fi

# ---------------------------------------------------------------------------
# Abschluss
# ---------------------------------------------------------------------------
echo ""
cat <<EOF
════════════════ INSTALLATION ERFOLGREICH ════════════════
  App          : ${APP_TITLE} - lokale Markdown-Wissensbasis
  Container    : CT ${CTID} (Hostname: ${HOSTNAME_FINAL}, unprivilegiert, onboot=1)
  Ressourcen   : ${DEFAULT_CORES} vCPU / ${DEFAULT_RAM} MB RAM / ${DEFAULT_SWAP} MB Swap / ${DEFAULT_DISK} GB Disk
  Web UI       : http://${CONTAINER_IP}:${PORT}
  Login        : Benutzer: ${AUTH_USER}
                 Passwort: ${AUTH_PASS}
  Health       : http://${CONTAINER_IP}:${PORT}/healthz
  Vault        : /var/lib/${APP}/vault.git (im CT)
  App-Code     : /opt/${APP}/src (im CT)
  Secrets      : /etc/${APP}/${APP}.env (Server-Token, root-only)
  Web-Config   : /tolaria-config.js (Basic-Auth-geschützt, enthält den API-Token)
  Log          : ${LOG_FILE}
  Update       : Einzeiler erneut ausführen (CT ${CTID} wird wiederverwendet)
  Reboot-Test  : bash tests/reboot-check.sh ${CTID} ${PORT}
  Deinstall    : pct stop ${CTID} && pct destroy ${CTID}   (Vault vorher sichern!)
══════════════════════════════════════════════════════════
EOF
