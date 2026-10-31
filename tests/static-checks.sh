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
echo "== DNS-Reparatur =="
DNS_CONF="$TMP_DIR/resolv.conf"
run "repair-dns --help" bash "$REPO_ROOT/scripts/repair-dns.sh" --help
bash "$REPO_ROOT/scripts/repair-dns.sh" --help > "$TMP_DIR/repair-help.txt"
run "repair-dns --help nennt --fallback-servers" \
  grep -q -- '--fallback-servers' "$TMP_DIR/repair-help.txt"
run "repair-dns --help nennt --persist-dhclient" \
  grep -q -- '--persist-dhclient' "$TMP_DIR/repair-help.txt"
run "repair-dns prueft IPv4/A-Records" grep -q 'getent ahostsv4' "$REPO_ROOT/scripts/repair-dns.sh"
run "repair-dns schreibt Nameserver" \
  bash "$REPO_ROOT/scripts/repair-dns.sh" --servers "1.1.1.1 9.9.9.9" \
    --resolv-conf "$DNS_CONF" --skip-check
run "resolv.conf enthält 1.1.1.1" grep -qx 'nameserver 1.1.1.1' "$DNS_CONF"
run "resolv.conf enthält 9.9.9.9" grep -qx 'nameserver 9.9.9.9' "$DNS_CONF"
run "resolv.conf enthält options" grep -q '^options ' "$DNS_CONF"

# DHCP darf die Nameserver nicht wieder überschreiben (supersede), und ein
# zweiter Lauf darf keinen doppelten Block erzeugen.
DHCLIENT_CONF="$TMP_DIR/dhclient.conf"
printf 'send host-name = gethostname();\n' > "$DHCLIENT_CONF"
run "persist-dhclient schreibt supersede" \
  bash "$REPO_ROOT/scripts/repair-dns.sh" --servers "1.1.1.1 9.9.9.9" \
    --resolv-conf "$DNS_CONF" --skip-check --persist-dhclient \
    --dhclient-conf "$DHCLIENT_CONF"
run "dhclient.conf enthält supersede" \
  grep -qx 'supersede domain-name-servers 1.1.1.1, 9.9.9.9;' "$DHCLIENT_CONF"
run "bestehende dhclient.conf bleibt erhalten" \
  grep -qx 'send host-name = gethostname();' "$DHCLIENT_CONF"
bash "$REPO_ROOT/scripts/repair-dns.sh" --servers "1.1.1.1 9.9.9.9" \
  --resolv-conf "$DNS_CONF" --skip-check --persist-dhclient \
  --dhclient-conf "$DHCLIENT_CONF" >/dev/null 2>&1
if [[ "$(grep -c '>>> tolaria-dns >>>' "$DHCLIENT_CONF")" == "1" ]]; then
  pass "persist-dhclient ist idempotent"
else
  fail "persist-dhclient ist idempotent"
fi

# Fehlschlagende Nameserver dürfen eine funktionierende Konfiguration nicht
# kaputt machen: Original wiederherstellen und dieses festschreiben.
FAKE_BIN="$TMP_DIR/fakebin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/getent" <<'EOF'
#!/usr/bin/env sh
case "$*" in *localhost*) exit 0 ;; esac
if grep -qE "$BADPAT" "$WATCH" 2>/dev/null; then exit 2; fi
exit 0
EOF
chmod +x "$FAKE_BIN/getent"
RESTORE_CONF="$TMP_DIR/restore-resolv.conf"
RESTORE_DHC="$TMP_DIR/restore-dhclient.conf"
printf 'nameserver 203.0.113.9\n' > "$RESTORE_CONF"
: > "$RESTORE_DHC"
if PATH="$FAKE_BIN:$PATH" WATCH="$RESTORE_CONF" BADPAT='198\.51\.100\.' \
   bash "$REPO_ROOT/scripts/repair-dns.sh" --servers "198.51.100.1" \
     --fallback-servers "198.51.100.2" --resolv-conf "$RESTORE_CONF" \
     --persist-dhclient --dhclient-conf "$RESTORE_DHC" >/dev/null 2>&1 \
   && grep -qx 'nameserver 203.0.113.9' "$RESTORE_CONF" \
   && grep -qx 'supersede domain-name-servers 203.0.113.9;' "$RESTORE_DHC"; then
  pass "funktionierende Konfiguration wird wiederhergestellt"
else
  fail "funktionierende Konfiguration wird wiederhergestellt"
fi

# Kaputte Ausgangslage + kaputte Wunschserver -> Fallback wird geschrieben
# und ebenfalls gegen DHCP festgeschrieben.
FALLBACK_CONF="$TMP_DIR/fallback-resolv.conf"
FALLBACK_DHC="$TMP_DIR/fallback-dhclient.conf"
printf 'nameserver 203.0.113.9\n' > "$FALLBACK_CONF"
: > "$FALLBACK_DHC"
if PATH="$FAKE_BIN:$PATH" WATCH="$FALLBACK_CONF" BADPAT='198\.51\.100\.|203\.0\.113\.' \
   bash "$REPO_ROOT/scripts/repair-dns.sh" --servers "198.51.100.1" \
     --fallback-servers "1.1.1.1" --resolv-conf "$FALLBACK_CONF" \
     --persist-dhclient --dhclient-conf "$FALLBACK_DHC" >/dev/null 2>&1 \
   && grep -qx 'nameserver 1.1.1.1' "$FALLBACK_CONF" \
   && grep -qx 'supersede domain-name-servers 1.1.1.1;' "$FALLBACK_DHC"; then
  pass "Fallback-Nameserver werden persistiert"
else
  fail "Fallback-Nameserver werden persistiert"
fi

echo ""
echo "== apt-Host-Pinning =="
PIN_BIN="$TMP_DIR/pinbin"
mkdir -p "$PIN_BIN"
cat > "$PIN_BIN/getent" <<'EOF'
#!/usr/bin/env sh
last=""
for arg in "$@"; do last="$arg"; done
printf '151.101.1.1 %s\n' "$last"
EOF
chmod +x "$PIN_BIN/getent"
HOSTS_FILE="$TMP_DIR/hosts"
printf '127.0.0.1 localhost\n' > "$HOSTS_FILE"
run "apt-hosts-pin --help" bash "$REPO_ROOT/scripts/apt-hosts-pin.sh" --help
run "apt-hosts-pin pin" env PATH="$PIN_BIN:$PATH" \
  bash "$REPO_ROOT/scripts/apt-hosts-pin.sh" pin \
    --hosts-file "$HOSTS_FILE" --hosts "deb.debian.org security.debian.org" --retries 1
run "Pin-Eintrag für deb.debian.org" grep -qx '151.101.1.1 deb.debian.org' "$HOSTS_FILE"
run "bestehende hosts-Einträge bleiben" grep -qx '127.0.0.1 localhost' "$HOSTS_FILE"
env PATH="$PIN_BIN:$PATH" bash "$REPO_ROOT/scripts/apt-hosts-pin.sh" pin \
  --hosts-file "$HOSTS_FILE" --hosts "deb.debian.org security.debian.org" --retries 1 >/dev/null 2>&1
if [[ "$(grep -c '>>> tolaria-apt-hosts >>>' "$HOSTS_FILE")" == "1" ]]; then
  pass "Pin ist idempotent"
else
  fail "Pin ist idempotent"
fi
run "apt-hosts-pin unpin" bash "$REPO_ROOT/scripts/apt-hosts-pin.sh" unpin --hosts-file "$HOSTS_FILE"
if ! grep -q 'tolaria-apt-hosts' "$HOSTS_FILE" && grep -qx '127.0.0.1 localhost' "$HOSTS_FILE"; then
  pass "unpin entfernt nur den eigenen Block"
else
  fail "unpin entfernt nur den eigenen Block"
fi
run "unpin ist idempotent" bash "$REPO_ROOT/scripts/apt-hosts-pin.sh" unpin --hosts-file "$HOSTS_FILE"
if bash "$REPO_ROOT/scripts/apt-hosts-pin.sh" bogus >/dev/null 2>&1; then
  fail "ungültige Aktion wird abgelehnt"
else
  pass "ungültige Aktion wird abgelehnt"
fi
if bash "$REPO_ROOT/scripts/apt-hosts-pin.sh" pin \
     --hosts-file "$HOSTS_FILE" --hosts 'bad;host' --retries 1 >/dev/null 2>&1; then
  fail "ungültiger Hostname wird abgelehnt"
else
  pass "ungültiger Hostname wird abgelehnt"
fi

# /etc/hosts endet nicht immer mit Zeilenumbruch. Der Marker muss trotzdem
# als eigene Zeile erkannt und wieder entfernt werden können.
printf '127.0.0.1 localhost' > "$HOSTS_FILE"
if env PATH="$PIN_BIN:$PATH" bash "$REPO_ROOT/scripts/apt-hosts-pin.sh" pin \
     --hosts-file "$HOSTS_FILE" --hosts "deb.debian.org" --retries 1 >/dev/null 2>&1 \
   && grep -qx '151.101.1.1 deb.debian.org' "$HOSTS_FILE" \
   && bash "$REPO_ROOT/scripts/apt-hosts-pin.sh" unpin --hosts-file "$HOSTS_FILE" >/dev/null 2>&1 \
   && grep -qx '127.0.0.1 localhost' "$HOSTS_FILE" \
   && ! grep -q 'tolaria-apt-hosts' "$HOSTS_FILE"; then
  pass "Pin funktioniert ohne abschließenden Zeilenumbruch"
else
  fail "Pin funktioniert ohne abschließenden Zeilenumbruch"
fi

# Zwei A-Records pro Host erhöhen die Chance, dass ein blockiertes
# Fastly-Subnetz nicht die ganze Installation verhindert.
PIN_BIN2="$TMP_DIR/pinbin2"
mkdir -p "$PIN_BIN2"
cat > "$PIN_BIN2/getent" <<'EOF'
#!/usr/bin/env sh
printf '151.101.1.1\n151.101.2.2\n'
EOF
chmod +x "$PIN_BIN2/getent"
printf '127.0.0.1 localhost\n' > "$HOSTS_FILE"
if env PATH="$PIN_BIN2:$PATH" bash "$REPO_ROOT/scripts/apt-hosts-pin.sh" pin \
     --hosts-file "$HOSTS_FILE" --hosts "deb.debian.org" --retries 1 >/dev/null 2>&1 \
   && grep -qx '151.101.1.1 deb.debian.org' "$HOSTS_FILE" \
   && grep -qx '151.101.2.2 deb.debian.org' "$HOSTS_FILE"; then
  pass "mehrere A-Records werden gepinnt"
else
  fail "mehrere A-Records werden gepinnt"
fi
bash "$REPO_ROOT/scripts/apt-hosts-pin.sh" unpin --hosts-file "$HOSTS_FILE" >/dev/null 2>&1 || true

# Der eingebaute Fallback in setup-in-container.sh ist die Versicherung gegen
# ein veraltetes Host-Skript, das apt-hosts-pin.sh nicht mitpusht. Deshalb
# wird genau dieser Code hier funktional getestet (aus dem Skript extrahiert).
SETUP_FILE="$REPO_ROOT/scripts/setup-in-container.sh"
SETUP_PIN_HARNESS="$TMP_DIR/setup-pin-harness.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'set -euo pipefail'
  echo 'msg_info() { echo "[INFO] $*"; }'
  echo 'msg_ok() { echo "[OK] $*"; }'
  echo 'msg_warn() { echo "[WARN] $*"; }'
  echo 'msg_error() { echo "[ERROR] $*" >&2; }'
  echo 'PKG_DIR="$1"'
  sed -n '/^# >>> tolaria-inline-pin >>>/,/^# <<< tolaria-inline-pin <<</p' "$SETUP_FILE" | sed '1d;$d'
  cat <<'EOF'
apt_hosts_pin_inline
apt_hosts_verified
grep -q '^151.101.1.1 deb.debian.org$' "$APT_HOSTS_FILE"
grep -q '^151.101.2.2 deb.debian.org$' "$APT_HOSTS_FILE"
grep -q '^151.101.1.1 security.debian.org$' "$APT_HOSTS_FILE"
apt_hosts_remove_block
! grep -q 'tolaria-apt-hosts' "$APT_HOSTS_FILE"
grep -qx '127.0.0.1 localhost' "$APT_HOSTS_FILE"
EOF
} > "$SETUP_PIN_HARNESS"
INLINE_HOSTS="$TMP_DIR/inline-hosts"
printf '127.0.0.1 localhost\n' > "$INLINE_HOSTS"
if env PATH="$PIN_BIN2:$PATH" APT_HOSTS_FILE="$INLINE_HOSTS" \
     bash "$SETUP_PIN_HARNESS" "$TMP_DIR/no-pin-script" >/dev/null 2>&1; then
  pass "Setup: eingebauter Pin-Fallback funktioniert ohne apt-hosts-pin.sh"
else
  fail "Setup: eingebauter Pin-Fallback funktioniert ohne apt-hosts-pin.sh"
fi

# nsswitch.conf muss /etc/hosts vor DNS fragen. Sonst liefert getent zwar
# eine (gleiche) DNS-IP, apt fragt aber weiter DNS und scheitert unter Last.
# Die Funktion wird mit einem kontrollierten getent getestet.
NSS_BIN="$TMP_DIR/nssbin"
mkdir -p "$NSS_BIN"
cat > "$NSS_BIN/getent" <<'EOF'
#!/usr/bin/env sh
if [ "${FAKE_HOSTS_OK:-0}" = "1" ]; then
  printf '127.0.0.1\n'
  exit 0
fi
exit 2
EOF
chmod +x "$NSS_BIN/getent"

NSS_HARNESS="$TMP_DIR/nss-harness.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'set -euo pipefail'
  echo 'msg_info() { echo "[INFO] $*"; }'
  echo 'msg_ok() { echo "[OK] $*"; }'
  echo 'msg_warn() { echo "[WARN] $*"; }'
  echo 'msg_error() { echo "[ERROR] $*" >&2; }'
  echo 'PKG_DIR="$1"'
  sed -n '/^# >>> tolaria-inline-pin >>>/,/^# <<< tolaria-inline-pin <<</p' "$SETUP_FILE" | sed '1d;$d'
  echo 'ensure_hosts_lookup || true'
} > "$NSS_HARNESS"

NSS_OK="$TMP_DIR/nss-ok"
printf 'hosts: files dns\n' > "$NSS_OK"
NSS_OK_HOSTS="$TMP_DIR/nss-ok-hosts"
printf '127.0.0.1 localhost\n' > "$NSS_OK_HOSTS"
if env PATH="$NSS_BIN:$PATH" FAKE_HOSTS_OK=1 \
     APT_HOSTS_FILE="$NSS_OK_HOSTS" NSSWITCH_FILE="$NSS_OK" \
     bash "$NSS_HARNESS" "$TMP_DIR/no-pin-script" >/dev/null 2>&1 \
   && grep -qx 'hosts: files dns' "$NSS_OK"; then
  pass "Setup: funktionierende hosts-Auflösung bleibt unverändert"
else
  fail "Setup: funktionierende hosts-Auflösung bleibt unverändert"
fi

NSS_BAD="$TMP_DIR/nss-bad"
printf 'hosts: resolve files\n' > "$NSS_BAD"
NSS_BAD_HOSTS="$TMP_DIR/nss-bad-hosts"
printf '127.0.0.1 localhost\n' > "$NSS_BAD_HOSTS"
env PATH="$NSS_BIN:$PATH" FAKE_HOSTS_OK=0 \
  APT_HOSTS_FILE="$NSS_BAD_HOSTS" NSSWITCH_FILE="$NSS_BAD" \
  bash "$NSS_HARNESS" "$TMP_DIR/no-pin-script" >/dev/null 2>&1 || true
if grep -qx 'hosts: files dns' "$NSS_BAD" \
   && ! grep -q 'tolaria-hosts-check' "$NSS_BAD_HOSTS"; then
  pass "Setup: nsswitch wird auf files-first korrigiert"
else
  fail "Setup: nsswitch wird auf files-first korrigiert"
fi

echo ""
echo "== Packaging-Tarball =="
# Der Host-Installer lädt Packaging als einen konsistenten Tarball. Hier
# wird die Funktion mit einem lokalen Snapshot getestet, damit der Test
# ohne GitHub/Netzwerk läuft.
PKG_SNAP="$TMP_DIR/pkg-snapshot"
mkdir -p "$PKG_SNAP/scripts" "$PKG_SNAP/systemd" "$PKG_SNAP/nginx"
cp "$REPO_ROOT/scripts/setup-in-container.sh" "$PKG_SNAP/scripts/"
cp "$REPO_ROOT/scripts/inject-web-config.py" "$PKG_SNAP/scripts/"
cp "$REPO_ROOT/scripts/seed-vault.sh" "$PKG_SNAP/scripts/"
cp "$REPO_ROOT/scripts/repair-dns.sh" "$PKG_SNAP/scripts/"
cp "$REPO_ROOT/scripts/apt-hosts-pin.sh" "$PKG_SNAP/scripts/"
cp "$REPO_ROOT/scripts/apt-proxy.pl" "$PKG_SNAP/scripts/"
cp "$REPO_ROOT/systemd/tolaria.service" "$PKG_SNAP/systemd/"
cp "$REPO_ROOT/nginx/tolaria.conf" "$PKG_SNAP/nginx/"
PKG_TARBALL="$TMP_DIR/packaging.tar.gz"
tar -czf "$PKG_TARBALL" -C "$PKG_SNAP" .

PKG_FETCH_HARNESS="$TMP_DIR/pkg-fetch-harness.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'set -euo pipefail'
  echo 'msg_info() { echo "[INFO] $*"; }'
  echo 'msg_ok() { echo "[OK] $*"; }'
  echo 'msg_warn() { echo "[WARN] $*"; }'
  echo 'msg_error() { echo "[ERROR] $*" >&2; }'
  sed -n '/^# >>> tolaria-packaging-fetch >>>/,/^# <<< tolaria-packaging-fetch <<</p' "$REPO_ROOT/install/tolaria.sh" | sed '1d;$d'
  cat <<'EOF'
PKG_DIR="$1"
PACKAGING_TARBALL="$2"
PACKAGING_REF=main
INSTALLER_REPO_SLUG=HatchetMan111/TolariaNotizen
INSTALLER_RAW="https://raw.githubusercontent.com/HatchetMan111/TolariaNotizen/main"
PACKAGING_SOURCE=""
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
mkdir -p "$PKG_DIR"
fetch_packaging_tarball
for rel in "${PACKAGING_FILES[@]}"; do
  [[ -s "$PKG_DIR/$(basename "$rel")" ]] || exit 1
done
EOF
} > "$PKG_FETCH_HARNESS"
if bash "$PKG_FETCH_HARNESS" "$TMP_DIR/pkg-target" "$PKG_TARBALL" >/dev/null 2>&1 \
   && [[ -s "$TMP_DIR/pkg-target/setup-in-container.sh" ]] \
   && [[ -s "$TMP_DIR/pkg-target/tolaria.conf" ]]; then
  pass "Packaging-Tarball wird entpackt und alle Dateien sind vorhanden"
else
  fail "Packaging-Tarball wird entpackt und alle Dateien sind vorhanden"
fi
if bash "$PKG_FETCH_HARNESS" "$TMP_DIR/pkg-target-bad" "$TMP_DIR/does-not-exist.tar.gz" >/dev/null 2>&1; then
  fail "defekter Packaging-Tarball wird abgelehnt"
else
  pass "defekter Packaging-Tarball wird abgelehnt"
fi

echo ""
echo "== apt-Proxy =="
if command -v perl >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
  PROXY_WWW="$TMP_DIR/proxy-www"
  mkdir -p "$PROXY_WWW"
  printf 'hello-through-apt-proxy\n' > "$PROXY_WWW/hello.txt"
  printf 'proxy.test 127.0.0.1\n' > "$TMP_DIR/proxy.map"
  python3 -m http.server 18081 --directory "$PROXY_WWW" >/dev/null 2>&1 &
  HTTP_PID=$!
  perl "$REPO_ROOT/scripts/apt-proxy.pl" --port 13143 --map "$TMP_DIR/proxy.map" \
    >"$TMP_DIR/proxy.log" 2>&1 &
  PROXY_PID=$!
  sleep 0.6
  BODY="$(curl -sS -m 5 -x http://127.0.0.1:13143 http://proxy.test:18081/hello.txt 2>/dev/null || true)"
  if [[ "$BODY" == "hello-through-apt-proxy" ]]; then
    pass "apt-Proxy leitet HTTP über das Host-Mapping"
  else
    fail "apt-Proxy leitet HTTP über das Host-Mapping"
    sed -n '1,10p' "$TMP_DIR/proxy.log" 2>/dev/null || true
  fi
  kill "$PROXY_PID" "$HTTP_PID" 2>/dev/null || true
  wait "$PROXY_PID" "$HTTP_PID" 2>/dev/null || true
else
  echo "[SKIP] apt-Proxy (perl oder curl fehlt)"
fi
if bash "$REPO_ROOT/scripts/repair-dns.sh" --servers "8.8.8.8 && echo pwned" \
     --resolv-conf "$DNS_CONF" --skip-check >/dev/null 2>&1; then
  fail "ungültiger Nameserver wird abgelehnt"
else
  pass "ungültiger Nameserver wird abgelehnt"
fi
if getent hosts deb.debian.org >/dev/null 2>&1; then
  printf 'nameserver 203.0.113.1\n' > "$DNS_CONF"
  bash "$REPO_ROOT/scripts/repair-dns.sh" --servers "9.9.9.9" \
    --resolv-conf "$DNS_CONF" >/dev/null 2>&1
  if grep -qx 'nameserver 203.0.113.1' "$DNS_CONF"; then
    pass "funktionierendes DNS wird nicht überschrieben"
  else
    fail "funktionierendes DNS wurde überschrieben"
  fi
else
  echo "[SKIP] funktionierendes DNS wird nicht überschrieben (keine Auflösung auf dem Testhost)"
fi

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

# Ein geerbtes GIT_DIR darf das Seeding nicht auf ein fremdes Repo umbiegen.
GIT_DIR_VAULT="$TMP_DIR/vault-git-dir.git"
if env GIT_DIR=/nonexistent VAULT_OWNER="$(id -un)" VAULT_GROUP="$(id -gn)" \
     bash "$REPO_ROOT/scripts/seed-vault.sh" "$GIT_DIR_VAULT" "$SEED" >/dev/null 2>&1 \
   && git --git-dir="$GIT_DIR_VAULT" rev-parse --verify HEAD >/dev/null 2>&1; then
  pass "seed ignoriert ein geerbtes GIT_DIR"
else
  fail "seed ignoriert ein geerbtes GIT_DIR"
fi
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
run "Healthcheck proxied zum Server" grep -q 'proxy_pass http://127.0.0.1:__SERVER_PORT__/healthz' "$TPL"
run "gzip aktiv" grep -q '^    gzip on;' "$TPL"
run "Asset-Caching" grep -q 'location /assets/' "$TPL"
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

if command -v nginx >/dev/null 2>&1; then
  NGX="$TMP_DIR/nginx"
  mkdir -p "$NGX/conf" "$NGX/logs"
  sed -e 's|__PORT__|18080|g' -e 's|__SERVER_PORT__|18787|g' "$TPL" > "$NGX/conf/tolaria.conf"
  cat > "$NGX/conf/nginx.conf" <<EOF
pid $NGX/nginx.pid;
error_log $NGX/logs/error.log;
events { worker_connections 16; }
http {
  access_log off;
  include $NGX/conf/tolaria.conf;
}
EOF
  run "nginx -t mit gerendertem Template" nginx -p "$NGX" -c "$NGX/conf/nginx.conf" -t
else
  echo "[SKIP] nginx nicht installiert"
fi

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
echo "== DNS / apt-Härtung =="
HOST_INST="$REPO_ROOT/install/tolaria.sh"
CT_SETUP="$REPO_ROOT/scripts/setup-in-container.sh"
run "Host: DNS-Erkennung" grep -q 'detect_dns_servers' "$HOST_INST"
run "Host: Nameserver dauerhaft in CT-Config" grep -Fq 'pct set "$CTID" --nameserver' "$HOST_INST"
run "Host: persistiert effektive CT-Nameserver" grep -Fq 'CT_DNS_EFFECTIVE' "$HOST_INST"
run "Host: liest Nameserver aus CT-resolv.conf" grep -Fq "awk '/^nameserver" "$HOST_INST"
run "Host: repair-dns.sh wird in den CT gepusht" grep -q 'repair-dns.sh' "$HOST_INST"
run "Host: apt-hosts-pin.sh im Packaging" grep -q 'scripts/apt-hosts-pin.sh' "$HOST_INST"
run "Host: apt-proxy.pl im Packaging" grep -q 'scripts/apt-proxy.pl' "$HOST_INST"
run "Setup: lokaler apt-Proxy vorhanden" grep -q 'start_apt_proxy' "$CT_SETUP"
run "Setup: Proxy wird aufgeräumt" grep -q 'cleanup_apt' "$CT_SETUP"
run "Setup: CA-Bundle wird geprüft" grep -q '/etc/ssl/certs/ca-certificates.crt' "$CT_SETUP"
run "Setup: Debian-Keyring wird repariert" grep -q 'debian-archive-keyring' "$CT_SETUP"
run "Setup: NodeSource nutzt den Proxy" grep -q 'https_proxy=' "$CT_SETUP"
run "Setup: Node-Tarball-Fallback vorhanden" grep -q 'install_node_tarball' "$CT_SETUP"
run "Setup: pnpm wird absolut aufgerufen" grep -q "PNPM_BIN" "$CT_SETUP"
run "Setup: Build ohne Login-Shell" grep -q 'bash -c "cd /opt/tolaria/src' "$CT_SETUP"
run "Setup: systemd nutzt tatsächlichen node-Pfad" grep -q 'ExecStart=${NODE_BIN}' "$CT_SETUP"
run "Host: Packaging als atomarer Tarball" grep -q 'codeload.github.com' "$HOST_INST"
run "Host: Cache-Buster fuer Downloads" grep -q 'cache_busted_url' "$HOST_INST"
run "Host: Raw-Download als Fallback" grep -q 'fetch_packaging_raw' "$HOST_INST"
run "Host: Tarball-Download" grep -q 'fetch_packaging_tarball' "$HOST_INST"
run "Host: Packaging-Ref konfigurierbar" grep -q 'TOLARIA_PACKAGING_REF' "$HOST_INST"
run "Setup: apt-Hosts werden gepinnt" grep -q 'apt-hosts-pin.sh' "$CT_SETUP"
run "Setup: Pinning wird entfernt" grep -qF '"$APT_HOSTS_PIN" unpin' "$CT_SETUP"
run "Setup: eingebauter Pin-Fallback" grep -q 'apt_hosts_pin_inline' "$CT_SETUP"
run "Setup: Pin wird verifiziert" grep -q 'apt_hosts_verified' "$CT_SETUP"
run "Setup: hosts-Auflösung wird geprüft" grep -q 'ensure_hosts_lookup' "$CT_SETUP"
run "Setup: nsswitch wird korrigiert" grep -q 'NSSWITCH_FILE' "$CT_SETUP"
run "Setup: apt nutzt immer IPv4" grep -q 'Acquire::ForceIPv4 "true"' "$CT_SETUP"
run "Setup: apt-Parallelität reduziert" grep -q 'Acquire::Queue-Mode "access"' "$CT_SETUP"
run "Setup: hosts-Datei wird fuer _apt lesbar gemacht" grep -q 'chmod 644 "$APT_HOSTS_FILE"' "$CT_SETUP"
run "Setup: letzter Fallback ohne _apt-Sandbox" grep -q 'APT::Sandbox::User=root' "$CT_SETUP"
run "Setup: Pin-Fehler bricht Setup nicht ab" grep -q 'if pin_apt_hosts; then' "$CT_SETUP"
run "Setup: mehrere A-Records pro Host" grep -q 'head -n2' "$CT_SETUP"
run "Setup: apt-Diagnose vorhanden" grep -q 'apt_diag' "$CT_SETUP"
run "Setup: dpkg-Lock-Timeout" grep -q 'DPkg::Lock::Timeout' "$CT_SETUP"
run "Host: Nameserver beim pct create" grep -q -- '--nameserver "\$CT_DNS"' "$HOST_INST"
run "Setup: DNS-Guard vor apt" grep -q 'REPAIR_DNS.*--servers' "$CT_SETUP"
run "Setup: DNS-Guard persistiert dhclient" grep -q -- '--persist-dhclient' "$CT_SETUP"
run "Setup: prueft IPv4/A-Records vor apt" grep -q 'getent ahostsv4 deb.debian.org' "$CT_SETUP"
run "Setup: apt-Fetch-Fehler werden erkannt" grep -q 'Failed to fetch' "$CT_SETUP"
run "Setup: apt-Retries" grep -q 'Acquire::Retries' "$CT_SETUP"
run "Setup: ForceIPv4 ohne globales IPv6" grep -q 'Acquire::ForceIPv4' "$CT_SETUP"
run "Setup: zweiter Versuch mit --fix-missing" grep -q -- '--fix-missing' "$CT_SETUP"
run "Setup: prueft installierte Werkzeuge" grep -q 'missing_cmds' "$CT_SETUP"
if grep -q 'apt-get update -qq' "$CT_SETUP"; then
  fail "Setup: apt-get update -qq (Fehler würden ignoriert)"
else
  pass "Setup: kein stilles apt-get update -qq"
fi
run "Setup: Build-Skip bei unverändertem Commit" grep -q 'NEED_BUILD' "$CT_SETUP"
run "Setup: FORCE_BUILD" grep -q 'FORCE_BUILD' "$CT_SETUP"
run "README: Troubleshooting DNS" grep -q "Temporary failure resolving" "$REPO_ROOT/README.md"
run "README: Troubleshooting CDN-Cache" grep -q 'GitHub-CDN' "$REPO_ROOT/README.md"
run "README: Einzeiler mit Cache-Buster" grep -q 'cb=$(date +%s)' "$REPO_ROOT/README.md"
run "Host: Versionsmarker" grep -q '^INSTALLER_VERSION=' "$REPO_ROOT/install/tolaria.sh"
run "Setup: Versionsmarker" grep -q '^SETUP_VERSION=' "$REPO_ROOT/scripts/setup-in-container.sh"
run "Host: Versions-Handshake" grep -q 'setup_version' "$REPO_ROOT/install/tolaria.sh"

echo ""
echo "== Installer-Dry-Run / Hilfe =="
run "installer --help" bash "$REPO_ROOT/install/tolaria.sh" --help
run "installer --dry-run" bash "$REPO_ROOT/install/tolaria.sh" --dry-run --ctid 150
DRY="$(bash "$REPO_ROOT/install/tolaria.sh" --dry-run --ctid 150 2>&1)"
if grep -q 'CT-ID            : 150' <<<"$DRY"; then pass "Dry-Run zeigt CT-ID"; else fail "Dry-Run zeigt CT-ID"; fi
if grep -q '10-25 Minuten' <<<"$DRY"; then pass "Dry-Run nennt Build-Dauer"; else fail "Dry-Run nennt Build-Dauer"; fi
if grep -q 'Nameserver (CT)' <<<"$DRY"; then pass "Dry-Run zeigt Nameserver"; else fail "Dry-Run zeigt Nameserver"; fi
if grep -q 'Installer-Version' <<<"$DRY"; then pass "Dry-Run zeigt Installer-Version"; else fail "Dry-Run zeigt Installer-Version"; fi
if grep -q 'Build erzwingen' <<<"$DRY"; then pass "Dry-Run zeigt Force-Build"; else fail "Dry-Run zeigt Force-Build"; fi
if bash "$REPO_ROOT/install/tolaria.sh" --help 2>&1 | grep -q -- '--force-build'; then
  pass "--help nennt --force-build"
else
  fail "--help nennt --force-build"
fi
if bash "$REPO_ROOT/install/tolaria.sh" --dry-run --dns "8.8.8.8 && id" >/dev/null 2>&1; then
  fail "ungültige --dns wird abgelehnt"
else
  pass "ungültige --dns wird abgelehnt"
fi

echo ""
echo "=================================================="
echo "PASS: ${PASS}  FAIL: ${FAIL}"
echo "=================================================="
[[ "$FAIL" -eq 0 ]]
