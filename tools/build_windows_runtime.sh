#!/bin/bash
# Build the Windows-application runtime for arm64 macOS: Wine with the ARM64EC,
# aarch64 and i386 architectures, plus FEX's Windows-side emulator modules
# (libarm64ecfex.dll for x86-64 code, libwow64fex.dll for x86 code), assembled
# into build/windows-runtime/Wine. The same files run natively on an Apple
# silicon Mac (for validation, no Rosetta) and, once Tolkara hosts them, on the
# iPad. See docs/WINDOWS.md. Wine is LGPL, FEX is MIT; nothing here is part of
# any application.
#
# First version: the Wine tree and FEX build have not yet been exercised on a
# macOS host with arm64ec in this repository, so expect to iterate on the
# configure step. Each stage leaves a marker so a rerun resumes where it stopped.
#
# Variables (environment or local.env): WINE_REPO, WINE_BRANCH, FEX_REPO,
# FEX_BRANCH, LLVM_MINGW_VERSION, JOBS.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[ -f local.env ] && { . tools/localenv.sh; tolkara_load_env; }
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
# Proton's Wine (ValveSoftware/wine, experimental_11.0) carries bylaws' ARM64EC
# patches and the FEX unixlib loader; bylaws/wine upstream-arm64ec is the
# leaner upstream-based alternative.
WINE_REPO="${WINE_REPO:-https://github.com/ValveSoftware/wine.git}"
WINE_BRANCH="${WINE_BRANCH:-experimental_11.0}"
FEX_REPO="${FEX_REPO:-https://github.com/FEX-Emu/FEX.git}"
FEX_BRANCH="${FEX_BRANCH:-main}"
LLVM_MINGW_VERSION="${LLVM_MINGW_VERSION:-20260922}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
OUT="$ROOT/build/windows-runtime"
SRC="$OUT/src"
MINGW="$OUT/llvm-mingw"
RUNTIME="$OUT/Wine"
mkdir -p "$OUT" "$SRC"

step() { printf '\n==> %s\n' "$*"; }
need_brew() {
    local missing=()
    for formula in "$@"; do brew list --formula "$formula" >/dev/null 2>&1 || missing+=("$formula"); done
    if [ ${#missing[@]} -gt 0 ]; then echo "error: install the build dependencies first: brew install ${missing[*]}"; exit 1; fi
}

step "Checking the host toolchain"
xcrun --sdk macosx --show-sdk-path >/dev/null || { echo "error: Xcode with the macOS SDK is required (DEVELOPER_DIR=$DEVELOPER_DIR)"; exit 1; }
need_brew bison pkgconf freetype gnutls cmake ninja
# macOS ships bison 2.3; Wine wants 3.0 or later.
export PATH="$(brew --prefix bison)/bin:$PATH"

step "LLVM mingw-w64 toolchain (PE compiler for the arm64ec, aarch64 and i386 Windows sides)"
if [ ! -x "$MINGW/bin/arm64ec-w64-mingw32-clang" ]; then
    TARBALL="llvm-mingw-$LLVM_MINGW_VERSION-ucrt-macos-universal.tar.xz"
    if [ ! -f "$OUT/$TARBALL" ]; then
        curl -L --fail -o "$OUT/$TARBALL" "https://github.com/mstorsjo/llvm-mingw/releases/download/$LLVM_MINGW_VERSION/$TARBALL"
    fi
    rm -rf "$MINGW"; mkdir -p "$MINGW"
    tar -xJf "$OUT/$TARBALL" -C "$MINGW" --strip-components=1
fi
"$MINGW/bin/arm64ec-w64-mingw32-clang" --version | head -1

step "Sources"
if [ ! -d "$SRC/wine/.git" ]; then git clone --depth 1 --branch "$WINE_BRANCH" "$WINE_REPO" "$SRC/wine"; fi
if [ ! -d "$SRC/FEX/.git" ]; then git clone --depth 1 --recurse-submodules --shallow-submodules --branch "$FEX_BRANCH" "$FEX_REPO" "$SRC/FEX"; fi
(cd "$SRC/wine" && git log -1 --format='wine %h %s')
(cd "$SRC/FEX" && git log -1 --format='FEX %h %s')

step "FEX Windows-side emulator modules"
build_fex() {  # triple, output name
    local triple=$1 name=$2 dir="$OUT/fex-$1" built
    if [ -f "$OUT/$name" ]; then echo "$name already built"; return; fi
    # The FEX toolchain file finds <triple>-clang in PATH; put llvm-mingw first
    # for this step only (its ar/ranlib would otherwise shadow the host's).
    PATH="$MINGW/bin:$PATH" cmake -G Ninja -S "$SRC/FEX" -B "$dir" \
        -DCMAKE_TOOLCHAIN_FILE="$SRC/FEX/Data/CMake/toolchain_mingw.cmake" -DMINGW_TRIPLE="$triple" \
        -DCMAKE_BUILD_TYPE=Release -DENABLE_LTO=False -DENABLE_JEMALLOC_GLIBC_ALLOC=False -DBUILD_TESTING=False -DTUNE_CPU=none
    PATH="$MINGW/bin:$PATH" cmake --build "$dir" -j "$JOBS"
    built="$(find "$dir" -name "$name" -type f | head -1)"
    [ -n "$built" ] || { echo "error: $name not produced; see $dir"; exit 1; }
    cp "$built" "$OUT/$name"
}
build_fex arm64ec-w64-mingw32 libarm64ecfex.dll
build_fex aarch64-w64-mingw32 libwow64fex.dll

step "Wine for arm64 macOS (arm64ec, aarch64 and i386 Windows sides)"
WINE_BUILD="$OUT/wine-build"; mkdir -p "$WINE_BUILD"
if [ ! -f "$WINE_BUILD/.configured" ]; then
    MACSDK="$(xcrun --sdk macosx --show-sdk-path)"
    # Wine's configure builds the Unix side with the host clang and every PE
    # side with the mingw clang it is pointed at. No X11, ALSA or PulseAudio on
    # macOS; CoreAudio and the Mac driver are detected. Vulkan (MoltenVK) and
    # GStreamer are left to autodetection for now.
    (cd "$WINE_BUILD" && CC="xcrun clang" CXX="xcrun clang++" \
        CFLAGS="-isysroot $MACSDK -mmacosx-version-min=14.0" LDFLAGS="-isysroot $MACSDK" \
        "$SRC/wine/configure" --prefix="$RUNTIME" --enable-archs=arm64ec,aarch64,i386 \
        --with-mingw="$MINGW/bin/clang" --disable-tests --without-x --without-alsa --without-pulse --without-oss \
        2>&1 | tee "$OUT/wine-configure.log")
    touch "$WINE_BUILD/.configured"
fi
if [ ! -f "$WINE_BUILD/.built" ]; then
    (cd "$WINE_BUILD" && make -j "$JOBS" 2>&1 | tee "$OUT/wine-build.log" | grep -E '^(make|.*error)' || true)
    [ -x "$WINE_BUILD/loader/wine" ] || { echo "error: Wine did not build; see $OUT/wine-build.log"; exit 1; }
    touch "$WINE_BUILD/.built"
fi
rm -rf "$RUNTIME"
(cd "$WINE_BUILD" && make install >"$OUT/wine-install.log" 2>&1)
# The emulator modules go where Wine looks for aarch64 PE builtins.
cp "$OUT/libarm64ecfex.dll" "$OUT/libwow64fex.dll" "$RUNTIME/lib/wine/aarch64-windows/"
# The runtime must be self-contained on the iPad: Homebrew libraries the Unix
# side links are copied beside it and their install names rewritten.
step "Bundling Homebrew libraries the Unix side links"
mkdir -p "$RUNTIME/lib"
bundle() {  # binary
    otool -L "$1" | awk 'NR>1{print $1}' | grep -E "^$(brew --prefix)/" | while read -r lib; do
        local name; name="$(basename "$lib")"
        [ -f "$RUNTIME/lib/$name" ] || { cp "$lib" "$RUNTIME/lib/$name"; chmod u+w "$RUNTIME/lib/$name"; bundle "$RUNTIME/lib/$name"; }
        install_name_tool -change "$lib" "@rpath/$name" "$1" 2>/dev/null || true
    done
}
for binary in "$RUNTIME"/bin/* "$RUNTIME"/lib/wine/aarch64-unix/*.so "$RUNTIME"/lib/*.dylib; do
    [ -f "$binary" ] && file "$binary" | grep -q Mach-O || continue
    bundle "$binary"
    install_name_tool -add_rpath @loader_path/../lib "$binary" 2>/dev/null || true
    install_name_tool -add_rpath @loader_path/../.. "$binary" 2>/dev/null || true
done
for f in "$RUNTIME"/bin/* "$RUNTIME"/lib/*.dylib "$RUNTIME"/lib/wine/aarch64-unix/*.so; do
    [ -f "$f" ] && file "$f" | grep -q Mach-O && codesign -f -s - "$f" >/dev/null 2>&1 || true
done
step "Runtime assembled in $RUNTIME"
file "$RUNTIME/bin/wine"
ls "$RUNTIME/lib/wine/"
du -sh "$RUNTIME"
echo "Next: python3 profiles/heroes3-hota/install.py --installer <your GOG setup .exe> --stage-only"
