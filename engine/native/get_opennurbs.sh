#!/bin/zsh
# Fetches openNURBS (McNeel's Rhino file toolkit, github.com/mcneel/opennurbs) at a pinned commit
# of the 8.x branch into third_party/opennurbs. It isn't committed (see .gitignore): run this once
# before native/build_opennurbs.sh. ONURBS_TARBALL=path uses an archive already downloaded.
set -euo pipefail
HERE="${0:A:h}"
SHA=eb92af3ba1806b0a34a99aba0d3bda83e3d46083
DEST="$HERE/third_party/opennurbs"
[[ -f "$DEST/opennurbs.h" ]] && { echo "openNURBS already in $DEST"; exit 0; }
TMP=$(mktemp -d)
TAR=${ONURBS_TARBALL:-$TMP/opennurbs.tar.gz}
[[ -f "$TAR" ]] || curl -sL --fail -o "$TAR" "https://codeload.github.com/mcneel/opennurbs/tar.gz/$SHA"
mkdir -p "$DEST"
tar -xzf "$TAR" -C "$TMP"
SRC="$TMP/opennurbs-$SHA"
# The library itself and its zlib: no examples, fonts, projects or test files.
cp "$SRC"/opennurbs*.h "$SRC"/opennurbs*.cpp "$SRC"/LICENSE "$SRC"/makefile "$DEST"/
cp -R "$SRC"/zlib "$DEST"/
[[ -d "$SRC/android_uuid" ]] && cp -R "$SRC"/android_uuid "$DEST"/
echo "$SHA" > "$DEST/PINNED_COMMIT"
rm -rf "$TMP"
echo "openNURBS $SHA in $DEST"
