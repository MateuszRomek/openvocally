#!/usr/bin/env bash
# Builds whisper.xcframework, a static library, for OpenVocallyKit from pinned whisper.cpp source plus our patch.
# Skips the build when the output matches this script and the patch.

set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage: scripts/whisper/build-xcframework.sh

Builds OpenVocallyKit/Vendor/whisper.xcframework, a static library, from pinned whisper.cpp
source plus the patches in scripts/whisper. Skips the build when the stamp matches this
script and the patches.
EOF
  exit 0
fi
shopt -s nullglob

TAG="v1.9.5"
COMMIT="d1be6fde11ac6e0407606b4e42fe72d34add8037"
MIN_MACOS="15.0"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$ROOT/scripts/whisper"
OUT="$ROOT/OpenVocallyKit/Vendor/whisper.xcframework"
WORK="$ROOT/.build/whisper"
STAMP="$ROOT/OpenVocallyKit/Vendor/whisper.stamp"

patches=("$HERE"/*.patch)
stamp="$(cat "$HERE/build-xcframework.sh" ${patches[@]+"${patches[@]}"} /dev/null | shasum -a 256 | cut -d' ' -f1)"
if [[ -d "$OUT" && -f "$STAMP" && "$(cat "$STAMP")" == "$stamp" ]]; then
  exit 0
fi

echo "[whisper] building whisper.cpp $TAG with ${#patches[@]} patch(es)"
rm -rf "$WORK"
mkdir -p "$WORK"
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$TAG" https://github.com/ggml-org/whisper.cpp.git "$WORK/src"
if [[ "$(git -C "$WORK/src" rev-parse HEAD)" != "$COMMIT" ]]; then
  echo "[whisper] $TAG is not $COMMIT" >&2
  exit 1
fi
for patch in ${patches[@]+"${patches[@]}"}; do
  git -C "$WORK/src" apply "$patch"
done

cmake -S "$WORK/src" -B "$WORK/build" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS" \
  -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF \
  -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_METAL_USE_BF16=ON -DGGML_BLAS_DEFAULT=ON \
  -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF \
  -DCMAKE_C_FLAGS="-Wno-shorten-64-to-32" -DCMAKE_CXX_FLAGS="-Wno-shorten-64-to-32" >"$WORK/build.log" 2>&1 ||
  { tail -20 "$WORK/build.log" >&2; exit 1; }
cmake --build "$WORK/build" --config Release -j "$(sysctl -n hw.ncpu)" >>"$WORK/build.log" 2>&1 ||
  { tail -20 "$WORK/build.log" >&2; exit 1; }

# A static library, not a framework: library validation rejects a separately signed binary when the
# signing certificate has no Team ID, and Xcode embeds a stub dylib for a static framework.
headers_dir="$WORK/Headers"
mkdir -p "$headers_dir"
headers=(whisper.h ggml.h ggml-alloc.h ggml-backend.h ggml-metal.h ggml-cpu.h ggml-blas.h gguf.h)
cp "$WORK/src/include/whisper.h" "$headers_dir/"
for header in "${headers[@]:1}"; do
  cp "$WORK/src/ggml/include/$header" "$headers_dir/"
done
{
  echo "module whisper {"
  for header in "${headers[@]}"; do
    echo "    header \"$header\""
  done
  echo '    link "c++"'
  echo '    link framework "Accelerate"'
  echo '    link framework "Metal"'
  echo '    link framework "Foundation"'
  echo "    export *"
  echo "}"
} >"$headers_dir/module.modulemap"

libs=(
  "$WORK/build/src/libwhisper.a"
  "$WORK/build/ggml/src/libggml.a"
  "$WORK/build/ggml/src/libggml-base.a"
  "$WORK/build/ggml/src/libggml-cpu.a"
  "$WORK/build/ggml/src/ggml-metal/libggml-metal.a"
  "$WORK/build/ggml/src/ggml-blas/libggml-blas.a"
)
libtool -static -no_warning_for_no_symbols -o "$WORK/libwhisper.a" "${libs[@]}"

xcodebuild -create-xcframework -library "$WORK/libwhisper.a" -headers "$headers_dir" \
  -output "$WORK/out/whisper.xcframework" >/dev/null
mkdir -p "$(dirname "$OUT")"
rm -rf "$OUT" "$STAMP"
mv "$WORK/out/whisper.xcframework" "$OUT"
echo "$stamp" >"$STAMP"
echo "[whisper] built $OUT"
