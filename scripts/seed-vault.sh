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

# Ein geerbtes GIT_DIR/GIT_WORK_TREE würde alle "git -C $TMP_DIR"-Aufrufe
# auf ein fremdes Repository umbiegen und mit "fatal: not in a git directory"
# scheitern. Das Seeding braucht eine saubere Git-Umgebung.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
      GIT_COMMON_DIR GIT_NAMESPACE GIT_CEILING_DIRECTORIES

VAULT_DIR="${1:-/var/lib/tolaria/vault.git}"
SEED_DIR="${2:-/opt/tolaria/src/demo-vault-v2}"
VAULT_OWNER="${VAULT_OWNER:-tolaria}"
VAULT_GROUP="${VAULT_GROUP:-$VAULT_OWNER}"

msg_info()  { echo "[INFO]  $*"; }
msg_ok()    { echo "[OK]    $*"; }
msg_warn()  { echo "[WARN]  $*"; }
msg_error() { echo "[ERROR] $*" >&2; }

trap 'msg_error "seed-vault: fehlgeschlagen in Zeile ${LINENO}: ${BASH_COMMAND}"; exit 1' ERR

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

git init -q "$TMP_DIR"
if [[ ! -d "$TMP_DIR/.git" ]]; then
  msg_error "git init hat kein Repository in ${TMP_DIR} erzeugt."
  msg_error "git: $(git --version 2>&1 || true)"
  msg_error "GIT_DIR='${GIT_DIR:-<unset>}' GIT_WORK_TREE='${GIT_WORK_TREE:-<unset>}'"
  ls -la "$TMP_DIR" 2>&1 | head -10 || true
  exit 1
fi

# Explizite Pfade statt "git -C": Damit kann ein geerbtes GIT_DIR oder ein
# merkwürdiges cwd das Seeding nicht mehr auf ein fremdes Repo umbiegen.
GIT_WT=(--git-dir="$TMP_DIR/.git" --work-tree="$TMP_DIR")
git "${GIT_WT[@]}" config user.name "Tolaria"
git "${GIT_WT[@]}" config user.email "tolaria@localhost"
git "${GIT_WT[@]}" config core.autocrlf false
git "${GIT_WT[@]}" add -A

if git "${GIT_WT[@]}" diff --cached --quiet; then
  msg_error "Seed-Inhalt ergibt keinen Commit (alles ignoriert/leer?): $SEED_DIR"
  exit 1
fi

git "${GIT_WT[@]}" commit -q -m "Initial Tolaria vault"
git "${GIT_WT[@]}" branch -M main
git "${GIT_WT[@]}" remote add origin "$VAULT_DIR"
git "${GIT_WT[@]}" push -q origin main

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  if id -u "$VAULT_OWNER" >/dev/null 2>&1; then
    chown -R "$VAULT_OWNER:$VAULT_GROUP" "$VAULT_DIR"
  else
    msg_warn "Benutzer $VAULT_OWNER existiert nicht - chown übersprungen."
  fi
fi

HEAD_SHORT="$(git --git-dir="$VAULT_DIR" rev-parse --short HEAD)"
msg_ok "Vault geseedet: ${VAULT_DIR} (${HEAD_SHORT}, Branch main)"
