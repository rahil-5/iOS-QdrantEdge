#!/usr/bin/env bash
#
# Builds Qdrant Edge for iOS and installs it as the local `QdrantEdge` Swift package
# the app depends on (Packages/QdrantEdge).
#
# Qdrant does not publish a Swift package yet. Its Swift SDK is an open pull request
# (qdrant/qdrant#9979) on top of the merged UniFFI crate `qdrant-edge-ffi`, so this
# builds that crate from a pinned commit of the pull request's branch. Bump
# QDRANT_COMMIT deliberately: the Swift API is generated, and Qdrant Edge is in beta.
#
# Produces, both git-ignored because they are large and fully reproducible:
#   Packages/QdrantEdge/QdrantEdge.xcframework          ios-arm64 + ios-arm64-simulator
#   Packages/QdrantEdge/Sources/QdrantEdge/QdrantEdge.swift   the generated binding
#
# Requirements: Xcode, rustup, perl. Rust targets are installed on demand.
# The Cargo build directory lives in .build/qdrant-edge (several GB; safe to delete).
#
# Usage: Scripts/build-qdrant-edge.sh [--prune] [--clean]
#   --prune   delete per-target intermediates after each slice is copied out, for
#             machines short on disk.
#   --clean   rebuild every slice. Otherwise a slice already built from this commit
#             is reused, so regenerating the package takes seconds, not minutes.

set -euo pipefail

QDRANT_REMOTE="https://github.com/DenisovAV/qdrant.git"
QDRANT_COMMIT="5a516ea05afe2dcd94baf01e75412eea206e8df7"
# The workspace needs nightly (unstable std features in lib/common). Pinned to a
# dated nightly so a rebuild produces the same library.
TOOLCHAIN="${QDRANT_EDGE_TOOLCHAIN:-nightly-2026-10-01}"
TARGETS=("aarch64-apple-ios-sim" "aarch64-apple-ios")

PRUNE=false
CLEAN=false
for arg in "$@"; do
    case "$arg" in
        --prune) PRUNE=true ;;
        --clean) CLEAN=true ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${QDRANT_EDGE_WORK:-$ROOT/.build/qdrant-edge}"
SRC="$WORK/src"
STAGE="$WORK/stage"
PACKAGE="$ROOT/Packages/QdrantEdge"
LIB="libqdrant_edge_ffi.a"

# Matches the app's deployment target. rustc otherwise defaults Apple targets to a
# very old OS while cc-built C dependencies use the current SDK, and the link fails.
export IPHONEOS_DEPLOYMENT_TARGET=26.0
unset CARGO_TARGET_DIR CARGO_BUILD_TARGET_DIR

for tool in rustup xcodebuild perl git; do
    command -v "$tool" >/dev/null || { echo "error: '$tool' not found" >&2; exit 1; }
done
CARGO="$(rustup which --toolchain "$TOOLCHAIN" cargo)"

echo "==> Toolchain $TOOLCHAIN, targets ${TARGETS[*]}"
rustup toolchain install "$TOOLCHAIN" --profile minimal >/dev/null
rustup target add --toolchain "$TOOLCHAIN" "${TARGETS[@]}"

echo "==> Source at $QDRANT_COMMIT"
if [ "$(git -C "$SRC" rev-parse HEAD 2>/dev/null)" != "$QDRANT_COMMIT" ]; then
    rm -rf "$SRC"
    git init -q "$SRC"
    git -C "$SRC" remote add origin "$QDRANT_REMOTE"
    git -C "$SRC" fetch -q --depth 1 origin "$QDRANT_COMMIT"
    # The repository keeps test fixtures in Git LFS; none are needed to build.
    GIT_LFS_SKIP_SMUDGE=1 git -C "$SRC" -c filter.lfs.smudge= -c filter.lfs.process= \
        -c filter.lfs.required=false checkout -q -f FETCH_HEAD
fi

# `PATH` is extended so the build scripts' nested `cargo`/`rustc` calls resolve to
# the pinned toolchain rather than whatever rustup's default happens to be.
export PATH="$(dirname "$CARGO"):$PATH"
export RUSTUP_TOOLCHAIN="$TOOLCHAIN"

# Staged slices are only reusable if they came from this commit.
if $CLEAN || [ "$(cat "$STAGE/commit" 2>/dev/null)" != "$QDRANT_COMMIT" ]; then
    rm -rf "$STAGE"
fi
rm -rf "$STAGE/headers" "$STAGE/bindings"
mkdir -p "$STAGE/headers"
echo "$QDRANT_COMMIT" > "$STAGE/commit"

for target in "${TARGETS[@]}"; do
    if [ -f "$STAGE/$target/$LIB" ]; then
        echo "==> Reusing $target"
        continue
    fi
    echo "==> Building $target"
    # --no-default-features drops the O(n²) `search_matrix` op, as Qdrant's own
    # mobile build does.
    "$CARGO" build --locked --profile release-mobile --no-default-features \
        --lib --package qdrant-edge-ffi --target "$target" \
        --manifest-path "$SRC/Cargo.toml"
    mkdir -p "$STAGE/$target"
    cp "$SRC/target/$target/release-mobile/$LIB" "$STAGE/$target/$LIB"
    if $PRUNE; then
        rm -rf "$SRC/target/$target/release-mobile/deps" "$SRC/target/$target/release-mobile/build"
    fi
done

echo "==> Generating the Swift binding"
# Library mode runs `cargo metadata` in the working directory, so it has to be run
# from inside the Qdrant workspace.
(cd "$SRC" && "$CARGO" run --locked --package qdrant-edge-ffi-bindgen --bin uniffi-bindgen -- \
    generate --library "$STAGE/${TARGETS[0]}/$LIB" --language swift --out-dir "$STAGE/bindings")

"$SRC/lib/edge/swift/demote-ffi-internals.sh" "$STAGE/bindings/qdrant_edge_ffi.swift"
cp "$STAGE/bindings/qdrant_edge_ffiFFI.h" "$STAGE/headers/QdrantEdgeFFI.h"
cat > "$STAGE/headers/module.modulemap" <<'MODULEMAP'
module qdrant_edge_ffiFFI {
    header "QdrantEdgeFFI.h"
    link "qdrant_edge_ffi"
    export *
}
MODULEMAP

echo "==> Assembling the XCFramework"
rm -rf "$PACKAGE/QdrantEdge.xcframework"
xcodebuild -create-xcframework \
    -library "$STAGE/aarch64-apple-ios/$LIB" -headers "$STAGE/headers" \
    -library "$STAGE/aarch64-apple-ios-sim/$LIB" -headers "$STAGE/headers" \
    -output "$PACKAGE/QdrantEdge.xcframework"

mkdir -p "$PACKAGE/Sources/QdrantEdge"
cp "$STAGE/bindings/qdrant_edge_ffi.swift" "$PACKAGE/Sources/QdrantEdge/QdrantEdge.swift"

echo "==> Done"
du -sh "$PACKAGE/QdrantEdge.xcframework"/*/
