#!/usr/bin/env bash
# Package the old document root into the tarballs the bucket expects.
#
#   scripts/package.sh data/nginx-config 2026.09.12
#
# Produces, under out/:
#   <app>/<app>-<version>.tar.gz          eight .NET publish trees
#   webroot/webroot-<version>.tar.gz      the three frontends, unpacked over
#                                         the document root
#
# Upload:
#   for f in out/*/*.tar.gz; do
#     n=$(basename "$(dirname "$f")"); v=$(basename "$f" .tar.gz); v=${v#"$n"-}
#     pscloud push "$n" "$v" "$f"
#   done
#
# Then set the version in ansible/group_vars/role_app/applications.yml.
set -euo pipefail

SRC=${1:?usage: package.sh <document root> <version>}
VER=${2:?usage: package.sh <document root> <version>}
OUT=${OUT:-out}

APPS="cadastrosapi dashsapi entradaapi geradorrelatoriosapi monitorclientesapi pixapi relatoriosapi virtualstore"

# State, not build output. These are linked_dirs: they live in
# /srv/apps/<app>/shared and are symlinked into each release, so inside the
# artifact a deploy would replace the live data with the tarball's copy.
STATE="Contents Relatorios ArquivosFiscais Fonts logs"

# Build leftovers -- entradaapi and pixapi shipped a nested copy of themselves.
JUNK="publish ref obj"

# Everything nginx serves from disk: the Ionic storefront at /, and the two
# Flutter builds at /app and /monitorclientes.
WEBROOT="index.html manifest.json signalr_ponto_a.html build assets icons app monitorclientes"

pack() { printf '  %-22s %s\n' "$1" "$(du -h "$2" | cut -f1)"; }

for app in $APPS; do
  [ -d "$SRC/$app" ] || { echo "  skip $app"; continue; }
  mkdir -p "$OUT/$app"
  ex=(); for d in $STATE $JUNK; do ex+=(--exclude="./$d"); done
  tar -C "$SRC/$app" "${ex[@]}" -czf "$OUT/$app/$app-$VER.tar.gz" .
  pack "$app" "$OUT/$app/$app-$VER.tar.gz"
done

mkdir -p "$OUT/webroot"
tar -C "$SRC" -czf "$OUT/webroot/webroot-$VER.tar.gz" $WEBROOT
pack webroot "$OUT/webroot/webroot-$VER.tar.gz"

cat <<TXT

State directories are excluded and are seeded once per machine:
  rsync -a $SRC/virtualstore/Contents/          host:/srv/apps/virtualstore/shared/Contents/
  rsync -a $SRC/virtualstore/Relatorios/        host:/srv/apps/virtualstore/shared/Relatorios/
  rsync -a $SRC/pixapi/Contents/                host:/srv/apps/pixapi/shared/Contents/
  rsync -a $SRC/cadastrosapi/ArquivosFiscais/   host:/srv/apps/cadastrosapi/shared/ArquivosFiscais/
  rsync -a $SRC/relatoriosapi/Fonts/            host:/srv/apps/relatoriosapi/shared/Fonts/
  rsync -a $SRC/relatoriosapi/Relatorios/       host:/srv/apps/relatoriosapi/shared/Relatorios/
TXT
