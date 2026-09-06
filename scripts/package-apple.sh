#!/usr/bin/env bash
#
# Builds the C API static libraries for every Apple target and repacks them
# into a dylib xcframework that exports only libsql_* symbols. Bundled SQLite
# symbols stay private so other clients in the host app keep using the system
# libsqlite3 (see CasaZurigo/libsql-swift#1).
set -euo pipefail
trap 'echo "[package-apple] FAILED at line $LINENO: $(sed -n "${LINENO}p" "$0")"' ERR
set -x

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
STAGING_DIR="$DIST_DIR/staging"

# rust's llvm-nm reads current rust object files; the Xcode nm cannot
# (unknown LLVM attribute kinds). llvm-tools installs it under
# <sysroot>/lib/rustlib/<host>/bin, not <sysroot>/bin.
TOOLS_DIR="$(rustc --print sysroot)/lib/rustlib/aarch64-apple-darwin/bin"
if [ ! -x "$TOOLS_DIR/llvm-nm" ]; then
  rustup component add llvm-tools
fi
NM="$TOOLS_DIR/llvm-nm"

rm -rf "$DIST_DIR"
mkdir -p "$STAGING_DIR"

# Only the slices the CasaZurigo app consumes: iOS device + simulator (arm64).
# rust_triple|slice_name|sdk|clang_arch
TARGETS=(
  "aarch64-apple-ios|ios-arm64|iphoneos|arm64"
  "aarch64-apple-ios-sim|ios-arm64-simulator|iphonesimulator|arm64"
)

XCFRAMEWORK_ARGS=()
for entry in "${TARGETS[@]}"; do
  IFS='|' read -r triple slice sdk arch <<< "$entry"

  cargo build --target "$triple" --release
  static_lib="$ROOT_DIR/target/$triple/release/liblibsql.a"
  sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"

  slice_dir="$STAGING_DIR/$slice"
  mkdir -p "$slice_dir/Headers"

  # Export only libsql_*; everything else (bundled sqlite3_*) stays hidden.
  # llvm-nm has no Apple-only -U flag; filter on defined symbol types instead.
  # Keep the leading underscore — the linker's export list needs Mach-O names.
  "$NM" -g "$static_lib" | awk '$3 ~ /^_libsql_/ && $2 ~ /^[TDBSW]/ { print $3 }' | sort -u \
    > "$slice_dir/libsql.exports"

  objects_dir="$slice_dir/objects"
  mkdir -p "$objects_dir"
  (cd "$objects_dir" && ar x "$static_lib")
  find "$objects_dir" -name "*.o" > "$slice_dir/objects.list"

  # Link with the classic Apple ld: the default new ld crashes on current
  # rust object files, and rust's ld64.lld cannot resolve the iOS SDK's
  # text-based re-exports.
  clang -arch "$arch" -dynamiclib -isysroot "$sdk_path" \
    -Wl,-ld_classic \
    -Wl,-filelist,"$slice_dir/objects.list" \
    -Wl,-exported_symbols_list,"$slice_dir/libsql.exports" \
    -Wl,-install_name,@rpath/liblibsql.dylib \
    -o "$slice_dir/liblibsql.dylib"
  rm -rf "$slice_dir/objects" "$slice_dir/objects.list" "$slice_dir/libsql.exports"

  cp "$ROOT_DIR/libsql.h" "$slice_dir/Headers/libsql.h"

  # Match the module map that upstream's packaging ships per slice.
  printf 'module CLibsql {\n    header "libsql.h"\n    export *\n}\n' \
    > "$slice_dir/Headers/module.modulemap"

  XCFRAMEWORK_ARGS+=(
    -library "$slice_dir/liblibsql.dylib"
    -headers "$slice_dir/Headers"
  )
done

xcodebuild -create-xcframework \
  "${XCFRAMEWORK_ARGS[@]}" \
  -output "$DIST_DIR/CLibsql.xcframework"

rm -rf "$STAGING_DIR"
cd "$DIST_DIR"
zip -qry CLibsql.xcframework.zip CLibsql.xcframework
shasum -a 256 CLibsql.xcframework.zip > CLibsql.xcframework.zip.sha256

echo "[package-apple] done: $DIST_DIR/CLibsql.xcframework.zip"
