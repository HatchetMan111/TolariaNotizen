#!/usr/bin/env bash
#
# Lokale statische Tests, die KEINEN Proxmox-Host brauchen.
# Prüft Syntax, Shellcheck, HTML-Injection und Vault-Seeding.
#
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d /tmp/tolaria-static.XXXXXX)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

PASS=0
FAIL=0

pass() { echo "[PASS] $*"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $*" >&2; FAIL=$((FAIL + 1)); }

run() {
  local name="$1"; shift
  if "$@"; then pass "$name"; else fail "$name"; fi
}

echo "== Bash-Syntax =="
while IFS= read -r -d '' script; do
  rel="${script#"$REPO_ROOT"/}"
  run "bash -n ${rel}" bash -n "$script"
done < <(find "$REPO_ROOT" -type f -name '*.sh' -print0)

echo ""
echo "== Shellcheck =="
if command -v shellcheck >/dev/null 2>&1; then
  while IFS= read -r -d '' script; do
    rel="${script#"$REPO_ROOT"/}"
    run "shellcheck ${rel}" shellcheck -x -S warning "$script"
  done < <(find "$REPO_ROOT" -type f -name '*.sh' -print0)
else
  echo "[SKIP] shellcheck nicht installiert"
fi

echo ""
echo "== Python-Syntax =="
run "py_compile inject-web-config.py" \
  python3 -m py_compile "$REPO_ROOT/scripts/inject-web-config.py"

echo ""
echo "== HTML-Injection (idempotent) =="
DIST="$TMP_DIR/dist"
mkdir -p "$DIST/apps/web"
cat > "$DIST/index.html" <<'HTML'
<!doctype html>
<html><head><title>Tolaria</title></head><body><div id="root"></div></body></html>
HTML
cat > "$DIST/apps/web/collab.html" <<'HTML'
<!doctype html>
<html><body><div id="root"></div></body></html>
HTML
run "inject erstes Mal" python3 "$REPO_ROOT/scripts/inject-web-config.py" "$DIST"
run "inject zweites Mal" python3 "$REPO_ROOT/scripts/inject-web-config.py" "$DIST"
run "inject --check" python3 "$REPO_ROOT/scripts/inject-web-config.py" --check "$DIST"
for f in "$DIST/index.html" "$DIST/apps/web/collab.html"; do
  count="$(grep -c 'src="/tolaria-config.js"' "$f" || true)"
  if [[ "$count" == "1" ]]; then pass "genau ein Config-Tag in ${f#"$TMP_DIR"/}"; else fail "Config-Tag Anzahl ${count} in ${f#"$TMP_DIR"/}"; fi
done
if grep -q '/tolaria-config.js' "$DIST/index.html" && \
   python3 - "$DIST/index.html" <<'PY'
import re, sys
text = open(sys.argv[1], encoding='utf-8').read()
tag = text.find('/tolaria-config.js')
head = text.find('</head>')
raise SystemExit(0 if 0 <= tag < head else 1)
PY
then pass "Config-Tag steht vor </head>"; else fail "Config-Tag steht nicht vor </head>"; fi

echo ""
echo "== Vault-Seeding (idempotent) =="
SEED="$TMP_DIR/seed"
VAULT="$TMP_DIR/vault.git"
mkdir -p "$SEED/sub"
printf '# Willkommen\n\nHallo Tolaria.\n' > "$SEED/welcome.md"
printf '# Unterseite\n' > "$SEED/sub/page.md"
run "seed leerer Vault" env VAULT_OWNER="$(id -un)" VAULT_GROUP="$(id -gn)" \
  bash "$REPO_ROOT/scripts/seed-vault.sh" "$VAULT" "$SEED"
run "HEAD existiert" git --git-dir="$VAULT" rev-parse --verify HEAD
run "welcome.md im Commit" bash -c "git --git-dir='$VAULT' show HEAD:welcome.md | grep -q 'Hallo Tolaria'"
run "sub/page.md im Commit" bash -c "git --git-dir='$VAULT' show HEAD:sub/page.md | grep -q 'Unterseite'"
SECOND="$(env VAULT_OWNER="$(id -un)" VAULT_GROUP="$(id -gn)" \
  bash "$REPO_ROOT/scripts/seed-vault.sh" "$VAULT" "$SEED" 2>&1)"
if grep -q 'bereits geseedet' <<<"$SECOND"; then pass "zweiter Lauf überspringt"; else fail "zweiter Lauf überschreibt nicht"; fi
NOTBARE="$TMP_DIR/notbare"
mkdir -p "$NOTBARE"
if env VAULT_OWNER="$(id -un)" VAULT_GROUP="$(id -gn)" \
  bash "$REPO_ROOT/scripts/seed-vault.sh" "$NOTBARE" "$SEED" >/dev/null 2>&1; then
  fail "nicht-bare Verzeichnis wird abgelehnt"
else
  pass "nicht-bare Verzeichnis wird abgelehnt"
fi

echo ""
echo "== nginx-Template =="
TPL="$REPO_ROOT/nginx/tolaria.conf"
run "Platzhalter __PORT__" grep -q '__PORT__' "$TPL"
run "Platzhalter __SERVER_PORT__" grep -q '__SERVER_PORT__' "$TPL"
run "Basic Auth für /" grep -q 'auth_basic "Tolaria"' "$TPL"
run "WebSocket-Upgrade" grep -q 'proxy_set_header Upgrade' "$TPL"
run "Proxy auf 127.0.0.1" grep -q 'proxy_pass http://127.0.0.1:__SERVER_PORT__' "$TPL"
run "Healthcheck öffentlich" grep -q 'location = /healthz' "$TPL"
run "Config-JS no-store" grep -q 'no-store' "$TPL"
if python3 - "$TPL" <<'PY'
import re
import sys
text = open(sys.argv[1], encoding='utf-8').read()

blocks = {}
for match in re.finditer(r"location\s+(=|\^~|~\*|~)?\s*([^\s{]+)\s*\{", text):
    start = match.end() - 1
    depth = 0
    for index in range(start, len(text)):
        if text[index] == '{':
            depth += 1
        elif text[index] == '}':
            depth -= 1
            if depth == 0:
                blocks[(match.group(1) or '') + match.group(2)] = text[start:index + 1]
                break

v1 = blocks.get('/v1/')
config = blocks.get('=/tolaria-config.js')
root = blocks.get('/')
ok = (
    v1 is not None
    and 'auth_basic' not in v1
    and config is not None
    and 'auth_basic' in config
    and root is not None
    and 'auth_basic' in root
    and text.count('{') == text.count('}')
)
raise SystemExit(0 if ok else 1)
PY
then pass "nginx: Basic nur UI/Config, nicht /v1/, Klammern balanciert"; else fail "nginx: Auth-Bloecke oder Klammern falsch"; fi

echo ""
echo "== systemd-Unit =="
run "ExecStart vorhanden" grep -q '^ExecStart=/usr/bin/node' "$REPO_ROOT/systemd/tolaria.service"
run "EnvironmentFile vorhanden" grep -q '^EnvironmentFile=/etc/tolaria/tolaria.env' "$REPO_ROOT/systemd/tolaria.service"
run "Restart=always" grep -q '^Restart=always' "$REPO_ROOT/systemd/tolaria.service"
run "ReadWritePaths .tmp" grep -q 'node_modules/.tmp' "$REPO_ROOT/systemd/tolaria.service"
if command -v systemd-analyze >/dev/null 2>&1; then
  if systemd-analyze verify "$REPO_ROOT/systemd/tolaria.service" 2>"$TMP_DIR/systemd.err"; then
    pass "systemd-analyze verify"
  else
    # Fehlende User/tolaria oder Pfade sind auf diesem Testhost normal.
    if grep -qiE 'User|Group|No such file|not found' "$TMP_DIR/systemd.err"; then
      echo "[SKIP] systemd-analyze verify (Host ohne tolaria-User/Pfade)"
      sed -n '1,5p' "$TMP_DIR/systemd.err" | sed 's/^/       /'
    else
      fail "systemd-analyze verify"
      sed -n '1,20p' "$TMP_DIR/systemd.err" | sed 's/^/       /'
    fi
  fi
else
  echo "[SKIP] systemd-analyze nicht installiert"
fi

echo ""
echo "== Secret-Handling =="
if [[ "$(grep -c '^[[:space:]]*set -x$' "$REPO_ROOT/install/tolaria.sh" || true)" == "1" ]]; then
  pass "Host: nur ein set -x (vor Secrets)"
else
  fail "Host: set -x Anzahl unerwartet"
fi
if grep -q 'set +x' "$REPO_ROOT/install/tolaria.sh" && \
   grep -q '<redacted>' "$REPO_ROOT/install/tolaria.sh"; then
  pass "Host: xtrace-Stopp + Redaction vorhanden"
else
  fail "Host: xtrace-Stopp/Redaction fehlt"
fi
if grep -q 'set +x' "$REPO_ROOT/scripts/setup-in-container.sh" && \
   grep -q '<redacted>' "$REPO_ROOT/scripts/setup-in-container.sh"; then
  pass "Setup: xtrace-Stopp + Redaction vorhanden"
else
  fail "Setup: xtrace-Stopp/Redaction fehlt"
fi
if grep -q 'TOLARIA_TOKEN' "$REPO_ROOT/scripts/setup-in-container.sh" && \
   ! grep -q 'echo .*TOLARIA_TOKEN' "$REPO_ROOT/scripts/setup-in-container.sh"; then
  pass "Setup: Token wird nicht ausgegeben"
else
  fail "Setup: moegliche Token-Ausgabe"
fi

echo ""
echo "== Installer-Dry-Run / Hilfe =="
run "installer --help" bash "$REPO_ROOT/install/tolaria.sh" --help
run "installer --dry-run" bash "$REPO_ROOT/install/tolaria.sh" --dry-run --ctid 150
DRY="$(bash "$REPO_ROOT/install/tolaria.sh" --dry-run --ctid 150 2>&1)"
if grep -q 'CT-ID            : 150' <<<"$DRY"; then pass "Dry-Run zeigt CT-ID"; else fail "Dry-Run zeigt CT-ID"; fi
if grep -q '10-25 Minuten' <<<"$DRY"; then pass "Dry-Run nennt Build-Dauer"; else fail "Dry-Run nennt Build-Dauer"; fi

echo ""
echo "=================================================="
echo "PASS: ${PASS}  FAIL: ${FAIL}"
echo "=================================================="
[[ "$FAIL" -eq 0 ]]
