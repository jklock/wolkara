#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/emulation
xcrun clang -fobjc-arc -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined \
    -Iauthorization/App -framework Foundation authorization/App/LocalServiceRetry.m \
    tests/test_local_service_retry.m -o build/emulation/test_local_service_retry
build/emulation/test_local_service_retry
xcrun clang -fobjc-arc -Wall -Wextra -Werror -Iauthorization/Pairing -c authorization/Pairing/TunnelTLS.m -o build/emulation/TunnelTLS.o
xcrun clang -std=c11 -Wall -Wextra -Werror -c authorization/Control/ArenaControl.c -o build/emulation/RetryArenaControl.o
xcrun clang -std=c11 -Wall -Wextra -Werror -c authorization/DebugWire.c -o build/emulation/RetryDebugWire.o
xcrun swiftc -module-cache-path build/swift-module-cache -warnings-as-errors -g -sanitize=address -import-objc-header authorization/Transport/TransportBridge.h authorization/Pairing/*.swift authorization/Storage/*.swift authorization/Transport/*.swift authorization/Debugger/*.swift authorization/Tunnel/LocalPacketTCPProxy.swift authorization/Tunnel/PacketServiceProbe.swift build/emulation/TunnelTLS.o build/emulation/RetryArenaControl.o build/emulation/RetryDebugWire.o tests/test_packet_service_retry.swift -o build/emulation/test_packet_service_retry
build/emulation/test_packet_service_retry
