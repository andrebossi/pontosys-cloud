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

# Contents/Relatorios/ArquivosFiscais/Fonts are part of the app (templates,
# fonts, reference content) and ship in the tarball now like everything
# else -- they used to be excluded and seeded by hand via rsync, which meant
# a fresh machine started without them until someone remembered to run it.
#
# logs is the one real exception: it's runtime output, not build output --
# there is nothing to package, a fresh release just starts empty. Still a
# linked_dir (see applications.yml), so it survives across releases.
STATE="logs"

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
