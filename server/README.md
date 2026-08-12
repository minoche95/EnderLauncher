# Index du launcher — côté serveur

Le launcher ne sait rien du pack : il demande tout à un service HTTP. Ce dossier
l'installe.

```bash
curl -fsSL https://raw.githubusercontent.com/minoche95/EnderLauncher/master/server/install.sh -o install.sh
bash install.sh --url https://index.enderhost.info
```

Un conteneur `nginx:alpine`, **indépendant de Crafty** : aucun volume ni réseau
partagé, rien à changer dans ta stack de jeu.

Il écoute sur `127.0.0.1:8087` seulement — c'est le tunnel `cloudflared` qui
publie le service. **Aucun port à ouvrir dans le pare-feu.** `--public` lève
cette restriction si tu sers sans tunnel.

## Le tunnel

Le service n'est joignable de l'extérieur que par un tunnel. Dans
**Zero Trust → Networks → Tunnels**, sur un tunnel qui tourne *sur cette
machine*, ajoute un public hostname :

| | |
|---|---|
| Subdomain | `index` |
| Domain | `enderhost.info` |
| Service | `HTTP` → `localhost:8087` |

Cloudflare crée l'enregistrement DNS lui-même. Si aucun tunnel ne tourne encore
sur le serveur de jeu, il faut en créer un — un tunnel est lié à la machine où
`cloudflared` s'exécute, on ne peut pas réutiliser celui d'un autre PC.

## Ce que le launcher demande

| Route | Contenu |
|---|---|
| `/config` | réglages globaux : maintenance, thème, dossier de données, `online` |
| `/instances` | les instances : nom, loader, adresse du serveur, manifeste |
| `/articles` | les actualités affichées à l'accueil |
| `/files/<instance>.json` | la liste des fichiers, avec empreinte et taille |
| `/pack/<instance>/…` | les fichiers eux-mêmes |

### `online` n'est pas optionnel

`login.js` teste `typeof config.online` : `true` affiche la connexion Microsoft,
`false` la connexion hors-ligne, une URL bascule sur AZauth. **Si le champ est
absent, aucune branche ne s'exécute** : le formulaire de connexion n'est jamais
affiché, et le launcher reste sur l'image de fond — sans erreur, sans message,
sans rien télécharger. Le symptôme ressemble à une panne réseau alors que tout
l'index répond correctement.

Le format du manifeste n'est pas un choix : `minecraft-java-core` attend
exactement `{path, hash, size, url}` par entrée, et déduit le type du fichier du
premier segment de son chemin. Le champ s'appelle bien `hash` côté serveur —
la bibliothèque le relit en `sha1`.

## Le panneau de gestion

Une interface web pour ajouter ou retirer des mods, voir l'état du service et
suivre l'activité. **Jamais exposée** — c'est elle qui décide de ce que tous les
joueurs téléchargent. On y accède par tunnel SSH :

```bash
ssh -L 8088:127.0.0.1:8088 minoche@serveur
```

puis `http://localhost:8088`.

C'est un **service systemd utilisateur**, pas un conteneur. Volontairement : le
panneau lance `update.sh`, qui doit écrire dans `pack/` et `www/` avec votre
compte. En conteneur il tournait en root et laissait derrière lui des fichiers
que vous ne pouviez plus modifier. Et comme il a besoin de `bash`, `sha1sum` et
`find`, déjà présents sur la machine, l'isolation n'apportait rien.

Par défaut il n'écoute que sur `127.0.0.1`. `--panel-bind 0.0.0.0` le rend
joignable depuis le réseau local, sans tunnel — pratique sur un réseau
personnel, mais **le panneau n'a aucune authentification** : quiconque
l'atteint peut publier ce qu'il veut chez tous les joueurs. À ne jamais
exposer sur internet.

```bash
systemctl --user status enderindex-panel     # état
systemctl --user restart enderindex-panel    # après mise à jour de panel.py
journalctl --user -u enderindex-panel -n 50  # journal
```

| | |
|---|---|
| **État** | nginx en ligne, date de la dernière publication, nombre de fichiers, espace disque |
| **Publication** | diff avant d'agir — ajoutés, modifiés, supprimés — puis publication en un clic |
| **Fichiers** | navigation, dépôt par glisser-déposer, suppression |
| **Activité** | lancements par jour, clients uniques, volume transféré, fichiers les plus téléchargés |

Le diff est le garde-fou qui manquait : sans lui, rien n'empêche de publier
200 fichiers en trop sans s'en apercevoir avant que les joueurs les récupèrent.

Il n'invente rien sur ce qui sera publié : il appelle `./update.sh --manifest`,
qui applique exactement les mêmes exclusions que la publication réelle. Dupliquer
cette logique serait le meilleur moyen de la faire diverger un jour.

Les statistiques viennent du journal d'accès nginx, pas d'une télémétrie : le
launcher demande `/instances` à chaque démarrage, ce qui donne un compte de
lancements fidèle sans rien installer chez le joueur.

`--no-panel` pour s'en passer, `--panel-port` pour changer de port.

## Publier une mise à jour

1. Déposer le contenu du pack client dans `pack/EnderCraft/` — exactement ce
   qu'un joueur aurait dans son `.minecraft` : `mods/`, `config/`, `kubejs/`.
2. Lancer `./update.sh`.

C'est tout. Nginx sert des fichiers statiques et le launcher relit le manifeste
à chaque démarrage : **rien à redémarrer**.

`update.sh` recalcule toutes les empreintes. Un joueur ne retélécharge que ce
qui a changé, puisque le launcher compare taille puis SHA-1 avant d'agir.

## `ignored` protège de la SUPPRESSION, pas seulement de l'écrasement

C'est le point le plus important de toute la configuration.

`checkFiles` supprime **tout fichier de l'instance absent du manifeste et
d'`ignored`**. C'est ce qui garantit qu'un joueur ne peut pas glisser un xray —
mais sans une liste correcte, chaque lancement effacerait aussi ses mondes solo,
ses captures et sa carte FTB Chunks.

D'où les 18 entrées d'`instances.json` : `saves`, `screenshots`, `backups`,
`logs`, `crash-reports`, `local` (carte et waypoints FTB Chunks), `fancymenu_data`,
et les fichiers de réglages.

**Toute donnée créée par le joueur doit y figurer.** Si vous ajoutez un mod qui
écrit hors de `config/` — un mod de carte, de schémas, de statistiques — pensez
à ajouter son dossier, sinon vos joueurs le perdront à chaque démarrage.

## Les fichiers qu'on ne doit pas écraser

`ignored` dans `instances.json` liste ce que le launcher laisse tranquille une
fois écrit chez le joueur :

```
options.txt · optionsof.txt · servers.dat
config/fancymenu/customizablemenus.txt
```

Sans ça, chaque lancement réinitialiserait les réglages, les touches et les
serveurs enregistrés. À compléter si un mod stocke des préférences ailleurs.

Attention à l'inverse : **tout ce qui n'est pas dans `ignored` est réécrit**.
C'est voulu — c'est ce qui garantit que tous les joueurs ont le même pack — mais
ça veut dire qu'un joueur ne peut pas ajouter ses propres mods. Si tu veux le
permettre, il faudra ignorer un sous-dossier dédié.

## Ce qui change par rapport à Prism

Le launcher héberge et distribue les jars lui-même. Les archives Prism, elles,
ne contenaient que des identifiants — précisément pour ne pas redistribuer les
mods.

Sur un serveur privé entre joueurs c'est la pratique courante et personne n'y
regarde. Mais c'est un changement de posture réel, à connaître si le serveur
devient public un jour.

En contrepartie, trois ennuis disparaissent : plus de `fetch-extras` à lancer,
plus d'invites de téléchargement manuel de CurseForge, et plus aucune dérive de
versions entre le client et le serveur.
