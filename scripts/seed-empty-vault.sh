#!/usr/bin/env bash
#
# Seedet einen leeren Tolaria-Vault mit der kanonischen Minimal-Struktur:
# nur Typdefinitionen und .gitignore, keine Notizen.
#
# Usage:
#   seed-empty-vault.sh [VAULT_DIR]
#
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
VAULT_DIR="${1:-/var/lib/tolaria/vault.git}"

msg_info()  { echo "[INFO]  $*"; }
msg_error() { echo "[ERROR] $*" >&2; }

TMP_SEED="$(mktemp -d /tmp/tolaria-empty-seed.XXXXXX)"
cleanup() { rm -rf "$TMP_SEED"; }
trap cleanup EXIT

msg_info "Erzeuge leeren Seed (Typdefinitionen, keine Notizen) ..."

cat > "$TMP_SEED/.gitignore" <<'EOF'
# Tolaria app files (machine-specific, never commit)
.laputa/settings.json

# macOS
.DS_Store
.AppleDouble
.LSOverride

# Thumbnails
._*

# Editors
.vscode/
.idea/
*.swp
*.swo
EOF

cat > "$TMP_SEED/type.md" <<'EOF'
---
type: Type
order: 0
visible: false
---

# Type

A Type defines shared metadata and defaults for a category of notes in this vault.

## Common properties
- **Icon**: Sidebar icon for this type
- **Color**: Accent color for notes of this type
- **Order**: Sidebar ordering
- **Sidebar label**: Override the default plural label
- **Template**: Default body for new notes of this type
- **View**: Preferred note-list view for this type
EOF

cat > "$TMP_SEED/note.md" <<'EOF'
---
type: Type
---

# Note

A Note is a general-purpose document — research notes, meeting notes, strategy docs, or anything that doesn't fit a more specific type.
EOF

[[ -s "$TMP_SEED/type.md" && -s "$TMP_SEED/note.md" && -s "$TMP_SEED/.gitignore" ]] \
  || { msg_error "Leerer Seed konnte nicht erzeugt werden: ${TMP_SEED}"; exit 1; }

bash "${SCRIPT_DIR}/seed-vault.sh" "$VAULT_DIR" "$TMP_SEED"
