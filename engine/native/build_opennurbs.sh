#!/bin/zsh
# Builds coastline_engine/_opennurbs: openNURBS (fetched by native/get_opennurbs.sh) plus
# native/src/opennurbs_module.cpp, which writes clean B-reps as Rhino .3dm files. The library's
# objects are cached in engine/build/opennurbs, so rebuilding the module is quick.
set -euo pipefail
ENGINE="${0:A:h:h}"
cd "$ENGINE"
ON=native/third_party/opennurbs
[[ -f "$ON/opennurbs.h" ]] || { echo "run native/get_opennurbs.sh first"; exit 1; }
PY="$ENGINE/.venv/bin/python"
SUFFIX=$("$PY" -c "import sysconfig;print(sysconfig.get_config_var('EXT_SUFFIX'))")
PYINC=$("$PY" -c "import sysconfig;print(sysconfig.get_paths()['include'])")
PBINC=$("$PY" -c "import pybind11;print(pybind11.get_include())")
OBJ=build/opennurbs
mkdir -p "$OBJ"
# The makefile's lists of the library's sources and its zlib.
SRCS=($("$PY" -c "
import re; s=open('$ON/makefile').read().replace('\\\\\n',' ')
for n in ('ON_SRC','ZLIB_SRC'):
    m=re.search(r'^'+n+r'\s*=\s*(.*)\$', s, re.M); print(' '.join(m.group(1).split()) if m else '')
"))
FLAGS=(-O2 -fPIC -arch arm64 -fvisibility=hidden -w -D_GNU_SOURCE -DON_COMPILING_OPENNURBS -DOPENNURBS_EXPORTS -DZ_PREFIX -DMY_ZCALLOC -I"$ON" -I"$ON/zlib")
compile() {
  local src=$1 obj="$OBJ/${1//\//_}.o"
  [[ -f "$obj" && "$obj" -nt "$ON/$src" ]] && return 0
  if [[ $src == *.c ]]; then clang -c "${FLAGS[@]}" "$ON/$src" -o "$obj"
  elif [[ $src == *apple* ]]; then clang++ -c -std=c++17 -x objective-c++ "${FLAGS[@]}" "$ON/$src" -o "$obj"
  else clang++ -c -std=c++17 "${FLAGS[@]}" "$ON/$src" -o "$obj"; fi
}
pids=()
for src in $SRCS; do
  compile "$src" &
  pids+=($!)
  if (( ${#pids} >= 10 )); then wait ${pids[1]}; pids=(${pids[2,-1]}); fi
done
wait
OUT="coastline_engine/_opennurbs$SUFFIX"
clang++ -std=c++17 -O2 -fPIC -shared -undefined dynamic_lookup -arch arm64 -fvisibility=hidden -w \
  -DON_COMPILING_OPENNURBS -I"$PYINC" -I"$PBINC" -I"$ON" \
  native/src/opennurbs_module.cpp "$OBJ"/*.o \
  -framework CoreFoundation -framework CoreGraphics -framework CoreText -framework AppKit -o "$OUT"
echo "built $OUT"
