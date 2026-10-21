#!/bin/bash
# Exercise the production Swift extractor and the app's pinned ZIPFoundation.
set -euo pipefail
cd "$(dirname "$0")/../.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
build="$PWD/build/addon-archive"
mkdir -p "$build"
revision=$(sed -n 's/^+    revision: //p' wolkara/patches/0010*.patch)
package=${ZIPFOUNDATION_SOURCE:-$build/ZIPFoundation}
if [ ! -d "$package/.git" ]; then
    git clone --quiet https://github.com/weichsel/ZIPFoundation.git "$package"
    git -C "$package" checkout --quiet "$revision"
fi
[ "$(git -C "$package" rev-parse HEAD)" = "$revision" ] || { echo 'ZIPFoundation revision differs from the app'; exit 1; }
[ -z "$(git -C "$package" status --porcelain)" ] || { echo 'ZIPFoundation checkout is dirty'; exit 1; }
xcrun swiftc -O -emit-library -emit-module -module-name ZIPFoundation \
    "$package"/Sources/ZIPFoundation/*.swift -o "$build/libZIPFoundation.dylib" \
    -emit-module-path "$build/ZIPFoundation.swiftmodule"
python3 wolkara/tools/tests/make_addon_archives.py "$build/fixtures"
for source in AddonStore UpdateLock; do
    xcrun clang -fobjc-arc -Wall -Wextra -Werror -Wno-deprecated-declarations -c "wolkara/WoW/$source.m" -o "$build/$source.o"
done
xcrun clang -fobjc-arc -Wall -Wextra -Werror -Iwolkara/WoW -c wolkara/WoW/tests/test_addon_import.m -o "$build/import.o"
xcrun swiftc -warnings-as-errors -I "$build" -L "$build" -lZIPFoundation \
    -Xlinker -rpath -Xlinker "$build" wolkara/WoW/AddonArchive.swift \
    wolkara/WoW/tests/test_addon_archive.swift "$build/AddonStore.o" "$build/UpdateLock.o" "$build/import.o" -o "$build/test_addon_archive"
"$build/test_addon_archive" "$build/fixtures"
