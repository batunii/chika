#!/bin/sh
# Builds the Kotlin :shared framework for the platform Xcode is building (Xcode pre-build phase).
#
# Kotlin/Native has no Mac Catalyst target, so for Catalyst we build the macOS framework and rewrite
# the platform in its object file's LC_BUILD_VERSION from macOS to Mac Catalyst. This is safe
# because :shared is pure Kotlin (commonMain, no platform APIs) and only links Foundation/libc, which
# Catalyst shares with macOS. ld refuses the unmodified object ("built for macOS").
set -eu
cd "$SRCROOT/.."
# Xcode doesn't inherit the shell's PATH; fall back to Homebrew's JDK when no system JDK is set up.
if [ -z "${JAVA_HOME:-}" ] && ! /usr/libexec/java_home >/dev/null 2>&1; then
  for jdk in /opt/homebrew/opt/openjdk@17 /opt/homebrew/opt/openjdk; do
    [ -d "$jdk" ] && export JAVA_HOME="$jdk/libexec/openjdk.jdk/Contents/Home" && break
  done
fi

if [ "${IS_MACCATALYST:-NO}" = "YES" ]; then
  ./gradlew :shared:linkReleaseFrameworkMacosArm64
  src=shared/build/bin/macosArm64/releaseFramework/ChikaShared.framework
  dst=shared/build/bin/macCatalystArm64/releaseFramework/ChikaShared.framework
  rm -rf "$dst" && mkdir -p "$(dirname "$dst")" && cp -R "$src" "$dst"
  bin="$PWD/$dst/Versions/A/ChikaShared"
  work=$(mktemp -d)
  (cd "$work" && ar -x "$bin")
  for obj in "$work"/*.o; do
    /usr/bin/python3 - "$obj" <<'PY'
import struct, sys
path = sys.argv[1]
data = bytearray(open(path, "rb").read())
assert struct.unpack_from("<I", data, 0)[0] == 0xFEEDFACF, "not a 64-bit Mach-O object"
ncmds = struct.unpack_from("<I", data, 16)[0]
off, patched = 32, 0
for _ in range(ncmds):
    cmd, size = struct.unpack_from("<II", data, off)
    if cmd == 0x32:  # LC_BUILD_VERSION: platform, minos, sdk
        # PLATFORM_MACCATALYST = 6; Catalyst versions use iOS numbering (16.0 = macOS 13).
        struct.pack_into("<III", data, off + 8, 6, 16 << 16, 18 << 16)
        patched += 1
    off += size
assert patched, "no LC_BUILD_VERSION found"
open(path, "wb").write(data)
PY
  done
  rm "$bin"
  xcrun libtool -static -o "$bin" "$work"/*.o
  rm -rf "$work"
elif [ "$PLATFORM_NAME" = "iphonesimulator" ]; then
  ./gradlew :shared:linkReleaseFrameworkIosSimulatorArm64
else
  ./gradlew :shared:linkReleaseFrameworkIosArm64
fi
