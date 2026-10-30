#!/usr/bin/env bash
#
# Reboot-/Persistenz-Test für den Tolaria-LXC.
# MUSS auf dem Proxmox-Host laufen (pct erforderlich).
#
# Usage:
#   bash tests/reboot-check.sh <CTID> [PORT]
#
# Getestet wird:
#   - onboot=1 und tolaria.service enabled
#   - Container-Reboot, Service kommt automatisch wieder
#   - Web-UI, /healthz, /tolaria-config.js und /v1/vault nach dem Reboot
#   - Vault-Commit und Server-Daten überleben den Reboot
#
# Hinweis: Das ist ein Container-Reboot, kein Host-Reboot. onboot=1 wird
# geprüft, aber ein echter Proxmox-Host-Neustart muss manuell verifiziert
# werden (dabei startet der Container automatisch).
#
set -euo pipefail

CTID="${1:-}"
PORT="${2:-8080}"

PASS=0
FAIL=0
pass() { echo "[PASS] $*"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $*" >&2; FAIL=$((FAIL + 1)); }
info() { echo "[INFO] $*"; }

if [[ -z "$CTID" ]]; then
  echo "Usage: bash $0 <CTID> [PORT]" >&2
  exit 2
fi
if ! command -v pct >/dev/null 2>&1; then
  echo "pct nicht gefunden - bitte auf dem Proxmox-Host ausführen." >&2
  exit 2
fi
if ! pct status "$CTID" >/dev/null 2>&1; then
  echo "Container $CTID existiert nicht." >&2
  exit 2
fi

info "Tolaria Reboot-Check für CT ${CTID} (Port ${PORT})"
echo ""

ONBOOT="$(pct config "$CTID" | awk '/^onboot:/ {print $2}')"
if [[ "$ONBOOT" == "1" ]]; then pass "onboot=1"; else fail "onboot=${ONBOOT:-<unset>} (erwartet 1)"; fi

ENABLED="$(pct exec "$CTID" -- systemctl is-enabled tolaria 2>/dev/null || true)"
if [[ "$ENABLED" == "enabled" ]]; then pass "tolaria.service ist enabled"; else fail "tolaria.service ist '${ENABLED}' (erwartet enabled)"; fi

if pct exec "$CTID" -- systemctl is-active --quiet tolaria; then
  pass "tolaria.service läuft vor dem Reboot"
else
  fail "tolaria.service läuft vor dem Reboot nicht"
fi

HEAD_BEFORE="$(pct exec "$CTID" -- git --git-dir=/var/lib/tolaria/vault.git rev-parse HEAD 2>/dev/null || true)"
if [[ -n "$HEAD_BEFORE" ]]; then pass "Vault-HEAD vor Reboot: ${HEAD_BEFORE:0:12}"; else fail "Vault-HEAD vor Reboot nicht lesbar"; fi

info "Reboote Container ${CTID} ..."
pct reboot "$CTID"

info "Warte auf Container und Service (max. 180 s) ..."
UP=0
for _ in $(seq 1 90); do
  if pct exec "$CTID" -- true >/dev/null 2>&1; then UP=1; break; fi
  sleep 2
done
if [[ "$UP" == "1" ]]; then pass "Container ist nach Reboot erreichbar"; else fail "Container nach Reboot nicht erreichbar"; fi

ACTIVE=0
for _ in $(seq 1 90); do
  if pct exec "$CTID" -- systemctl is-active --quiet tolaria 2>/dev/null; then ACTIVE=1; break; fi
  sleep 2
done
if [[ "$ACTIVE" == "1" ]]; then pass "tolaria.service ist nach Reboot aktiv"; else fail "tolaria.service nach Reboot nicht aktiv"; fi

if pct exec "$CTID" -- nginx -t >/dev/null 2>&1; then pass "nginx -t nach Reboot"; else fail "nginx -t nach Reboot"; fi

IP="$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}')"
[[ -n "$IP" ]] || IP="$(pct exec "$CTID" -- bash -lc "ip -4 -o addr show dev eth0 | awk '{print \$4}' | cut -d/ -f1 | head -n1" 2>/dev/null || true)"
if [[ -n "$IP" ]]; then pass "Container-IP: ${IP}"; else fail "Container-IP nicht ermittelbar"; fi

if [[ -n "$IP" ]]; then
  if curl -fsS --max-time 10 "http://${IP}:${PORT}/healthz" | grep -q '^ok'; then
    pass "GET /healthz nach Reboot"
  else
    fail "GET /healthz nach Reboot"
  fi

  CREDS="$(pct exec "$CTID" -- cat /root/tolaria-credentials.txt 2>/dev/null || true)"
  AUTH_USER="$(sed -n 's/^USER=//p' <<<"$CREDS" | head -n1)"
  AUTH_PASS="$(sed -n 's/^PASSWORD=//p' <<<"$CREDS" | head -n1)"
  if [[ -n "$AUTH_USER" && -n "$AUTH_PASS" ]]; then
    if curl -fsS --max-time 10 -u "${AUTH_USER}:${AUTH_PASS}" "http://${IP}:${PORT}/" >/dev/null; then
      pass "Web-UI mit Basic Auth nach Reboot"
    else
      fail "Web-UI mit Basic Auth nach Reboot"
    fi
    if curl -fsS --max-time 10 -u "${AUTH_USER}:${AUTH_PASS}" "http://${IP}:${PORT}/tolaria-config.js" | grep -q 'TOLARIA_REMOTE_TOKEN'; then
      pass "/tolaria-config.js nach Reboot"
    else
      fail "/tolaria-config.js nach Reboot"
    fi
  else
    fail "Basic-Auth-Zugangsdaten nicht lesbar (/root/tolaria-credentials.txt)"
  fi

  TOKEN="$(pct exec "$CTID" -- bash -lc 'sed -n "s/^TOLARIA_SERVER_TOKEN=//p" /etc/tolaria/tolaria.env | head -n1' 2>/dev/null || true)"
  if [[ -n "$TOKEN" ]]; then
    if curl -fsS --max-time 10 -H "Authorization: Bearer ${TOKEN}" "http://${IP}:${PORT}/v1/vault" >/dev/null; then
      pass "GET /v1/vault mit Bearer-Token nach Reboot"
    else
      fail "GET /v1/vault mit Bearer-Token nach Reboot"
    fi
  else
    fail "Server-Token nicht lesbar (/etc/tolaria/tolaria.env)"
  fi
fi

HEAD_AFTER="$(pct exec "$CTID" -- git --git-dir=/var/lib/tolaria/vault.git rev-parse HEAD 2>/dev/null || true)"
if [[ -n "$HEAD_AFTER" && "$HEAD_AFTER" == "$HEAD_BEFORE" ]]; then
  pass "Vault-HEAD unverändert nach Reboot (${HEAD_AFTER:0:12})"
else
  fail "Vault-HEAD nach Reboot: ${HEAD_AFTER:-<unlesbar>} (vorher ${HEAD_BEFORE:-<unlesbar>})"
fi

if pct exec "$CTID" -- test -d /var/lib/tolaria/data/vault/.git; then
  pass "Server-Datenverzeichnis /var/lib/tolaria/data/vault existiert"
else
  fail "Server-Datenverzeichnis /var/lib/tolaria/data/vault fehlt"
fi

echo ""
echo "== Ergebnis: PASS=${PASS} FAIL=${FAIL} =="
if [[ "$FAIL" -ne 0 ]]; then
  echo ""
  echo "--- Diagnose ---" >&2
  pct status "$CTID" >&2 || true
  pct exec "$CTID" -- systemctl status tolaria --no-pager --full >&2 || true
  pct exec "$CTID" -- journalctl -u tolaria --no-pager -n 100 >&2 || true
  exit 1
fi

echo "Hinweis: Ein echter Proxmox-Host-Neustart wurde NICHT ausgeführt."
echo "Der Container hat onboot=1 und sollte nach einem Host-Reboot automatisch starten."
