#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/emulation
CC=(xcrun clang -std=c11 -D_DARWIN_C_SOURCE -Wall -Wextra -Werror -O1 -g
    -fsanitize=address,undefined -fno-omit-frame-pointer -Iruntime)
"${CC[@]}" runtime/GuestMemory.c runtime/DarwinMemory.c runtime/MemoryProbe.c tests/test_memory.c -o build/emulation/test_memory
build/emulation/test_memory
"${CC[@]}" runtime/GuestMemory.c runtime/GuestCPU.c runtime/CPUProbe.c runtime/CPUProbeProgram.S tests/test_cpu.c -o build/emulation/test_cpu
build/emulation/test_cpu
"${CC[@]}" -Iauthorization authorization/LocalRoute.c tests/test_local_route.c -o build/emulation/test_local_route
build/emulation/test_local_route
"${CC[@]}" -Iauthorization authorization/DebugWire.c tests/test_debug_wire.c -o build/emulation/test_debug_wire
build/emulation/test_debug_wire
"${CC[@]}" -Iauthorization authorization/Control/ArenaControl.c tests/test_arena_control.c -o build/emulation/test_arena_control
build/emulation/test_arena_control
xcrun swiftc -module-cache-path build/swift-module-cache -warnings-as-errors \
    -g -sanitize=address authorization/Pairing/PairingWire.swift \
    authorization/Debugger/DebugArenaRequest.swift tests/test_debug_request.swift \
    -o build/emulation/test_debug_request
build/emulation/test_debug_request
"${CC[@]}" -c authorization/DebugWire.c -o build/emulation/DebugWire.o
xcrun swiftc -module-cache-path build/swift-module-cache -warnings-as-errors \
    -g -sanitize=address -import-objc-header authorization/Transport/TransportBridge.h \
    authorization/Pairing/PairingWire.swift authorization/Debugger/DebugArenaRequest.swift \
    authorization/Debugger/DebugProtocolWire.swift authorization/Debugger/DebugArenaSession.swift \
    build/emulation/DebugWire.o tools/probe_debug_arena.swift -o build/probe_debug_arena
python3 tests/test_debug_arena_peer.py
xcrun swiftc -module-cache-path build/swift-module-cache -warnings-as-errors \
    -g -sanitize=address authorization/Pairing/*.swift tests/test_pairing.swift \
    -o build/emulation/test_pairing
build/emulation/test_pairing
xcrun swiftc -module-cache-path build/swift-module-cache -warnings-as-errors \
    -g -sanitize=address authorization/Pairing/PairingWire.swift \
    authorization/Pairing/PairingIdentity.swift authorization/Storage/*.swift \
    tests/test_pairing_storage.swift -o build/emulation/test_pairing_storage
build/emulation/test_pairing_storage
xcrun swiftc -module-cache-path build/swift-module-cache -warnings-as-errors \
    -g -sanitize=address authorization/Pairing/*.swift tests/PairingPeerFixture.swift \
    tests/test_pairing_session.swift -o build/emulation/test_pairing_session
build/emulation/test_pairing_session
xcrun swiftc -module-cache-path build/swift-module-cache -warnings-as-errors \
    -g -sanitize=address authorization/Pairing/PairingWire.swift \
    authorization/Transport/CDTunnelWire.swift tests/test_cd_tunnel.swift \
    -o build/emulation/test_cd_tunnel
build/emulation/test_cd_tunnel
xcrun swiftc -module-cache-path build/swift-module-cache -warnings-as-errors \
    -g -sanitize=address authorization/Pairing/PairingWire.swift \
    authorization/Transport/TunnelTCP.swift tests/test_tunnel_tcp.swift \
    -o build/emulation/test_tunnel_tcp
build/emulation/test_tunnel_tcp
xcrun swiftc -module-cache-path build/swift-module-cache -warnings-as-errors -g -sanitize=address \
    authorization/Pairing/PairingWire.swift authorization/Transport/TunnelTCP.swift \
    authorization/Transport/LocalTCPIPv4.swift tests/test_local_tcp_ipv4.swift \
    -o build/emulation/test_local_tcp_ipv4
build/emulation/test_local_tcp_ipv4
xcrun swiftc -module-cache-path build/swift-module-cache -warnings-as-errors \
    -g -sanitize=address authorization/Pairing/PairingWire.swift \
    authorization/Transport/TunnelTCP.swift tools/probe_tunnel_tcp.swift \
    -o build/probe_tunnel_tcp
python3 tests/test_tunnel_tcp_peer.py
xcrun swiftc -module-cache-path build/swift-module-cache -warnings-as-errors \
    -g -sanitize=address authorization/Pairing/PairingWire.swift \
    authorization/Transport/RemoteXPCWire.swift tests/test_remote_xpc.swift \
    -o build/emulation/test_remote_xpc
build/emulation/test_remote_xpc
xcrun swiftc -module-cache-path build/swift-module-cache -warnings-as-errors \
    -g -sanitize=address authorization/Pairing/PairingWire.swift \
    authorization/Transport/RemoteXPCWire.swift authorization/Transport/RemoteDiscovery.swift \
    tools/probe_remote_discovery.swift -o build/probe_remote_discovery
python3 tests/test_remote_discovery_peer.py
xcrun swiftc -module-cache-path build/swift-module-cache -warnings-as-errors \
    -g -sanitize=address authorization/Pairing/PairingWire.swift \
    authorization/Transport/CDTunnelWire.swift authorization/Transport/TunnelTCP.swift \
    authorization/Transport/TunnelStreams.swift tests/test_tunnel_streams.swift \
    -o build/emulation/test_tunnel_streams
build/emulation/test_tunnel_streams
xcrun clang -fobjc-arc -Wall -Wextra -Werror -Iauthorization/Pairing \
    -c authorization/Pairing/TunnelTLS.m -o build/emulation/TunnelTLS.o
for test in tunnel_manager developer_session; do
    xcrun swiftc -module-cache-path build/swift-module-cache -warnings-as-errors \
        -g -sanitize=address -import-objc-header authorization/Transport/TransportBridge.h \
        authorization/Pairing/*.swift authorization/Transport/*.swift \
        build/emulation/TunnelTLS.o "tests/test_${test}.swift" -o "build/emulation/test_${test}"
    "build/emulation/test_${test}"
done
"${CC[@]}" runtime/NativeCodeMemory.c tests/test_native_memory.c -o build/emulation/test_native_memory
build/emulation/test_native_memory
"${CC[@]}" runtime/GuestMemory.c runtime/SignedImage.c tests/test_signed_image.c -o build/emulation/test_signed_image
build/emulation/test_signed_image
"${CC[@]}" -Ilauncher/App launcher/App/SignedFileProbe.c tests/test_signed_file_probe.c -o build/emulation/test_signed_file_probe
build/emulation/test_signed_file_probe
xcrun clang -fobjc-arc -Wall -Wextra -Werror -g -fsanitize=address,undefined \
    -Iruntime -Iauthorization -Iauthorization/App -framework Foundation \
    runtime/NativeCodeMemory.c authorization/Control/ArenaControl.c \
    authorization/App/LocalArenaPublisher.m tests/test_local_arena_publisher.m \
    -o build/emulation/test_local_arena_publisher
build/emulation/test_local_arena_publisher
xcrun clang -fobjc-arc -Wall -Wextra -Werror -g -fsanitize=address,undefined \
    -Iruntime -Iauthorization -Iauthorization/App -framework Foundation \
    authorization/Control/ArenaControl.c authorization/App/LocalArenaPoller.m tests/test_local_arena_poller.m \
    -o build/emulation/test_local_arena_poller
build/emulation/test_local_arena_poller
"${CC[@]}" runtime/GuestWait.c tests/test_guest_wait.c -o build/emulation/test_guest_wait
build/emulation/test_guest_wait
"${CC[@]}" runtime/GuestWait.c tests/test_guest_wait_runloop.c -framework CoreFoundation -o build/emulation/test_guest_wait_runloop
build/emulation/test_guest_wait_runloop
"${CC[@]}" runtime/GuestMemory.c runtime/GuestImage.c runtime/GuestFixups.c tools/guest_probe.c -o build/emulation/guest_probe_sanitized
python3 tests/test_image.py build/emulation/guest_probe_sanitized
python3 tests/test_package.py
python3 tests/test_profile.py
xcrun clang -arch arm64 -x c -o build/emulation/module_fixture - <<'C'
int main(void) { return 42; }
C
xcrun clang -fobjc-arc -Wno-deprecated-declarations -Wall -Wextra -Werror \
    -O1 -g -fsanitize=address,undefined -Iruntime -framework Foundation \
    runtime/GuestModule.m runtime/GuestMemory.c runtime/GuestImage.c tests/test_guest_module.m \
    -o build/emulation/test_guest_module
build/emulation/test_guest_module build/emulation/module_fixture
for auth in 0 1; do   # TolkaraDiagnostics and Tolkara (TOLKARA_INTEGRATED_AUTH)
    xcrun clang -fobjc-arc -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined \
        -DTOLKARA_INTEGRATED_AUTH=$auth -Ilauncher/App -framework Foundation \
        launcher/App/ExecutionMode.m tests/test_execution_mode.m -o "build/emulation/test_execution_mode_$auth"
    "build/emulation/test_execution_mode_$auth"
done
python3 tests/test_publish.py
python3 tests/test_arena_publish.py
python3 tests/test_nib.py
python3 tests/test_metallib.py
python3 - <<'PYFIXTURE'
import sys
from pathlib import Path
sys.path.insert(0,'tests')
from test_metallib import library
data=bytearray(library());data[4:16]=bytes([1,128,2,0,2,0,0,0,0,0,0,0])
Path('build/emulation/container-fixture.metallib').write_bytes(data)
PYFIXTURE
xcrun clang -fobjc-arc -Wall -Wextra -Werror -Wno-deprecated-declarations -g -fsanitize=address,undefined \
    -Itranslation/Metal -framework Foundation translation/Metal/LibraryContainer.m tests/test_library_container.m \
    -o build/emulation/test_library_container
build/emulation/test_library_container build/emulation/container-fixture.metallib
python3 tests/test_shader_translation.py
python3 -m unittest tests.test_sign_guest_local
python3 -m unittest tests.test_build_signed_container

"${CC[@]}" runtime/GuestMemory.c runtime/GuestImage.c runtime/GuestFixups.c tests/test_fixups.c -o build/emulation/test_fixups
build/emulation/test_fixups
"${CC[@]}" runtime/GuestTLS.c runtime/GuestTLSArm64.S tests/test_tls.c tests/test_tls_arm64.S -o build/emulation/test_tls
build/emulation/test_tls

xcrun clang -fobjc-arc -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined \
    -Itranslation/AKSupport -framework Foundation translation/Carbon/Keyboard.m \
    translation/CoreServices/Keyboard.m tests/test_keyboard.m -o build/emulation/test_keyboard
build/emulation/test_keyboard

xcrun clang -fobjc-arc -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined \
    -Itranslation/AKSupport -Itranslation/AppKit -framework Foundation -framework CoreGraphics \
    translation/AKSupport/AKSupport.m translation/AppKit/Images.m tests/test_images.m -o build/emulation/test_images
build/emulation/test_images

xcrun clang -fobjc-arc -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined \
    -Itranslation/AKSupport -framework Foundation translation/AppKit/TextInput.m tests/test_text_input.m \
    -o build/emulation/test_text_input
build/emulation/test_text_input

bash tools/test_legacy_crypto.sh

xcrun clang -fobjc-arc -Wno-deprecated-declarations -framework Foundation -framework Security \
    tools/export_system_anchors.m -o build/emulation/export_system_anchors
build/emulation/export_system_anchors build/emulation/system-roots.plist
xcrun clang -fobjc-arc -Wall -Wextra -Werror -Wno-deprecated-declarations \
    -O1 -g -fsanitize=address,undefined -Itranslation/Security -framework Foundation \
    -framework Security translation/Security/Keychain.m tests/test_system_roots.m \
    -o build/emulation/test_system_roots
build/emulation/test_system_roots build/emulation/system-roots.plist
