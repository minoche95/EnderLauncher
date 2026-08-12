#!/usr/bin/env bash
#
# Installe l'index du launcher EnderCraft : le service HTTP que le launcher
# interroge pour connaître les instances et télécharger les fichiers.
#
#   ./install.sh                          installe dans ./enderindex
#   ./install.sh --dir /srv/enderindex    installe ailleurs
#   ./install.sh --port 8080              port d'écoute (défaut 8087)
#   ./install.sh --public                 exposer sur toutes les interfaces
#   ./install.sh --no-panel               sans le panneau de gestion
#   ./install.sh --panel-bind 0.0.0.0     panneau joignable sur le reseau local
#   ./install.sh --ref <commit>           version des fichiers du panneau
#   ./install.sh --url https://index...   URL publique, écrite dans les manifestes
#
# Rejouable : index.conf, exclude.txt et les manifestes deja presents sont
# conserves. C'est donc aussi la facon de mettre a jour update.sh.
#
# Conçu pour cohabiter avec Crafty : c'est un conteneur nginx indépendant, sur
# son propre port, qui ne touche ni aux volumes ni au réseau de Crafty. Les
# fichiers du pack se déposent dans pack/<instance>/ et `update.sh` régénère
# l'index — aucune raison d'aller fouiller dans les dossiers du serveur de jeu.

set -euo pipefail

TARGET="$PWD/enderindex"
PORT=8087
PUBLIC_URL=""
INSTANCE="EnderCraft"
BIND="127.0.0.1:"   # derrière un tunnel, rien n'a besoin d'être exposé
PANEL=1
PANEL_PORT=8088
PANEL_BIND="127.0.0.1"
REF="master"
RAW="https://raw.githubusercontent.com/minoche95/EnderLauncher"

die()  { printf '\n\033[31mErreur :\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[36m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --dir)      TARGET="${2:?--dir attend un chemin}"; shift 2 ;;
        --port)     PORT="${2:?--port attend un numéro}"; shift 2 ;;
        --url)      PUBLIC_URL="${2:?--url attend une URL}"; shift 2 ;;
        --instance) INSTANCE="${2:?--instance attend un nom}"; shift 2 ;;
        --public)   BIND=""; shift ;;
        --no-panel) PANEL=0; shift ;;
        --panel-port) PANEL_PORT="${2:?--panel-port attend un numéro}"; shift 2 ;;
        --panel-bind) PANEL_BIND="${2:?--panel-bind attend une adresse}"; shift 2 ;;
        --ref)      REF="${2:?--ref attend une référence git}"; shift 2 ;;
        -h|--help)  sed -n '2,15p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *)          die "option inconnue : $1" ;;
    esac
done

mkdir -p "$TARGET"
TARGET="$(cd "$TARGET" && pwd)"
[ -n "$PUBLIC_URL" ] || PUBLIC_URL="http://$(hostname -I 2>/dev/null | awk '{print $1}'):$PORT"
PUBLIC_URL="${PUBLIC_URL%/}"

step "Prérequis"
command -v docker >/dev/null || die "docker introuvable."
docker compose version >/dev/null 2>&1 || die "le plugin 'docker compose' est requis."
command -v sha1sum >/dev/null || die "sha1sum introuvable (paquet coreutils)."
note "docker et sha1sum présents"

step "Arborescence"
mkdir -p "$TARGET/www/files" "$TARGET/pack/$INSTANCE" "$TARGET/logs"
note "$TARGET/pack/$INSTANCE/  ← déposer ici mods/, config/, kubejs/…"
note "$TARGET/www/            ← servi par nginx, régénéré par update.sh"

# ─── Réglages, relus par update.sh ───────────────────────────────────────────

if [ -f "$TARGET/index.conf" ]; then
    note "index.conf existant, conservé"
else
cat > "$TARGET/index.conf" <<CONF
# Réglages de l'index. Modifiables à chaud : update.sh les relit à chaque appel.
PUBLIC_URL=$PUBLIC_URL
INSTANCE=$INSTANCE
PORT=$PORT

# Fichiers que le launcher ne doit jamais écraser une fois écrits chez le
# joueur : ses options, ses raccourcis, ses shaders. Sans ça, chaque lancement
# réinitialiserait ses réglages.
IGNORED=options.txt,optionsof.txt,servers.dat,config/fancymenu/customizablemenus.txt
CONF
note "index.conf écrit"
fi

# ─── nginx ───────────────────────────────────────────────────────────────────

cat > "$TARGET/docker-compose.yml" <<COMPOSE
# Service indépendant de Crafty : port dédié, aucun volume partagé.
services:
  enderindex:
    image: nginx:alpine
    container_name: enderindex
    restart: unless-stopped
    ports:
      # Par défaut lié à la boucle locale : c'est le tunnel cloudflared qui
      # publie le service. Rien à ouvrir dans le pare-feu, rien à exposer.
      # --public retire cette restriction si vous servez sans tunnel.
      - "$BIND$PORT:80"
    volumes:
      - ./www:/usr/share/nginx/html:ro
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      # Le journal alimente les statistiques du panneau.
      - ./logs:/var/log/nginx
COMPOSE


cat > "$TARGET/nginx.conf" <<'NGINX'
server {
    listen 80;
    server_name _;
    root /usr/share/nginx/html;
    access_log /var/log/nginx/access.log combined;

    # Le launcher demande /config, /instances et /articles sans extension.
    location = /config    { default_type application/json; try_files /config.json =404; }
    location = /instances { default_type application/json; try_files /instances.json =404; }
    location = /articles  { default_type application/json; try_files /articles.json =404; }

    # Les jars sont volumineux et immuables : on les laisse en cache long, et
    # c'est l'empreinte du manifeste qui fait foi pour les mises à jour.
    location /pack/ {
        expires 30d;
        add_header Cache-Control "public, immutable";
    }

    # Les manifestes changent à chaque publication : jamais de cache.
    location /files/ {
        default_type application/json;
        add_header Cache-Control "no-store";
    }

    autoindex off;
}
NGINX
note "nginx.conf et docker-compose.yml écrits"

if [ "$PANEL" -eq 1 ]; then
    for f in panel.py panel.html; do
        curl -fsSL "$RAW/$REF/server/$f" -o "$TARGET/$f"             || die "téléchargement de $f impossible (ref $REF)"
    done
    note "panneau récupéré ($REF)"

    # Service utilisateur, pas conteneur : le panneau lance update.sh, qui doit
    # ecrire dans pack/ et www/ avec VOTRE compte. En conteneur il tournait en
    # root et vous laissait des fichiers intouchables. Il a besoin de bash,
    # sha1sum et find — deja presents, l'isolation n'apportait rien.
    command -v python3 >/dev/null || die "python3 est requis pour le panneau."
    UNIT="$HOME/.config/systemd/user/enderindex-panel.service"
    mkdir -p "$(dirname "$UNIT")"
    cat > "$UNIT" <<UNITFILE
[Unit]
Description=Panneau de gestion de l'index EnderCraft
After=network.target

[Service]
Type=simple
WorkingDirectory=$TARGET
Environment=ENDERINDEX_ROOT=$TARGET
Environment=PANEL_PORT=$PANEL_PORT
Environment=PANEL_BIND=$PANEL_BIND
ExecStart=$(command -v python3) $TARGET/panel.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
UNITFILE

    if systemctl --user daemon-reload 2>/dev/null; then
        systemctl --user enable --now enderindex-panel.service >/dev/null 2>&1             && note "service enderindex-panel démarré"             || note "service écrit, à démarrer : systemctl --user start enderindex-panel"
        # Sans lingering, le service meurt a la deconnexion SSH.
        loginctl enable-linger "$USER" >/dev/null 2>&1             && note "lingering activé — le panneau survit à la déconnexion"             || note "lingering refusé : sudo loginctl enable-linger $USER"
    else
        note "systemd utilisateur indisponible — lancez : python3 $TARGET/panel.py"
    fi
    if [ "$PANEL_BIND" != "127.0.0.1" ]; then
        note "écoute sur $PANEL_BIND — aucune authentification, à réserver"
        note "à un réseau de confiance et à ne jamais exposer sur internet"
    fi
fi

# ─── Scripts de gestion ──────────────────────────────────────────────────────

install -m 755 /dev/stdin "$TARGET/update.sh" <<'UPDATE'
#!/usr/bin/env bash
# Regenere l'index depuis pack/, en ecartant ce que exclude.txt designe.
#
#   ./update.sh                    publie depuis pack/<instance>/
#   ./update.sh --from /tmp/mc     publie depuis un autre dossier
#   ./update.sh --dry-run          montre ce qui serait publie, sans rien ecrire
#   ./update.sh --manifest         ecrit sur la sortie standard le manifeste qui
#                                  SERAIT publie. Sert au panneau pour comparer
#                                  a ce que les joueurs ont deja, sans dupliquer
#                                  la logique d'exclusion.
#
# On filtre a la PUBLICATION, pas a la copie : deposez une instance entiere sans
# trier, un oubli ne publiera jamais vos sauvegardes. Aucune dependance au-dela
# de find et sha1sum, presents partout.
set -euo pipefail
cd "$(dirname "$0")"
. ./index.conf

SRC="pack/$INSTANCE"
DRY=0
MANIFEST_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --from)     SRC="${2:?--from attend un chemin}"; shift 2 ;;
        --dry-run)  DRY=1; shift ;;
        --manifest) MANIFEST_ONLY=1; shift ;;
        *) echo "option inconnue : $1" >&2; exit 1 ;;
    esac
done
[ -d "$SRC" ] || { echo "Dossier $SRC introuvable." >&2; exit 1; }

# Motifs, commentaires et lignes vides retires.
mapfile -t PATTERNS < <(grep -vE '^\s*(#|$)' exclude.txt || true)

# Convention .gitignore :
#
#   /assets/     slash INITIAL -> ancre a la racine. Ecarte le dossier assets/
#                du haut, gere par le launcher, mais laisse passer un
#                kubejs/assets/ ou un resourcepacks/x/assets/ legitimes.
#   .mixin.out/  sans slash initial -> ce dossier a n'importe quel niveau.
#   *.log        motif simple -> confronte au nom de fichier, a tout niveau.
excluded() {
    local rel="$1" pat bare
    for pat in "${PATTERNS[@]}"; do
        case "$pat" in
            /*/)                                   # dossier ancre a la racine
                bare="${pat#/}"
                case "$rel/" in "$bare"*) return 0 ;; esac ;;
            /*)                                    # fichier ancre a la racine
                case "$rel" in ${pat#/}) return 0 ;; esac ;;
            */)                                    # dossier, a tout niveau
                bare="${pat%/}"
                case "$rel/" in "$pat"*) return 0 ;; esac
                case "$rel" in *"/$bare/"*) return 0 ;; esac ;;
            *)                                     # nom de fichier, tout niveau
                case "${rel##*/}" in $pat) return 0 ;; esac
                case "$rel" in $pat) return 0 ;; esac ;;
        esac
    done
    return 1
}

kept=0; skipped=0
LIST=$(mktemp); trap 'rm -f "$LIST"' EXIT
while IFS= read -r f; do
    rel="${f#"$SRC"/}"
    if excluded "$rel"; then skipped=$((skipped+1)); else echo "$rel" >> "$LIST"; kept=$((kept+1)); fi
done < <(find "$SRC" -type f | sort)

if [ "$MANIFEST_ONLY" -eq 1 ]; then
    # On hache la source directement : rien n'est copie ni ecrit.
    echo "["
    first=1
    while IFS= read -r rel; do
        [ $first -eq 0 ] && echo ","
        first=0
        printf '  {"path": "%s", "hash": "%s", "size": %s, "url": "%s/pack/%s/%s"}'             "$rel" "$(sha1sum "$SRC/$rel" | cut -d' ' -f1)" "$(stat -c%s "$SRC/$rel")"             "$PUBLIC_URL" "$INSTANCE" "$rel"
    done < "$LIST"
    echo
    echo "]"
    exit 0
fi

if [ "$DRY" -eq 1 ]; then
    echo "$kept fichiers seraient publies, $skipped ecartes."
    echo
    echo "--- publie, par dossier de premier niveau ---"
    sed 's|/.*||' "$LIST" | sort | uniq -c | sort -rn | sed 's/^/  /'
    echo
    echo "--- ecarte, par dossier de premier niveau ---"
    while IFS= read -r f; do rel="${f#"$SRC"/}"; excluded "$rel" && echo "$rel"; done         < <(find "$SRC" -type f) | sed 's|/.*||' | sort | uniq -c | sort -rn | sed 's/^/  /'
    exit 0
fi

mkdir -p www/files www/pack
rm -rf "www/pack/$INSTANCE"
while IFS= read -r rel; do
    mkdir -p "www/pack/$INSTANCE/$(dirname "$rel")"
    cp -p "$SRC/$rel" "www/pack/$INSTANCE/$rel"
done < "$LIST"

# Manifeste : un objet par fichier, chemin relatif a l'instance.
# `hash` est bien le nom attendu — minecraft-java-core le relit en `sha1`.
{
  echo "["
  first=1
  while IFS= read -r rel; do
      f="www/pack/$INSTANCE/$rel"
      [ $first -eq 0 ] && echo ","
      first=0
      printf '  {"path": "%s", "hash": "%s", "size": %s, "url": "%s/pack/%s/%s"}'           "$rel" "$(sha1sum "$f" | cut -d' ' -f1)" "$(stat -c%s "$f")"           "$PUBLIC_URL" "$INSTANCE" "$rel"
  done < "$LIST"
  echo
  echo "]"
} > "www/files/$INSTANCE.json"

echo "Index regenere : $kept fichiers publies, $skipped ecartes, $(du -sh "www/pack/$INSTANCE" | cut -f1)"
du -sh "www/pack/$INSTANCE"/* 2>/dev/null | sort -rh | head -6 | sed 's/^/  /'
echo "  manifeste : $PUBLIC_URL/files/$INSTANCE.json"
UPDATE
note "update.sh installé"

cat > "$TARGET/exclude.txt.new" <<'EXCLUDE'
# Ce que l'index ne publie JAMAIS. Convention .gitignore :
#   /nom/   ancre a la racine        nom/   ce dossier a tout niveau
#   *.ext   nom de fichier, partout
# Vous pouvez donc deposer une instance Prism entiere dans pack/ sans trier.

# Propre au joueur, ou sans valeur pour lui
/saves/
/logs/
/crash-reports/
/screenshots/
/backups/
/usercache.json
/usernamecache.json
/local/
/fancymenu_data/
/realms_persistence.json
/servers.dat
/servers.dat_old
.fabric/
.mixin.out/

# Gere par le launcher lui-meme, jamais a distribuer.
# Ancres : un kubejs/assets/ ou un resourcepacks/x/assets/ sont du contenu.
/versions/
/libraries/
/assets/
/natives/
/runtime/
/downloads/

# Caches regeneres au lancement
/dynamic-resource-pack-cache/
/dynamic-data-pack-cache/
.cache/

# Propre a cette machine, ou sans valeur pour un joueur
/command_history.txt
/icon.png

# Metadonnees de Prism et outils de distribution
/mods/.index/
/instance.cfg
/mmc-pack.json
fetch-extras.*
LISEZ-MOI.txt
*.md

# Journaux et fichiers temporaires
*.log
*.log.gz
*.tmp

# Sauvegardes de configuration ecrites par NeoForge quand un fichier .toml
# change de schema. Elles apparaissent toutes seules dans config/ et n'ont
# aucune raison de partir chez les joueurs.
*.bak
EXCLUDE
if [ -f "$TARGET/exclude.txt" ] && ! cmp -s "$TARGET/exclude.txt" "$TARGET/exclude.txt.new"; then
    cp "$TARGET/exclude.txt" "$TARGET/exclude.txt.bak"
    note "exclude.txt mis à jour — ancienne version dans exclude.txt.bak"
else
    note "exclude.txt écrit — c'est lui qui filtre la publication"
fi
mv "$TARGET/exclude.txt.new" "$TARGET/exclude.txt"

# ─── Manifestes de départ ────────────────────────────────────────────────────

# Un garde PAR FICHIER : tester config.json pour decider des trois laissait
# /instances en 404 des qu'on ne regenerait que celui-la.
#
# "online" n'est PAS optionnel. login.js teste `typeof config.online` : booleen
# -> Microsoft (true) ou hors-ligne (false), chaine -> AZauth. Absent, aucune
# branche ne s'execute, le formulaire de connexion n'est jamais affiche et le
# launcher reste sur l'image de fond sans la moindre erreur.
if [ -f "$TARGET/www/config.json" ]; then
    note "config.json existant, conservé"
else
cat > "$TARGET/www/config.json" <<CONFIGJSON
{
  "maintenance": false,
  "maintenance_message": "Maintenance en cours, revenez plus tard.",
  "dataDirectory": "EnderCraft",
  "download_multi": 5,
  "theme": "dark",
  "game_config": true,
  "java_config": true,
  "online": true,
  "rss": ""
}
CONFIGJSON
note "config.json écrit"
fi

python3 - "$TARGET" "$PUBLIC_URL" "$INSTANCE" <<'PYINST'
import json, sys
target, url, inst = sys.argv[1], sys.argv[2], sys.argv[3]
# `loader` et non `loadder` : l'amont a corrigé la faute en 2.1.x, et home.js
# lit désormais options.loader.
instances = {
    inst: {
        "name": inst,
        "url": f"{url}/files/{inst}.json",
        "loader": {
            "loader_type": "neoforge",
            "loader_version": "21.1.233",
            "minecraft_version": "1.21.1",
        },
        "verify": True,
        # `ignored` protege de la SUPPRESSION, pas seulement de l'ecrasement.
        # checkFiles supprime tout fichier de l'instance absent du manifeste ET
        # d'ignored. Sans cette liste, chaque lancement effacerait les mondes
        # solo, les captures et la carte FTB Chunks du joueur.
        "ignored": [
            # Ce que le joueur cree
            "saves", "screenshots", "backups", "logs", "crash-reports",
            "local",            # carte et waypoints FTB Chunks, reglages KubeJS
            "fancymenu_data",   # dernier monde ouvert
            "schematics", "journeymap", "xaero",
            # Ses reglages : pousses une fois, jamais ecrases ensuite
            "options.txt", "optionsof.txt",
            "servers.dat", "servers.dat_old",
            "usercache.json", "usernamecache.json", "realms_persistence.json",
            "config/fancymenu/customizablemenus.txt",
        ],
        "jvm_args": [], "game_args": [],
        "whitelistActive": False, "whitelist": [],
        "status": {"nameServer": inst, "ip": "play.enderhost.info", "port": 25565},
    }
}
import os

def write_if_absent(path, data):
    """Ne touche jamais a un manifeste existant : il porte vos reglages."""
    if os.path.exists(path):
        return False
    open(path, "w", encoding="utf-8").write(
        json.dumps(data, indent=2, ensure_ascii=False) + chr(10))
    return True

wrote = []
if write_if_absent(f"{target}/www/instances.json", instances):
    wrote.append("instances.json")
if write_if_absent(f"{target}/www/articles.json",
                   [{"title": "Saison 1",
                     "content": "Le pack EnderCraft est en place. Bon jeu !",
                     "author": "EnderCraft", "publish_date": "2026-01-01"}]):
    wrote.append("articles.json")
print("    " + (", ".join(wrote) + " ecrits" if wrote
                else "instances.json et articles.json existants, conserves"))
PYINST
note "instances.json et articles.json : écrits s'ils manquaient"

step "Démarrage"
( cd "$TARGET" && docker compose up -d ) >/dev/null 2>&1 || die "docker compose a échoué."
sleep 2
code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/config" || echo 000)
[ "$code" = "200" ] || die "le service ne répond pas sur le port $PORT (code $code)."
note "nginx répond sur le port $PORT"

# Remise en route apres un redemarrage de la machine.
#
# `restart: unless-stopped` ne suffit pas : une politique de redemarrage ne
# s'applique qu'a un conteneur qui EXISTE encore. Apres un `docker compose
# down`, ou apres un `docker stop` que la politique respecte precisement, rien
# ne relance le service au boot — l'index reste muet et le launcher affiche
# « aucune connexion » a tous les joueurs.
#
# D'ou cette unite : elle rejoue `docker compose up -d` au demarrage, ce qui
# recree le conteneur s'il a disparu et le relance s'il etait arrete. Unite
# utilisateur, comme le panneau : le lingering active plus haut la fait
# demarrer sans ouvrir de session, et aucun sudo n'est requis.
STACK_UNIT="$HOME/.config/systemd/user/enderindex-stack.service"
mkdir -p "$(dirname "$STACK_UNIT")"
cat > "$STACK_UNIT" <<STACKUNIT
[Unit]
Description=Pile nginx de l'index EnderCraft
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$TARGET
ExecStart=$(command -v docker) compose up -d
ExecStop=$(command -v docker) compose stop
# Le demon Docker peut n'etre pas encore pret quand systemd lance l'unite.
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
STACKUNIT

if systemctl --user daemon-reload 2>/dev/null; then
    systemctl --user enable enderindex-stack.service >/dev/null 2>&1 \
        && note "enderindex-stack activé — la pile repart au démarrage" \
        || note "unité écrite, à activer : systemctl --user enable enderindex-stack"
    loginctl enable-linger "$USER" >/dev/null 2>&1 \
        || note "lingering refusé : sudo loginctl enable-linger $USER"
else
    note "systemd utilisateur indisponible — la pile ne repartira pas seule"
fi

# Docker lui-meme doit demarrer au boot, sinon tout ce qui precede est vain.
if command -v systemctl >/dev/null; then
    if systemctl is-enabled docker >/dev/null 2>&1; then
        note "docker est activé au démarrage"
    else
        note "ATTENTION : docker n'est pas activé au démarrage"
        note "  corrigez avec : sudo systemctl enable --now docker"
    fi
fi

step "Terminé"
printf '
    1. Déposez le contenu du pack client dans :
         %s/pack/%s/
       (mods/, config/, kubejs/ — exactement ce qu%s aurait dans .minecraft)

    2. Générez l'\''index :
         %s/update.sh

    3. Dans le launcher, package.json -> "url" doit valoir :
         %s

    Le launcher lit alors /instances, télécharge les fichiers listés et vérifie
    leur empreinte. Rien à redémarrer après un update.sh.

' "$TARGET" "$INSTANCE" "'un joueur" "$TARGET" "$PUBLIC_URL"
