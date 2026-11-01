# Tolaria auf Proxmox VE

Ein Community-Scripts-artiger Einzeiler, der **Tolaria** (lokale Markdown-Wissensbasis / Second Brain) in einem unprivilegierten Debian-12-LXC auf Proxmox VE installiert.

> **Alpha-Hinweis:** Der Web-Build von Tolaria ist Upstream noch **Alpha**. Der Desktop-Build ist das primäre Produkt. Dieses Projekt macht den Web-/Sync-Stack für ein Einzelvault im LAN nutzbar, nicht für Mehrbenutzer-Hosting im Internet.

> **Sicherheitsgrenze:** Die Web-UI läuft standardmäßig über **HTTP** (Port 8080). Basic-Auth-Passwort und Bearer-Token gehen dabei unverschlüsselt über das Netz. Nur in einem vertrauenswürdigen LAN oder hinter VPN/TLS-Reverse-Proxy betreiben. Basic-Auth-Benutzer und -Passwort sind Einzelbenutzer-Zugang: Wer sie hat, sieht auch das Bearer-Token in `/tolaria-config.js` und hat vollen Vault-Zugriff.

## Einzeiler

Auf dem **Proxmox-Host** als root:

```bash
wget -qO /tmp/tolaria.sh \
  "https://raw.githubusercontent.com/HatchetMan111/TolariaNotizen/main/install/tolaria.sh?cb=$(date +%s)" \
  && bash /tmp/tolaria.sh
```

Der `?cb=`-Parameter ist kein Zierrat: `raw.githubusercontent.com` liegt hinter einem CDN und kann `main` einige Minuten lang veraltet ausliefern. Ohne Cache-Buster kann ein frisch gepushter Fix noch nicht im ausgeführten Skript stehen. Das Herunterladen in eine Datei hat außerdem den Vorteil, dass ein fehlgeschlagener Download nicht als leeres `bash -c ""` mit Exit-Code 0 endet.

Alternativ mit festen Ressourcen / CT-ID:

```bash
wget -qO /tmp/tolaria.sh \
  "https://raw.githubusercontent.com/HatchetMan111/TolariaNotizen/main/install/tolaria.sh?cb=$(date +%s)"
CT_ID=150 CORES=4 RAM=6144 DISK=12 bash /tmp/tolaria.sh
```

Oder lokal:

```bash
bash install/tolaria.sh --ctid 150 --cores 4 --memory 6144 --disk 12
```

## Was installiert wird

| Komponente | Details |
|---|---|
| Container | Debian 12, unprivilegiert, `onboot=1`, Hostname `tolaria` |
| Ressourcen | 4 vCPU, 6144 MB RAM, 4096 MB Swap, 12 GB Disk (änderbar) |
| App | Tolaria Web-Build aus `refactoringhq/tolaria` (`pnpm build:web`) |
| Server | Tolaria-Sync-Server (Node 22.14+, Port `127.0.0.1:8787`) |
| Vault | bare Git-Repo `/var/lib/tolaria/vault.git`, geseedet mit `demo-vault-v2` |
| Daten | `/var/lib/tolaria/data` (Arbeits-Clone, Index, Snapshots) |
| Service | `tolaria.service` (systemd, `Restart=always`) |
| Proxy | nginx auf Port `8080`, Basic Auth für UI und Web-Config |
| Secrets | `/etc/tolaria/tolaria.env` (root-only), `/root/tolaria-credentials.txt` |

Der Installer ist **idempotent**: Ein erneuter Lauf mit derselben CT-ID aktualisiert den Quellcode und rebuildet, ohne den Vault zu überschreiben. Vorhandene Tokens und Basic-Auth-Zugangsdaten werden wiederverwendet.

## Zugriff

Nach der Installation zeigt der Installer URL und Zugangsdaten an. Standard:

```text
URL:      http://<LXC-IP>:8080
Benutzer: tolaria
Passwort: <zufällig, siehe Ausgabe>
```

Die Zugangsdaten liegen zusätzlich im Container unter `/root/tolaria-credentials.txt`:

```bash
pct exec <CTID> -- cat /root/tolaria-credentials.txt
```

Der API-Token liegt in `/etc/tolaria/tolaria.env` (root-only). Er wird nicht im Klartext geloggt.

### Auth-Modell (wichtig)

Tolaria Web sendet an `/v1/*` immer einen `Authorization: Bearer <token>`-Header. Deshalb gilt:

- `/` und `/tolaria-config.js` sind mit **HTTP Basic Auth** geschützt.
- `/v1/*` ist **nicht** Basic-geschützt; dort prüft der Tolaria-Server das Bearer-Token.
- Das echte Token steht in `/tolaria-config.js`. Diese Datei ist nur nach Basic-Auth erreichbar, aber für jeden authentifizierten Browser sichtbar.
- Der Server selbst lauscht nur auf `127.0.0.1:8787` und ist nicht direkt erreichbar.
- Das ist ein Einzelbenutzer-Setup. Es gibt keine Rollen, keine getrennten Konten und keine Mandantentrennung.

Basic Auth auf `/v1/*` wäre technisch falsch: Der Client überschreibt den `Authorization`-Header mit `Bearer`, und WebSocket-Upgrades können keinen Basic-Header zuverlässig mitschicken. Für Internet-Betrieb gehört zusätzlich ein VPN oder ein SSO-/Access-Proxy davor.

## Grenzen

- **Kein Desktop-Sync-Endpunkt:** Der Server arbeitet mit einem lokalen bare Git-Repo. Die Tolaria-Desktop-App kann dieses Repo nicht direkt als Git-Remote nutzen; für Desktop-Sync müsste das bare Repo zusätzlich per SSH/HTTPS als Git-Remote exponiert werden. Dieses Installer-Setup liefert bewusst nur die Web-UI.
- **Kein TLS:** Standard ist HTTP im LAN. Für Zugriff aus anderen Netzen VPN oder einen TLS-terminierenden Reverse-Proxy davorschalten.
- **Alpha:** Upstream-Web-Build und Protokoll können sich ändern; ein Update kann Anpassungen erfordern.
- **Ein Vault:** Die Installation ist auf ein Vault und einen Benutzer ausgelegt.

## Voraussetzungen

- Proxmox VE 8.x (getestet werden konnte nur statisch, siehe unten)
- Root-Zugriff auf den Proxmox-Host
- Internetzugang für Template, `nodejs.org` (Node-Tarball), npm/pnpm und den Upstream-Build (NodeSource nur als Fallback)
- Funktionierende DNS-Auflösung im Container. Der Installer übernimmt die Host-Nameserver, erkennt den systemd-resolved-Stub `127.0.0.53` und repariert `/etc/resolv.conf` automatisch. In Netzen ohne öffentlichen DNS: `--dns "192.168.1.1"`.
- Mindestens 12 GB freier Storage, 6 GB RAM und 4 vCPU für den Build
- Port `8080` im LAN erreichbar (oder `--port` ändern)

## Optionen

```text
--ctid ID            Container-ID (Default: nächste freie ID)
--hostname NAME      Hostname (Default: tolaria)
--cores N            vCPU (Default: 4)
--memory MB          RAM in MB (Default: 6144)
--swap MB            Swap in MB (Default: 4096)
--disk GB            Disk in GB (Default: 12)
--storage NAME       RootFS-Storage (Default: auto, bevorzugt local-lvm)
--template-store N   Template-Storage (Default: local)
--bridge NAME        Netzwerk-Bridge (Default: vmbr0)
--port PORT          Web-UI-Port (Default: 8080)
--auth-user USER     Basic-Auth-Benutzer (Default: tolaria)
--auth-password PW   Basic-Auth-Passwort (Default: zufällig)
--dns "IP [IP]"      Nameserver im Container (Default: Host-DNS, sonst 1.1.1.1 9.9.9.9)
--ref REF            Upstream-Branch/Tag (Default: main)
--password PW        Root-Passwort des Containers (Default: zufällig)
--ssh-key PATH       SSH-Public-Key in den Container übernehmen
--force-build        Build auch bei unverändertem Upstream-Commit neu ausführen
--debug, -x          Trace bis zur Secret-Erzeugung + erweiterte Fehlerkette
--dry-run            Nur Plan ausgeben, nichts verändern
--help, -h           Hilfe
```

Umgebungsvariablen funktionieren ebenfalls, z. B. `CT_ID`, `CORES`, `RAM`, `SWAP`, `DISK`, `BRIDGE`, `PORT`, `TOLARIA_REF`, `DNS_SERVERS`, `FORCE_BUILD`.

Für Packaging-Downloads gibt es zusätzlich:

| Variable | Zweck |
|---|---|
| `TOLARIA_PACKAGING_REF` | Branch/Tag/Commit des Installer-Repos für den Tarball (Default: `main`) |
| `TOLARIA_PACKAGING_TARBALL` | Eigene Tarball-URL oder lokaler Pfad statt `codeload.github.com` |
| `TOLARIA_PACKAGING_DIR` | Lokaler Checkout; umgeht den Download komplett (für Entwicklung/Offline) |
| `TOLARIA_REPO_SLUG` | GitHub-Repo für den Tarball, falls Fork (Default: `HatchetMan111/TolariaNotizen`) |
| `TOLARIA_RAW_BASE` | Basis-URL für den Raw-Datei-Fallback |

`--auth-password` erlaubt nur `A-Z a-z 0-9 . _ ~ @ % + = : , / -`. Ohne Angabe wird ein zufälliges Hex-Passwort erzeugt. `--debug` pausiert den Trace bewusst vor der Secret-Erzeugung, damit Token/Passwörter nicht im Install-Log landen.

## Update

Einfach den Einzeiler erneut ausführen. Der bestehende Container wird erkannt und wiederverwendet:

```bash
wget -qO /tmp/tolaria.sh \
  "https://raw.githubusercontent.com/HatchetMan111/TolariaNotizen/main/install/tolaria.sh?cb=$(date +%s)" \
  && bash /tmp/tolaria.sh
```

Ablauf beim Update:

1. Upstream `main` wird geholt (`git fetch`).
2. Ist der Commit unverändert und der Web-Build vorhanden, werden `pnpm install` und `pnpm build:web` **übersprungen** (normale Updates dauern dadurch Sekunden statt 10-25 Minuten).
3. Bei neuem Commit: `pnpm install --frozen-lockfile`, `pnpm build:web`, Web-Config wird erneut injiziert.
4. `tolaria.service` und nginx werden neu gestartet.
5. Vault, Token und Basic-Auth-Passwort bleiben erhalten.

Ein Rebuild lässt sich jederzeit erzwingen:

```bash
wget -qO /tmp/tolaria.sh \
  "https://raw.githubusercontent.com/HatchetMan111/TolariaNotizen/main/install/tolaria.sh?cb=$(date +%s)"
FORCE_BUILD=1 bash /tmp/tolaria.sh
```

Für einen bestimmten Stand: `--ref <tag-oder-branch>`.

## Backup

Der gesamte Wissensstand liegt im bare Git-Repo:

```bash
pct exec <CTID> -- tar -C /var/lib -czf /root/tolaria-vault-backup.tar.gz tolaria
pct pull <CTID> /root/tolaria-vault-backup.tar.gz ./tolaria-vault-backup.tar.gz
```

Alternativ nur das Git-Repo:

```bash
pct exec <CTID> -- git --git-dir=/var/lib/tolaria/vault.git bundle create /root/tolaria.bundle --all
pct pull <CTID> /root/tolaria.bundle ./tolaria.bundle
```

Zusätzlich sichern: `/etc/tolaria/tolaria.env` und `/root/tolaria-credentials.txt` (enthalten Token/Passwort).

## Restore

```bash
pct push <CTID> ./tolaria-vault-backup.tar.gz /root/tolaria-vault-backup.tar.gz
pct exec <CTID> -- bash -lc 'systemctl stop tolaria && tar -C /var/lib -xzf /root/tolaria-vault-backup.tar.gz && chown -R tolaria:tolaria /var/lib/tolaria && systemctl start tolaria'
```

## Deinstallieren

```bash
pct stop <CTID>
pct destroy <CTID>
```

Vorher Backup erstellen. `pct destroy` löscht den Vault unwiderruflich.

## Troubleshooting

### Der Installer verhält sich wie eine alte Version

Symptom: Ein Fix ist auf `main`, aber der Lauf zeigt weiterhin das alte Verhalten – zum Beispiel fehlt die Meldung zum apt-Host-Pinning, oder `setup-in-container.sh` scheitert an einer Datei, die es in `main` längst gibt.

Ursache ist der GitHub-CDN: `raw.githubusercontent.com` cached `main` typischerweise einige Minuten. Das Installer-Skript und die einzeln nachgeladenen Packaging-Dateien können dadurch aus **unterschiedlichen Commits** stammen. Der Installer lädt Packaging deshalb inzwischen bevorzugt als **einen Tarball** (`codeload.github.com/.../tar.gz/refs/heads/main`), also als konsistenten Snapshot. Zusätzlich ist das apt-Host-Pinning im Container-Skript selbst eingebaut, falls `apt-hosts-pin.sh` durch ein altes Host-Skript nicht mitgepusht wurde.

Host-Skript und Container-Setup tragen eine gemeinsame `INSTALLER_VERSION`/`SETUP_VERSION`. Weichen sie voneinander ab, bricht der Installer **vor** dem Containerstart mit einer klaren Meldung ab, statt einen halb kompatiblen Lauf zu starten. Der erste Log-Eintrag im Container ist `Setup-Version: ...`; damit lässt sich ein alter Lauf sofort erkennen.

Trotzdem gilt: Nach einem Push den Einzeiler mit Cache-Buster verwenden:

```bash
wget -qO /tmp/tolaria.sh \
  "https://raw.githubusercontent.com/HatchetMan111/TolariaNotizen/main/install/tolaria.sh?cb=$(date +%s)" \
  && bash /tmp/tolaria.sh
```

Für einen reproduzierbaren Stand kann Packaging explizit gepinnt werden:

```bash
TOLARIA_PACKAGING_REF=<commit-oder-tag> bash /tmp/tolaria.sh
```

### `Temporary failure resolving 'deb.debian.org'` / apt Exit-Code 100

Das ist der häufigste Installationsfehler in Proxmox-LXCs. Zwei Ursachen treten dabei auf:

1. Läuft auf dem Host `systemd-resolved`, übernimmt Proxmox den Stub `nameserver 127.0.0.53`, der **innerhalb** des Containers nicht erreichbar ist.
2. Der DHCP-Client im Container (`dhclient`) überschreibt `/etc/resolv.conf` nach dem Start mit den DHCP-Nameservern. Diese liefern in manchen Netzen nur AAAA-Antworten; apt braucht in einem IPv4-only-Container aber A-Records und scheitert dann mit `Temporary failure resolving`, obwohl `getent hosts` scheinbar funktioniert.

Der Installer prüft deshalb die **IPv4-Auflösung** (`getent ahostsv4`) vor `apt-get`, repariert `/etc/resolv.conf` automatisch und schreibt die geprüften Nameserver per `supersede domain-name-servers` in `/etc/dhcp/dhclient.conf`, damit DHCP sie nicht wieder ersetzt. Schlägt die Reparatur fehl, bricht er mit einer klaren Meldung ab, statt 84 MB Downloads einzeln scheitern zu lassen. Welche Nameserver tatsächlich funktionieren, liest er nach der Reparatur aus dem Container und hinterlegt genau diese dauerhaft via `pct set --nameserver` – auch wenn dafür der öffentliche Fallback `1.1.1.1 9.9.9.9` nötig war.

Bereits vorhandenen Container manuell reparieren:

```bash
CTID=106
pct set "$CTID" --nameserver "1.1.1.1 9.9.9.9"
pct exec "$CTID" -- bash -c 'printf "nameserver 1.1.1.1\nnameserver 9.9.9.9\noptions timeout:2 attempts:2\n" > /etc/resolv.conf'
# DHCP daran hindern, die Datei wieder zu überschreiben:
pct exec "$CTID" -- bash -c 'mkdir -p /etc/dhcp && printf "supersede domain-name-servers 1.1.1.1, 9.9.9.9;\n" >> /etc/dhcp/dhclient.conf'
pct reboot "$CTID"
pct exec "$CTID" -- getent ahostsv4 deb.debian.org
```

Wichtig ist `getent ahostsv4` (nicht `getent hosts`): Nur so sieht man, ob apt die benötigten A-Records bekommt.

### DNS funktioniert, apt meldet aber weiter `Temporary failure resolving`

Wenn `getent ahostsv4 deb.debian.org` eine Adresse liefert, apt beim Download aber trotzdem an der Auflösung scheitert, bricht die Namensauflösung unter der Last vieler paralleler apt-Verbindungen zusammen (typisch bei NAT/Conntrack oder Rate-Limits im Router). Der Installer löst deshalb `deb.debian.org`, `security.debian.org` und `deb.nodesource.com` vor der Paketinstallation einmal auf, pinnt sie kurzzeitig in `/etc/hosts` (markierter Block `tolaria-apt-hosts`) und entfernt den Block danach wieder. Damit braucht apt während der Installation gar kein DNS. Pro Host werden bis zu zwei A-Records gepinnt; nach dem Schreiben prüft der Installer, ob `getent` wirklich den gepinnten Eintrag liefert.

Das Pinning steckt sowohl in `scripts/apt-hosts-pin.sh` als auch als eingebauter Fallback direkt in `setup-in-container.sh`. Damit scheitert es nicht daran, dass ein veraltetes Host-Skript die separate Datei nicht in den Container kopiert hat.

Zusätzlich prüft der Installer mit einem Sentinel-Hostnamen, ob die Namensauflösung `/etc/hosts` überhaupt liest. Steht in `/etc/nsswitch.conf` z. B. `hosts: resolve ...` oder `hosts: dns files`, liefert `getent` zwar eine IP (und der Pin sieht „verifiziert“ aus), apt fragt aber weiter DNS. In diesem Fall setzt der Installer die `hosts:`-Zeile auf `hosts: files dns` (Backup: `/etc/nsswitch.conf.tolaria.bak`). Außerdem gilt für alle apt-Aufrufe im Container `/etc/apt/apt.conf.d/99tolaria-network` mit `Acquire::ForceIPv4`, Retries, Timeouts und reduzierter Parallelität (`Queue-Mode access`).

Ein weiterer Stolperstein sind die Dateirechte: apt lädt als Benutzer `_apt`. Ist `/etc/hosts` nur für root lesbar (z. B. Modus 600), sieht `getent` als root den Pin, apt aber nicht. Der Installer setzt `/etc/hosts` deshalb auf 644, prüft die Lesbarkeit als `_apt` und hat als letzten Fallback einen apt-Lauf ohne `_apt`-Sandbox (`APT::Sandbox::User=root`).

Falls apt trotz verifiziertem Pin weiter DNS fragt, startet der Installer zusätzlich einen **lokalen apt-Proxy** ([scripts/apt-proxy.pl](scripts/apt-proxy.pl)) auf `127.0.0.1:3142`. Er bekommt die gepinnten IPs als Mapping, leitet HTTP und HTTPS-CONNECT dorthin weiter und umgeht damit apts eigenen Resolver vollständig. Der Proxy läuft nur während der Installation; danach werden Konfiguration und Prozess entfernt. Voraussetzung ist `perl-base` (in Debian 12 enthalten); fehlt Perl, läuft apt wie bisher direkt.

Der Installer prüft außerdem **CA-Bundle und Debian-Keyring**. Fehlen sie oder sind sie veraltet, scheitert apt mit `NO_PUBKEY` bzw. `No system certificates available`. Zwei Dinge wurden dafür geändert:

1. **Pfadrechte:** In manchen LXCs steht `/etc` auf `0700`. Dann können `_apt` und der Build-Benutzer `tolaria` die Dateien unter `/etc/ssl` und `/usr/share/keyrings` nicht erreichen, obwohl die Dateien selbst 644 sind. Das Setup ergänzt fehlende Ausführungsbits (`chmod a+x /etc`, `/etc/ssl`, …) und macht CA-Bundle/OpenSSL-Config lesbar. Das erklärt `The certificate issuer is unknown` / `No system certificates`; `NO_PUBKEY` kommt zusätzlich von einem veralteten Keyring (siehe nächster Abschnitt).
2. **Keyring-Reparatur vor dem Entpinnen:** Der Reinstall von `ca-certificates`/`debian-archive-keyring` läuft jetzt, solange der Hosts-Pin und der lokale apt-Proxy noch aktiv sind. Scheitert der Reinstall trotzdem, wird das `.deb` per `apt-get download` über denselben Weg geladen und mit `dpkg -i` installiert. Erst danach wird der Pin entfernt.

Node 22 kommt inzwischen **primär** als offizieller Tarball von `nodejs.org` (SHA256-geprüft, ohne apt/GPG). NodeSource ist nur noch Fallback für Umgebungen, in denen `nodejs.org` blockiert ist. Damit hängt der Node-Schritt nicht mehr an Debian-Keyring, apt-HTTPS oder der NodeSource-Repositories-Signatur.

### `NO_PUBKEY ...` / `The following signatures couldn't be verified`

Symptom im Log:

```
NO_PUBKEY 6ED0E7B82643E131
NO_PUBKEY 78DBA3BC47EF2265
NO_PUBKEY F8D2585B8783D481
```

Ursache ist ein **veralteter `debian-archive-keyring`** (typisch im Proxmox-Debian-12-Template). Der Installer versucht den Reinstall mit aktivem DNS-unabhängigem Pin/Proxy. Prüfen:

```bash
pct exec <CTID> -- dpkg -l debian-archive-keyring ca-certificates
pct exec <CTID> -- stat -c '%a %U:%G %n' /etc /etc/ssl /usr/share/keyrings
pct exec <CTID> -- runuser -u _apt -- test -r /etc/ssl/certs/ca-certificates.crt \
  && echo "CA lesbar" || echo "CA NICHT lesbar"
```

Manuell reparieren:

```bash
pct exec <CTID> -- bash -c 'chmod a+x /etc /etc/ssl /usr/share/keyrings'
pct exec <CTID> -- apt-get update -o Acquire::Retries=5
pct exec <CTID> -- apt-get install --reinstall -y debian-archive-keyring ca-certificates
pct exec <CTID> -- update-ca-certificates --fresh
```

Danach den Installer erneut ausführen. Node 22 wird auch ohne funktionierenden Keyring über den Tarball installiert.

### `EAI_AGAIN registry.npmjs.org` bei `pnpm install`

pnpm öffnet viele parallele Verbindungen. Ein Resolver, der einzelne Anfragen beantwortet, bricht unter dieser Last zusammen – im Log sichtbar als `getaddrinfo EAI_AGAIN registry.npmjs.org`. Der Installer pinnt deshalb zusätzlich `registry.npmjs.org`/`registry.npmjs.com` in `/etc/hosts` (derselbe markierte Block wie apt), begrenzt die Parallelität (`--network-concurrency=4`), erhöht die Retries und wiederholt `pnpm install` bis zu dreimal. Der pnpm-Store bleibt im Home von `tolaria`, sodass ein Retry bereits geladene Pakete wiederverwendet.

Prüfen:

```bash
pct exec <CTID> -- grep -A8 tolaria-apt-hosts /etc/hosts
pct exec <CTID> -- getent ahostsv4 registry.npmjs.org
pct exec <CTID> -- runuser -u tolaria -- bash -lc \
  'cd /opt/tolaria/src && pnpm install --frozen-lockfile --network-concurrency=4 --fetch-retries=8'
```

Der Block wird am Ende der Installation automatisch entfernt. Bleibt er nach einem Abbruch stehen, entfernt ihn der nächste Lauf.

Schlägt apt trotz aktiven Pins fehl, bleibt der Pin zunächst aktiv und der Installer versucht es mit frischen Listen erneut. Erst wenn das ebenfalls scheitert, entfernt er den Pin für einen letzten DNS-Versuch. Die Diagnose (Pin-Block, A/AAAA, Proxy-Schlüssel, letzte apt-Zeilen) landet im Build-Log; die apt-Rohausgabe steht in `/root/tolaria-apt-update.log`.

Manuell prüfen:

```bash
pct exec 109 -- getent ahostsv4 deb.debian.org   # liefert eine IP?
pct exec 109 -- grep -A6 tolaria-apt-hosts /etc/hosts
pct exec 109 -- tail -n 40 /root/tolaria-apt-update.log
```

Der Block darf nach dem Lauf nicht mehr vorhanden sein; falls doch (z. B. nach einem Abbruch), entfernt ihn der nächste Lauf automatisch.

Danach den Installer erneut ausführen. In einem LAN ohne öffentlichen DNS die dort gültigen Resolver verwenden:

```bash
wget -qO /tmp/tolaria.sh \
  "https://raw.githubusercontent.com/HatchetMan111/TolariaNotizen/main/install/tolaria.sh?cb=$(date +%s)"
DNS_SERVERS="192.168.1.1" bash /tmp/tolaria.sh
```

`pct set --nameserver` ist wichtig: Ohne den Eintrag in der CT-Config schreibt Proxmox die kaputte Datei beim nächsten Start wieder. Der Installer ist idempotent: Bei einem vorhandenen Container genügt ein erneuter Lauf, er repariert DNS und den DHCP-Schutz automatisch.

### `pnpm: command not found` / `Permission denied`

Die Build-Schritte liefen früher über `bash -lc`. Eine Login-Shell liest `/etc/profile`; ist die Datei für den `tolaria`-User nicht lesbar, bricht die Profilauswertung ab und der `PATH` geht verloren. Der Installer setzt `/etc/profile` deshalb auf 644, ruft `pnpm` über den absolut ermittelten Pfad auf und nutzt `bash -c` mit explizitem `PATH` statt einer Login-Shell.

Zusätzlich lief das Setup früher mit `umask 077`. Dadurch legten Paket-Postinsts und `npm install -g` Dateien wie `/etc/ssl/openssl.cnf` oder `pnpm` als `root:root` mit Modus 600 an; der Build-Benutzer `tolaria` bekam `Permission denied`. Das Setup nutzt jetzt `umask 022`, setzt sensible Dateien explizit auf 600/640 und korrigiert die Rechte von pnpm, `/etc/ssl` und `/etc/ssl/openssl.cnf`. Für den Build wird zusätzlich `OPENSSL_CONF=/dev/null` gesetzt (Node nutzt eigene CA-Roots), damit ein nicht lesbares OpenSSL-Config den Build nicht blockiert; bei Bedarf zeigt `namei -l /etc/ssl/openssl.cnf` die tatsächlichen Pfadrechte im Log.

### `fatal: not in a git directory` beim Vault-Seeding

Das Seeding läuft in einem temporären Verzeichnis. Eine geerbte Git-Umgebung (`GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE` …) kann alle Git-Aufrufe auf ein fremdes Repository umbiegen; `git init` wirkt dann erfolgreich, aber `git config` scheitert. `seed-vault.sh` entfernt diese Variablen, nutzt explizite `--git-dir`/`--work-tree`-Pfade und prüft direkt nach `git init`, ob `.git` wirklich existiert. Bei einem Fehler nennt der ERR-Trap die exakte Zeile und den Befehl.

### Node.js bleibt bei Version 18 / NodeSource scheitert

Der Installer installiert Node 22 inzwischen **primär** über den offiziellen Tarball von `nodejs.org` (SHA256-geprüft, nach `/usr/local`, ohne apt/GPG). Das ist der zuverlässige Weg in Containern mit altem Debian-Keyring, unlesbarem CA-Bundle oder apt-HTTPS-Problemen. Nur wenn der Tarball nicht geladen werden kann, versucht der Installer NodeSource als Fallback. Die systemd-Unit wird auf den tatsächlichen Node-Pfad umgeschrieben.

Prüfen:

```bash
pct exec <CTID> -- node --version
pct exec <CTID> -- systemctl cat tolaria | grep ExecStart
pct exec <CTID> -- ls -l /usr/local/bin/node
```

### Build schlägt fehl / OOM

Der TypeScript-/Vite-Build braucht RAM. Mindestens 6 GB, besser 8 GB:

```bash
# Container stoppen, RAM erhöhen, neu starten
pct set <CTID> --memory 8192
pct stop <CTID> && pct start <CTID>
# Installer erneut ausführen
```

Der Build-Log liegt im Container unter `/root/tolaria-build.log`:

```bash
pct exec <CTID> -- tail -n 200 /root/tolaria-build.log
```

### Service läuft nicht

```bash
pct exec <CTID> -- systemctl status tolaria --no-pager --full
pct exec <CTID> -- journalctl -u tolaria --no-pager -n 200
pct exec <CTID> -- nginx -t
pct exec <CTID> -- tail -n 100 /var/log/nginx/error.log
```

### Web-UI lädt, aber keine Notizen

- Prüfen, ob `/v1/vault` mit dem Token antwortet:

```bash
TOKEN="$(pct exec <CTID> -- bash -lc 'sed -n "s/^TOLARIA_SERVER_TOKEN=//p" /etc/tolaria/tolaria.env')"
curl -i -H "Authorization: Bearer $TOKEN" http://<LXC-IP>:8080/v1/vault
```

- Prüfen, ob der Vault geseedet ist:

```bash
pct exec <CTID> -- git --git-dir=/var/lib/tolaria/vault.git log --oneline -3
```

- Prüfen, ob das Config-Script im HTML steht:

```bash
pct exec <CTID> -- grep -n 'tolaria-config.js' /opt/tolaria/src/apps/web/dist/index.html
```

### Port ändern

```bash
bash install/tolaria.sh --ctid <CTID> --port 8090
```

Der Installer schreibt die nginx-Config neu und startet nginx/tolaria neu. Der Vault bleibt erhalten.

### Debug

```bash
DEBUG=1 bash install/tolaria.sh --ctid <CTID>
```

Bei Fehlern gibt der Installer Befehl, Zeile, Exit-Code, Stacktrace, `pct config`, `systemctl status`, `journalctl`, `nginx -t`, nginx-Fehlerlog und Disk/RAM aus. Token und Passwörter werden in der Fehlerausgabe redigiert. Die vollständige Ausgabe steht zusätzlich in `/tmp/tolaria-install-*.log` auf dem Host.

## Reboot-Test

Auf dem Proxmox-Host:

```bash
bash tests/reboot-check.sh <CTID> 8080
```

Der Test prüft `onboot=1`, `systemctl is-enabled`, rebootet den **Container**, wartet auf den Service und prüft Web-UI, `/healthz`, `/tolaria-config.js`, `/v1/vault`, die IPv4-DNS-Auflösung samt DHCP-Schutz sowie die Persistenz von Vault-HEAD und Server-Daten. Ein echter **Host**-Reboot wird nicht ausgeführt; `onboot=1` wird geprüft, der Host-Neustart muss manuell verifiziert werden.

## Projektstruktur

```text
install/tolaria.sh              Host-Installer (Proxmox)
scripts/setup-in-container.sh   Build/Setup im LXC
scripts/repair-dns.sh           DNS-Check/-Reparatur im Container
scripts/apt-hosts-pin.sh        apt-Hosts temporär in /etc/hosts pinnen
scripts/apt-proxy.pl            lokaler apt-Proxy (127.0.0.1:3142) für gepinnte IPs
scripts/inject-web-config.py    idempotente HTML-Injection
scripts/seed-vault.sh           bare Git-Vault seeden
systemd/tolaria.service         systemd-Unit
nginx/tolaria.conf              nginx-Template (__PORT__, __SERVER_PORT__)
tests/static-checks.sh          lokale Tests ohne Proxmox
tests/reboot-check.sh           Reboot-/Persistenz-Test auf Proxmox
.github/workflows/ci.yml        CI: statische Checks bei Push/PR
```

## Teststatus

In dieser Umgebung wurde **kein echter Proxmox-Host** ausgeführt. Validiert wurden:

- Bash-Syntax (`bash -n`) und Shellcheck
- Python-Syntax und idempotente HTML-Injection
- Vault-Seeding inkl. Idempotenz und Schutz vor Nicht-bare-Verzeichnissen (auch mit dem echten `demo-vault-v2`)
- nginx-Template-Struktur
- nginx 1.24 mit dem gerenderten Template lokal: Syntax, Basic-Auth auf `/` und `/tolaria-config.js`, kein Basic-Auth auf `/v1/`, Bearer-Passthrough, gzip/Asset-Caching und öffentliches `/healthz` als Proxy zum Server
- systemd-Unit (soweit ohne `tolaria`-User/Pfade auf dem Testhost möglich)
- Installer `--dry-run`, `--help` und Secret-Redaction
- DNS-Reparatur (`scripts/repair-dns.sh`): Rendering der `resolv.conf`, Validierung von Nameservern, Ablehnung ungültiger Eingaben, Fallback-Nameserver, Backup/Restore, IPv4/A-Record-Prüfung und idempotentes Festschreiben gegen DHCP (`supersede`)
- apt-Host-Pinning (`scripts/apt-hosts-pin.sh`): Auflösen, markierter `/etc/hosts`-Block, Idempotenz und restloses Entfernen (funktional getestet); mehrere A-Records pro Host, Zeilenumbruch-sichere Marker und Hostnamen-Validierung
- Eingebauter Pinning-Fallback in `setup-in-container.sh` (funktional getestet), damit ein veraltetes Host-Skript das Pinning nicht aushebeln kann
- `ensure_hosts_lookup`: Sentinel-Test und Korrektur von `nsswitch.conf` auf `hosts: files dns` (funktional mit kontrolliertem `getent` getestet)
- apt-Grundeinstellungen im Container: `ForceIPv4`, Retries, Timeouts und `Queue-Mode access`
- Lokaler apt-Proxy (`scripts/apt-proxy.pl`): HTTP-Weiterleitung über Host-Mapping funktional getestet, inklusive HTTPS-`CONNECT` (manuell mit lokalem TLS-Server und echtem apt-Update)
- CA-/Keyring-Reparatur mit aktivem Pin/Proxy, inklusive `apt-get download` + `dpkg -i`-Fallback und `update-ca-certificates --fresh`
- Traversierbarkeit von `/etc`/`/etc/ssl` für `_apt` und `tolaria`; explizites apt-CA-Bundle (`Acquire::https::CaInfo`)
- Offizieller Node-22-Tarball als **primärer** Weg (SHA256-geprüft, nach `/usr/local`, systemd-Unit nutzt den tatsächlichen Pfad); NodeSource nur noch Fallback
- npm-Registry-Pinning (`registry.npmjs.org`/`registry.npmjs.com`) im selben `/etc/hosts`-Block wie apt, plus `--network-concurrency=4`, `--fetch-retries=8` und Retry für `pnpm install`
- Vault-Seeding mit explizitem `--git-dir`/`--work-tree` und Bereinigung einer geerbten Git-Umgebung; funktional mit `GIT_DIR=/nonexistent` und dem echten `demo-vault-v2` getestet
- pnpm/Build ohne Login-Shell, mit absolutem pnpm-Pfad und explizitem `PATH`
- Dateirechte für Build-Benutzer: `umask 022`, pnpm ausführbar, `/etc/ssl/openssl.cnf` und CA-Bundle lesbar
- Verifikation des Pins über `getent ahostsv4` plus `/etc/hosts`-Abgleich; apt versucht bei Fehlern zuerst erneut mit Pin und entfernt ihn erst für den letzten DNS-Versuch
- Packaging als atomarer Tarball inkl. Cache-Buster und Raw-Fallback: lokaler Tarball, `file://`-Tarball und echter `codeload.github.com`-Download getestet
- Persistenz der tatsächlich funktionierenden Nameserver in der CT-Config (statisch geprüft); wird jetzt auch bei bereits funktionierendem DNS geschrieben
- Statische Prüfung, dass apt-Fehler nicht mehr ignoriert werden (`Failed to fetch`-Erkennung, Retries)
- Statische Prüfung des inkrementellen Updates (`FORCE_BUILD`, Build-Skip)
- `tests/static-checks.sh` (alle Checks bestanden)
- GitHub-Actions-CI (`.github/workflows/ci.yml`) führt dieselben Checks bei Push/PR aus
- Realer Build-Test mit Upstream `main`: `pnpm install --frozen-lockfile` (pnpm 10.33.0, Node 22) und `pnpm build:web` erfolgreich
- HTML-Injection gegen den echten Web-Build (`index.html` und `apps/web/collab.html`)
- Lokaler Server-E2E-Test mit dem echten `demo-vault-v2`: `/healthz`, `/v1/vault`, `/v1/entries`, Datei-Lesen/Schreiben/Löschen, Git-Push ins bare Repo
- Web-Config-Injection vor dem App-Bundle im echten Build geprüft

Der Container-Reboot wurde hier **nicht** ausgeführt. Führe auf einem Proxmox-Host aus:

```bash
bash tests/static-checks.sh
bash tests/reboot-check.sh <CTID> 8080
```

## Lizenz / Upstream

Tolaria ist AGPL-3.0-or-later; siehe [refactoringhq/tolaria](https://github.com/refactoringhq/tolaria). Dieses Installer-Repository enthält nur Packaging-/Betriebsskripte und lädt den Upstream-Code zur Build-Zeit. Der Web-Build ist Upstream-Alpha; Funktionen und API können sich ändern.
