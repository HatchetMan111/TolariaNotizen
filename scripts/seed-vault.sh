#!/usr/bin/env bash
#
# Seedet einen leeren bare Git-Vault mit demo-vault-v2.
# Idempotent: existiert bereits ein HEAD, wird nichts angefasst.
#
# Usage:
#   seed-vault.sh [VAULT_DIR] [SEED_DIR]
#
set -euo pipefail
umask 077

VAULT_DIR="${1:-/var/lib/tolaria/vault.git}"
SEED_DIR="${2:-/opt/tolaria/src/demo-vault-v2}"
VAULT_OWNER="${VAULT_OWNER:-tolaria}"
VAULT_GROUP="${VAULT_GROUP:-$VAULT_OWNER}"

msg_info()  { echo "[INFO]  $*"; }
msg_ok()    { echo "[OK]    $*"; }
msg_warn()  { echo "[WARN]  $*"; }
msg_error() { echo "[ERROR] $*" >&2; }

[[ -d "$SEED_DIR" ]] || { msg_error "Seed-Verzeichnis fehlt: $SEED_DIR"; exit 1; }
[[ -n "$(find "$SEED_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
  || { msg_error "Seed-Verzeichnis ist leer: $SEED_DIR"; exit 1; }

if [[ -e "$VAULT_DIR" ]]; then
  if ! git --git-dir="$VAULT_DIR" rev-parse --is-bare-repository >/dev/null 2>&1; then
    msg_error "$VAULT_DIR existiert, ist aber kein bare Git-Repository. Nichts wird überschrieben."
    exit 1
  fi
  if git --git-dir="$VAULT_DIR" rev-parse --verify HEAD >/dev/null 2>&1; then
    if [[ "${EUID:-$(id -u)}" -eq 0 ]] && id -u "$VAULT_OWNER" >/dev/null 2>&1; then
      chown -R "$VAULT_OWNER:$VAULT_GROUP" "$VAULT_DIR"
    fi
    msg_ok "Vault ist bereits geseedet - übersprungen (idempotent)."
    exit 0
  fi
  msg_info "Leeres bare Repository gefunden - seede es."
else
  msg_info "Erzeuge bare Repository: $VAULT_DIR"
  install -d -m 750 "$(dirname "$VAULT_DIR")"
  git -c init.defaultBranch=main init --bare "$VAULT_DIR" >/dev/null
fi

git --git-dir="$VAULT_DIR" symbolic-ref HEAD refs/heads/main

TMP_DIR="$(mktemp -d /tmp/tolaria-seed.XXXXXX)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

msg_info "Kopiere Seed-Inhalt und erzeuge Initial-Commit ..."
cp -a "$SEED_DIR/." "$TMP_DIR/"
rm -rf "$TMP_DIR/.git"

git -C "$TMP_DIR" init -q
git -C "$TMP_DIR" config user.name "Tolaria"
git -C "$TMP_DIR" config user.email "tolaria@localhost"
git -C "$TMP_DIR" config core.autocrlf false
git -C "$TMP_DIR" add -A

if git -C "$TMP_DIR" diff --cached --quiet; then
  msg_error "Seed-Inhalt ergibt keinen Commit (alles ignoriert/leer?): $SEED_DIR"
  exit 1
fi

git -C "$TMP_DIR" commit -q -m "Initial Tolaria vault"
git -C "$TMP_DIR" branch -M main
git -C "$TMP_DIR" remote add origin "$VAULT_DIR"
git -C "$TMP_DIR" push -q origin main

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  if id -u "$VAULT_OWNER" >/dev/null 2>&1; then
    chown -R "$VAULT_OWNER:$VAULT_GROUP" "$VAULT_DIR"
  else
    msg_warn "Benutzer $VAULT_OWNER existiert nicht - chown übersprungen."
  fi
fi

HEAD_SHORT="$(git --git-dir="$VAULT_DIR" rev-parse --short HEAD)"
msg_ok "Vault geseedet: ${VAULT_DIR} (${HEAD_SHORT}, Branch main)"
