#!/bin/bash
# Shared by all tasks. Never silently fall back to the system Swift compiler.
set -euo pipefail

MOUSU_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$MOUSU_ROOT"

if ! command -v mise >/dev/null 2>&1; then
    echo "mise is required. Install it, then run: mise trust && mise install" >&2
    exit 1
fi
if ! MOUSU_TOOLCHAIN="$(mise where swift@6.3.3)"; then
    echo "Could not resolve the pinned toolchain. In this repository, run: mise trust && mise install" >&2
    exit 1
fi

export PATH="$MOUSU_TOOLCHAIN/bin:$MOUSU_TOOLCHAIN/usr/bin:$PATH"
export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
export DEVELOPER_DIR="/Library/Developer/CommandLineTools"
export MACOSX_DEPLOYMENT_TARGET="26.0"
export CLANG_MODULE_CACHE_PATH="$MOUSU_ROOT/.build/ModuleCache"
export SWIFT_MODULECACHE_PATH="$MOUSU_ROOT/.build/ModuleCache"
MOUSU_SWIFT="$MOUSU_TOOLCHAIN/bin/swift"
MOUSU_SWIFTC="$MOUSU_TOOLCHAIN/bin/swiftc"
MOUSU_TRIPLE="arm64-apple-macosx26.0"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
    echo "Mousü currently requires an Apple Silicon Mac." >&2
    exit 1
fi
if [[ ! -x "$MOUSU_SWIFT" || ! -d "$SDKROOT" ]]; then
    echo "Missing pinned Swift toolchain or exact macOS 26.5 SDK: $SDKROOT" >&2
    exit 1
fi
MOUSU_SWIFT_VERSION="$($MOUSU_SWIFT --version)"
if [[ "$MOUSU_SWIFT_VERSION" != *"Swift version 6.3.3 "* ]]; then
    echo "Expected Swift 6.3.3; found: $MOUSU_SWIFT_VERSION" >&2
    exit 1
fi
MOUSU_SDK_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :Version' "$SDKROOT/SDKSettings.plist")"
if [[ "$MOUSU_SDK_VERSION" != "26.5" ]]; then
    echo "Expected macOS SDK 26.5; found $MOUSU_SDK_VERSION" >&2
    exit 1
fi
