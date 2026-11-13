#!/bin/sh
# Local workaround for CLT installs containing obsolete private manifest interfaces.
# Uses matching public interfaces in an ignored directory; never edits the toolchain.
set -eu
cd "$(dirname "$0")/.."
dev="$(xcode-select -p)"
manifest="$dev/usr/lib/swift/pm/ManifestAPI"
arch="$(uname -m)"
public="$manifest/PackageDescription.swiftmodule/$arch-apple-macos.swiftinterface"
private="$manifest/PackageDescription.swiftmodule/$arch-apple-macos.private.swiftinterface"
if [ -f "$private" ] && grep -q swiftLanguageModes "$public" && ! grep -q swiftLanguageModes "$private"; then
    libs="$PWD/.build/manifest-libs"
    mkdir -p "$libs/ManifestAPI/PackageDescription.swiftmodule"
    cp "$manifest/libPackageDescription.dylib" "$libs/ManifestAPI/"
    cp "$public" "$libs/ManifestAPI/PackageDescription.swiftmodule/"
    export SWIFTPM_CUSTOM_LIBS_DIR="$libs"
fi
if [ "${1:-}" = test ] && [ -f "$dev/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib" ]; then
    set -- "$@" --disable-xctest -Xswiftc -load-plugin-library -Xswiftc "$dev/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
fi
# The Swift Build engine in this CLT release records the deployment target
# as the linked SDK version. AppKit/SwiftUI then use the pre-Tahoe design.
# Pass both versions explicitly, retaining macOS 14 as the minimum OS.
case "${1:-}" in
    build|test|run)
        sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
        set -- "$@" -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$sdk_version"
        ;;
esac
exec swift "$@"
