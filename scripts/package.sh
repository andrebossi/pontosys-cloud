#!/usr/bin/env bash
# Package the old document root into the tarballs the bucket expects, one
# per artifact -- backends and frontends alike, each packed from inside its
# own directory so it unpacks straight onto the path it's served from.
#
#   scripts/package.sh data/nginx-config 2026.09.12
#
# Eleven artifacts, organized the way the products actually are:
#
#   Backend, one build each:
#     virtualstore | relatoriosapi | pixapi | entradaapi | dashsapi | cadastrosapi
#
#   Virtualstore frontend, packed separately:
#     root (Ionic, served at / -- assets, build, index.html, manifest.json, ...;
#           key is "root", not "virtualstore": that name is already the
#           backend API above, see VIRTUALSTORE_FRONTEND_IONIC below)
#     app  (Flutter -- source repo is "flutter", "app" is only the
#           internal/artifact key)
#
#   Monitor Clientes, frontend + both its backends -- promoted together as
#   one release (see versions_rc.yml's "monitorclientes" release group):
#     monitorclientes (Flutter frontend)
#     monitorclientesapi
#     geradorrelatoriosapi
#
# Upload:
#   for f in out/*/*.tar.gz; do
#     n=$(basename "$(dirname "$f")"); v=$(basename "$f" .tar.gz); v=${v#"$n"-}
#     ns=$(oci os ns get --query data --raw-output)
#     oci os object put --namespace "$ns" --bucket-name pscloud-releases \
#       --name "artifacts/$n/$n-$v.tar.gz" --file "$f" --force
#   done
#
# Then set the version in ansible/group_vars/role_app/versions_rc.yml.
set -euo pipefail

SRC=${1:?usage: package.sh <document root> <version>}
VER=${2:?usage: package.sh <document root> <version>}
OUT=${OUT:-out}

VIRTUALSTORE_BACKEND="virtualstore relatoriosapi pixapi entradaapi dashsapi cadastrosapi"
MONITORCLIENTES_BACKEND="monitorclientesapi geradorrelatoriosapi"
BACKEND_APPS="$VIRTUALSTORE_BACKEND $MONITORCLIENTES_BACKEND"

# State, not build output. These are linked_dirs: they live in
# /srv/apps/<app>/shared and are symlinked into each release, so inside the
# artifact a deploy would replace the live data with the tarball's copy.
STATE="Contents Relatorios ArquivosFiscais Fonts logs"

# Build leftovers -- entradaapi and pixapi shipped a nested copy of themselves.
JUNK="publish ref obj"

# Virtualstore frontend, Ionic: the storefront's own files, at the root of
# the document root.
VIRTUALSTORE_FRONTEND_IONIC="index.html manifest.json signalr_ponto_a.html build assets icons"

# Virtualstore frontend, Flutter ("app") + Monitor Clientes frontend,
# Flutter ("monitorclientes") -- each packed from inside its own directory.
FRONTEND_SITES="app monitorclientes"

pack() { printf '  %-22s %s\n' "$1" "$(du -h "$2" | cut -f1)"; }

for app in $BACKEND_APPS; do
  [ -d "$SRC/$app" ] || { echo "  skip $app"; continue; }
  mkdir -p "$OUT/$app"
  ex=(); for d in $STATE $JUNK; do ex+=(--exclude="./$d"); done
  tar -C "$SRC/$app" "${ex[@]}" -czf "$OUT/$app/$app-$VER.tar.gz" .
  pack "$app" "$OUT/$app/$app-$VER.tar.gz"
done

mkdir -p "$OUT/root"
tar -C "$SRC" -czf "$OUT/root/root-$VER.tar.gz" $VIRTUALSTORE_FRONTEND_IONIC
pack root "$OUT/root/root-$VER.tar.gz"

for site in $FRONTEND_SITES; do
  [ -d "$SRC/$site" ] || { echo "  skip $site"; continue; }
  mkdir -p "$OUT/$site"
  tar -C "$SRC/$site" -czf "$OUT/$site/$site-$VER.tar.gz" .
  pack "$site" "$OUT/$site/$site-$VER.tar.gz"
done

cat <<TXT

State directories are excluded and are seeded once per machine:
  rsync -a $SRC/virtualstore/Contents/          host:/srv/apps/virtualstore/shared/Contents/
  rsync -a $SRC/virtualstore/Relatorios/        host:/srv/apps/virtualstore/shared/Relatorios/
  rsync -a $SRC/pixapi/Contents/                host:/srv/apps/pixapi/shared/Contents/
  rsync -a $SRC/cadastrosapi/ArquivosFiscais/   host:/srv/apps/cadastrosapi/shared/ArquivosFiscais/
  rsync -a $SRC/relatoriosapi/Fonts/            host:/srv/apps/relatoriosapi/shared/Fonts/
  rsync -a $SRC/relatoriosapi/Relatorios/       host:/srv/apps/relatoriosapi/shared/Relatorios/
TXT
