#!/usr/bin/env python3
"""Panneau de gestion de l'index EnderCraft.

Ecoute sur 127.0.0.1 uniquement : c'est lui qui decide de ce que TOUS les
joueurs telechargent, il ne doit jamais etre expose. On y accede par tunnel
SSH :

    ssh -L 8088:127.0.0.1:8088 minoche@serveur

puis http://localhost:8088

Bibliotheque standard seule — aucune dependance a installer, aucune surface
supplementaire.
"""

import html
import json
import os
import re
import shutil
import subprocess
import time
from collections import Counter, defaultdict
from datetime import datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

ROOT = Path(os.environ.get("ENDERINDEX_ROOT", Path(__file__).resolve().parent))
PORT = int(os.environ.get("PANEL_PORT", "8088"))
# En conteneur il faut ecouter sur 0.0.0.0 : c'est la publication Docker
# (127.0.0.1:8088:8088) qui limite l'exposition a la boucle locale de l'hote.
BIND = os.environ.get("PANEL_BIND", "127.0.0.1")


def conf() -> dict:
    """Relu a chaque appel : index.conf peut changer sans redemarrage."""
    out = {}
    f = ROOT / "index.conf"
    if f.exists():
        for line in f.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, _, v = line.partition("=")
                out[k.strip()] = v.strip()
    return out


def instance() -> str:
    return conf().get("INSTANCE", "EnderCraft")


def run(args: list[str], timeout: int = 600) -> tuple[int, str]:
    """update.sh est invoque par `bash` explicitement plutot qu'execute :
    le bit d'execution se perd facilement a la copie, et le script emploie des
    constructions bash (mapfile, substitution de processus) que sh n'a pas."""
    try:
        p = subprocess.run(["bash"] + args, cwd=ROOT, capture_output=True,
                           text=True, timeout=timeout)
    except FileNotFoundError:
        return 127, "bash introuvable sur ce systeme"
    return p.returncode, (p.stdout or "") + (p.stderr or "")


def published() -> list[dict]:
    f = ROOT / "www" / "files" / f"{instance()}.json"
    if not f.exists():
        return []
    try:
        return json.loads(f.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return []


def staged() -> tuple[list[dict], str]:
    """Ce qui SERAIT publie. Delegue a update.sh pour ne pas dupliquer la
    logique d'exclusion — la faire diverger serait le meilleur moyen de publier
    un jour une sauvegarde."""
    code, out = run(["./update.sh", "--manifest"])
    if code != 0:
        return [], out
    try:
        return json.loads(out), ""
    except json.JSONDecodeError:
        return [], out


def diff() -> dict:
    old = {e["path"]: e for e in published()}
    new, err = staged()
    cur = {e["path"]: e for e in new}
    return {
        "error": err,
        "added": sorted(set(cur) - set(old)),
        "removed": sorted(set(old) - set(cur)),
        "changed": sorted(p for p in set(cur) & set(old)
                          if cur[p]["hash"] != old[p]["hash"]),
        "total": len(cur),
        "size": sum(e["size"] for e in cur.values()),
    }


# ─── Statistiques, lues dans le journal d'acces nginx ────────────────────────

LOG_RE = re.compile(
    r'^(?P<ip>\S+) \S+ \S+ \[(?P<date>[^\]]+)\] "(?:GET|HEAD) (?P<path>\S+)'
    r'[^"]*" (?P<code>\d{3}) (?P<bytes>\d+)')


def stats(days: int = 14) -> dict:
    log = ROOT / "logs" / "access.log"
    if not log.exists():
        return {"available": False}

    since = datetime.now() - timedelta(days=days)
    per_day, ips, files = Counter(), defaultdict(set), Counter()
    total_bytes = launches = errors = 0

    with log.open(encoding="utf-8", errors="replace") as fh:
        for line in fh:
            m = LOG_RE.match(line)
            if not m:
                continue
            try:
                when = datetime.strptime(m["date"].split()[0], "%d/%b/%Y:%H:%M:%S")
            except ValueError:
                continue
            if when < since:
                continue
            day = when.strftime("%Y-%m-%d")
            code = int(m["code"])
            if code >= 400:
                errors += 1
                continue
            total_bytes += int(m["bytes"])
            ips[day].add(m["ip"])
            path = m["path"]
            # /instances n'est demande qu'au demarrage du launcher : c'est le
            # meilleur indicateur de lancements disponible sans telemetrie.
            if path.startswith("/instances"):
                launches += 1
                per_day[day] += 1
            elif path.startswith("/pack/"):
                files[path.split("/pack/", 1)[1].split("/", 1)[-1]] += 1

    days_sorted = sorted(set(list(per_day) + list(ips)))
    return {
        "available": True,
        "launches": launches,
        "errors": errors,
        "bytes": total_bytes,
        "series": [{"day": d, "launches": per_day.get(d, 0),
                    "clients": len(ips.get(d, ()))} for d in days_sorted],
        "top": files.most_common(12),
    }


def health() -> dict:
    c = conf()
    port = c.get("PORT", "8087")
    inst = instance()
    man = ROOT / "www" / "files" / f"{inst}.json"
    du = shutil.disk_usage(ROOT)

    # En conteneur, 127.0.0.1 designe la boucle locale du PANNEAU, pas nginx.
    # On essaie donc le nom du service docker d'abord, puis l'hote local pour le
    # cas d'une execution directe sans conteneur.
    import urllib.request
    nginx = False
    for url in (os.environ.get("NGINX_URL"),
                f"http://127.0.0.1:{port}/config",
                "http://enderindex/config"):
        if not url:
            continue
        try:
            with urllib.request.urlopen(url, timeout=4) as r:
                if r.status == 200:
                    nginx = True
                    break
        except Exception:
            continue

    pub = published()
    return {
        "nginx": nginx,
        "port": port,
        "instance": inst,
        "public_url": c.get("PUBLIC_URL", ""),
        "files": len(pub),
        "size": sum(e["size"] for e in pub),
        "published_at": man.stat().st_mtime if man.exists() else 0,
        "disk_free": du.free,
        "disk_total": du.total,
    }


def listing(sub: str) -> list[dict]:
    base = (ROOT / "pack" / instance() / sub).resolve()
    root = (ROOT / "pack" / instance()).resolve()
    if not str(base).startswith(str(root)) or not base.is_dir():
        return []
    out = []
    for p in sorted(base.iterdir(), key=lambda x: (x.is_file(), x.name.lower())):
        st = p.stat()
        out.append({"name": p.name, "dir": p.is_dir(),
                    "size": st.st_size if p.is_file() else 0,
                    "mtime": st.st_mtime})
    return out


def safe_target(rel: str) -> Path | None:
    """Empeche toute sortie du dossier du pack — un ../ suffirait sinon a
    ecrire n'importe ou sur le serveur."""
    root = (ROOT / "pack" / instance()).resolve()
    p = (root / rel).resolve()
    return p if str(p).startswith(str(root)) and p != root else None


# ─── Serveur ─────────────────────────────────────────────────────────────────

MAX_UPLOAD = 512 * 1024 * 1024   # un jar depasse rarement 100 Mo


class Panel(BaseHTTPRequestHandler):
    server_version = "EnderIndexPanel"

    def _json(self, obj, code=200):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        if u.path in ("/", "/index.html"):
            page = Path(__file__).resolve().parent / "panel.html"
            body = page.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif u.path == "/api/health":
            self._json(health())
        elif u.path == "/api/diff":
            self._json(diff())
        elif u.path == "/api/stats":
            self._json(stats())
        elif u.path == "/api/files":
            self._json(listing(q.get("path", [""])[0]))
        else:
            self._json({"error": "inconnu"}, 404)

    def do_POST(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        if u.path == "/api/publish":
            code, out = run(["./update.sh"])
            self._json({"ok": code == 0, "output": out})
        elif u.path == "/api/upload":
            rel = q.get("path", [""])[0]
            target = safe_target(rel)
            if not target:
                self._json({"error": "chemin refusé"}, 400)
                return
            size = int(self.headers.get("Content-Length", 0))
            if size > MAX_UPLOAD:
                self._json({"error": "fichier trop volumineux"}, 413)
                return
            target.parent.mkdir(parents=True, exist_ok=True)
            remaining = size
            with target.open("wb") as fh:
                while remaining > 0:
                    chunk = self.rfile.read(min(65536, remaining))
                    if not chunk:
                        break
                    fh.write(chunk)
                    remaining -= len(chunk)
            self._json({"ok": True, "path": rel})
        elif u.path == "/api/delete":
            size = int(self.headers.get("Content-Length", 0))
            payload = json.loads(self.rfile.read(size) or b"{}")
            target = safe_target(payload.get("path", ""))
            if not target or not target.exists():
                self._json({"error": "chemin refusé ou inexistant"}, 400)
                return
            if target.is_dir():
                shutil.rmtree(target)
            else:
                target.unlink()
            self._json({"ok": True})
        else:
            self._json({"error": "inconnu"}, 404)

    def log_message(self, fmt, *args):
        pass   # le journal utile est celui de nginx, pas celui du panneau


if __name__ == "__main__":
    srv = ThreadingHTTPServer((BIND, PORT), Panel)
    print("Panneau sur http://%s:%d  (racine : %s)" % (BIND, PORT, ROOT))
    print("Depuis votre poste :  ssh -L %d:127.0.0.1:%d utilisateur@serveur" % (PORT, PORT))
    srv.serve_forever()
