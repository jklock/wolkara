#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/wow-launcher
xcrun clang -fobjc-arc -Wall -Wextra -Werror -O1 -g \
    -fsanitize=address,undefined -fno-omit-frame-pointer -framework Foundation -lz \
    launcher/WoW/Manifest.m launcher/WoW/Client.m tests/test_wow_manifest.m \
    -o build/wow-launcher/test_wow_manifest
build/wow-launcher/test_wow_manifest
xcrun clang -fobjc-arc -Wall -Wextra -Werror -O1 -g \
    -fsanitize=address,undefined -fno-omit-frame-pointer -framework Foundation -lz \
    launcher/WoW/Manifest.m launcher/WoW/Client.m tests/test_wow_client.m \
    -o build/wow-launcher/test_wow_client
build/wow-launcher/test_wow_client
xcrun clang -fobjc-arc -Wall -Wextra -Werror -O2 -framework Foundation -lz \
    launcher/WoW/Manifest.m launcher/WoW/Client.m tools/wow_cdn.m \
    -o build/wow-launcher/wow_cdn
