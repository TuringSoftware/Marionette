#!/bin/bash
# Copyright © 2026 Turing Software, LLC
# SPDX-License-Identifier: Apache-2.0
#
# Builds the third-party code that cannot be compiled as a Swift package target: OpenSSL, which is
# configured by its own Perl scripts. It is built for each platform and packaged as
# Packages/COpenSSL/OpenSSL.xcframework (a static library holding libssl and libcrypto, with
# headers). The other C libraries are compiled from their pinned submodules by SwiftPM.
#
#   Scripts/build-deps.sh            build what is missing or out of date
#   Scripts/build-deps.sh --force    rebuild everything
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

SOURCE="$ROOT/ThirdParty/openssl"
WORK="$ROOT/ThirdParty/build/openssl"
OUTPUT="$ROOT/Packages/COpenSSL/OpenSSL.xcframework"
STAMP_FILE="$ROOT/Packages/COpenSSL/OpenSSL.stamp"
DEPLOYMENT=26.0
JOBS="$(sysctl -n hw.ncpu)"

if [[ ! -f "$SOURCE/Configure" ]]; then
    echo "OpenSSL sources are missing. Run: Scripts/bootstrap.sh" >&2
    exit 1
fi

# name | OpenSSL target | SDK | compiler flags
SLICES=(
    "macos|darwin64-arm64-cc|macosx|-mmacosx-version-min=$DEPLOYMENT"
    "ios|ios64-xcrun|iphoneos|-mios-version-min=$DEPLOYMENT"
    "ios-simulator|iossimulator-arm64-xcrun|iphonesimulator|-mios-simulator-version-min=$DEPLOYMENT"
)
# No visionOS slice: OpenSSL 3.6 has no configuration for it, and its iOS ones reject the SDK.
# Features this project has no use for: fewer features, less code parsing untrusted input.
OPTIONS=(no-shared no-tests no-apps no-docs no-engine no-dso no-async no-ui-console no-comp no-ssl3 no-dtls no-srp no-psk no-idea no-rc5 no-md2 no-mdc2 no-whirlpool no-sm2 no-sm3 no-sm4 no-gost no-zlib)

# The stamp names everything that decides the output; a build is skipped only when it matches.
STAMP="openssl=$(git -C "$SOURCE" rev-parse HEAD) xcode=$(xcodebuild -version | tr '\n' ' ') deployment=$DEPLOYMENT slices=${SLICES[*]} options=${OPTIONS[*]}"
if [[ "${1:-}" != "--force" && -d "$OUTPUT" && -f "$STAMP_FILE" && "$(cat "$STAMP_FILE")" == "$STAMP" ]]; then
    echo "OpenSSL.xcframework is up to date."
    exit 0
fi

rm -rf "$OUTPUT" "$STAMP_FILE"
[[ "${1:-}" == "--force" ]] && rm -rf "$WORK"
mkdir -p "$WORK"
ARGS=()
for slice in "${SLICES[@]}"; do
    IFS='|' read -r name target sdk flags <<<"$slice"
    if ! SDKROOT_PATH="$(xcrun --sdk "$sdk" --show-sdk-path 2>/dev/null)"; then
        echo "==> skipping $name: SDK $sdk is not installed"
        continue
    fi
    build="$WORK/$name"
    install="$WORK/$name-install"
    slice_stamp="$(git -C "$SOURCE" rev-parse HEAD) $slice ${OPTIONS[*]} $(xcodebuild -version | tr '\n' ' ')"
    if [[ -f "$install/libOpenSSL.a" && -f "$install/stamp" && "$(cat "$install/stamp")" == "$slice_stamp" ]]; then
        echo "==> OpenSSL for $name (already built)"
        ARGS+=(-library "$install/libOpenSSL.a" -headers "$install/include")
        continue
    fi
    echo "==> OpenSSL for $name"
    rm -rf "$build" "$install"
    mkdir -p "$build"
    (
        cd "$build"
        export CC="$(xcrun --sdk "$sdk" --find clang)"
        export CROSS_TOP="$(dirname "$(dirname "$SDKROOT_PATH")")"
        export CROSS_SDK="$(basename "$SDKROOT_PATH")"
        # shellcheck disable=SC2086
        "$SOURCE/Configure" "$target" "${OPTIONS[@]}" --prefix="$install" --openssldir="$install/ssl" \
            -isysroot "$SDKROOT_PATH" $flags >configure.log 2>&1
        make -j"$JOBS" build_libs >build.log 2>&1
        make install_dev >install.log 2>&1
    ) || { echo "build failed for $name; see $build/*.log" >&2; tail -20 "$build/build.log" >&2 || true; exit 1; }
    libtool -static -o "$install/libOpenSSL.a" "$install/lib/libssl.a" "$install/lib/libcrypto.a" 2>/dev/null
    echo "$slice_stamp" >"$install/stamp"
    ARGS+=(-library "$install/libOpenSSL.a" -headers "$install/include")
done

xcodebuild -create-xcframework "${ARGS[@]}" -output "$OUTPUT" >/dev/null
echo "$STAMP" >"$STAMP_FILE"
echo "Wrote $OUTPUT"
