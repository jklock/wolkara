#!/bin/bash
# The Forever UI operations' own tests: the Config.wtf rules and the archive.
#
# The archive tests use the production Swift writer/restorer against the same
# pinned ZIPFoundation the app links. No game, no simulator and no network
# beyond the package clone that the add-on archive test already performs.
set -euo pipefail
cd "$(dirname "$0")/../.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
build="$PWD/build/forever-ui"
mkdir -p "$build"

# Same pin as the app (patch 0010 declares it).
revision=$(sed -n 's/^+    revision: //p' wolkaraforever/patches/0010*.patch)
package=${ZIPFOUNDATION_SOURCE:-build/addon-archive/ZIPFoundation}
if [ ! -d "$package/.git" ]; then
    git clone --quiet https://github.com/weichsel/ZIPFoundation.git "$package"
    git -C "$package" checkout --quiet "$revision"
fi
[ "$(git -C "$package" rev-parse HEAD)" = "$revision" ] || { echo 'ZIPFoundation revision differs from the app'; exit 1; }
[ -z "$(git -C "$package" status --porcelain)" ] || { echo 'ZIPFoundation checkout is dirty'; exit 1; }
if [ ! -f "$build/libZIPFoundation.dylib" ]; then
    xcrun swiftc -O -emit-library -emit-module -module-name ZIPFoundation \
        "$package"/Sources/ZIPFoundation/*.swift -o "$build/libZIPFoundation.dylib" \
        -emit-module-path "$build/ZIPFoundation.swiftmodule"
fi

# The Config.wtf rules.
xcrun clang -fobjc-arc -Wall -Wextra -Werror -Wno-deprecated-declarations \
    -Iwolkaraforever/WoW -c wolkaraforever/WoW/ForeverUI.m -o "$build/ForeverUI.o"
xcrun clang -fobjc-arc -Wall -Wextra -Werror -Wno-deprecated-declarations \
    -Iwolkaraforever/WoW -c wolkaraforever/WoW/tests/test_forever_config.m -o "$build/test_forever_config.o"
xcrun clang -fobjc-arc "$build/ForeverUI.o" "$build/test_forever_config.o" \
    -framework Foundation -o "$build/test_forever_config"
"$build/test_forever_config"

# The archive writer and restorer.
xcrun swiftc -warnings-as-errors -I "$build" -L "$build" -lZIPFoundation \
    -Xlinker -rpath -Xlinker "$build" \
    wolkaraforever/WoW/ForeverUIArchive.swift \
    wolkaraforever/WoW/tests/test_forever_ui_archive.swift \
    -o "$build/test_forever_ui_archive"
"$build/test_forever_ui_archive"
