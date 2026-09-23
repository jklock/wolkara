# Architecture

Tolkara has the same shape as Wine: a loader that places an unmodified program
in memory, and a set of libraries that implement the operating-system interface
that program expects. macOS and iPadOS share a CPU architecture, a kernel, an
Objective-C runtime and most low-level frameworks, so far less needs translating
than between Windows and Linux. The work is in the parts that differ: process
loading, executable memory, the desktop UI frameworks and the shader format.

```
  original macOS executable (data, unchanged)
                 │ loaded by                 executable memory, one of:
        ┌────────▼────────┐                ┌──────────────────────────────┐
        │    runtime/     │◄───────────────┤ Developer service:           │
        └────────┬────────┘                │   authorization/             │
                 │ imports resolve to      │ Local signing: signed page   │
        ┌────────▼────────┐                │   container (SignedImage)    │
        │  translation/   │                └──────────────────────────────┘
        └────────┬────────┘
                 │ calls
          iPadOS frameworks (UIKit, Metal, AVFAudio, Security, …)
```

## runtime/: the loader

- `GuestImage` parses thin and fat arm64 `MH_EXECUTE` files with bounds checks
  and maps segments at their preferred addresses in a guest address space.
- `GuestFixups` applies dyld rebases and binds. Binds resolve through a short
  table of loader-owned functions (listed in the README), then the translation
  library mapped for that import, then the process's own symbols.
- `NativeCodeMemory` (Developer service) holds the image in memory with two
  views: a read-write view used for loading and for the program's own later
  code writes, and a read-execute view the CPU runs from. The executable view is
  never writable.
- `SignedImage` (Local signing) checks a signed page container against the
  executable before any of its pages are used; see below.
- `GuestTLS` provides macOS thread-local variables. `NativeGuest` registers the
  image's Objective-C metadata with the runtime, runs the original initializers
  in order, and calls the original `main`.
- `GuestModule` and `tools/package_guest.py` import an executable as a separate,
  hash-verified module under Documents. It refuses to write into a signed bundle.
- `GuestMemory`, `DarwinMemory` and `GuestCPU` are a software MMU and a scalar
  arm64 interpreter. They are a correctness reference for tests, not the path
  applications run on.

The file on disk is never changed. Rebases, binds and any code the program
unpacks for itself exist only in memory, and, with Local signing, in the signed
page container derived from it.

## translation/: the macOS API layer

`tools/classify.py` reads an executable's import table and sorts every symbol:
present on iPadOS (re-exported from the real framework), hand-written in
`translation/<Framework>/`, or missing. `tools/build_shims.py` then builds one
library per macOS framework. Missing functions become stubs that log their first
call and return zero, which is how new applications reveal what they need.

Hand-written areas today:

- **AppKit** on UIKit: application and event loop, windows and views, keyboard,
  text input, mouse and pointer, cursors, menus, alerts, screens, images, and
  nib loading from metadata extracted by `tools/inspect_nib.py`.
- **Metal**: devices and presentation pass straight through to the iPad GPU.
  macOS shader libraries are validated and rewrapped in an iOS container around
  the unchanged AIR bitcode, and the iPad's own compiler builds the pipelines.
  Unknown formats stop with a message instead of substituting a shader.
- **CoreAudio / AudioToolbox** on AVFAudio, **Carbon / CoreServices** keyboard
  layout services, **CoreGraphics** display queries, and **Security** (system
  trust roots exported from the builder's own Mac at build time, a keychain
  subset, and the legacy CDSA crypto calls on CommonCrypto).

## Executable memory: two modes

iPadOS refuses to execute pages that are not covered by a valid code signature.
Tolkara has two ways to satisfy that, and each user chooses one.

### Developer service (authorization/)

The supported exception to the signature rule is development: when a debugger
prepares memory in a development-signed app, the kernel allows it to become
executable. JIT-based apps have long relied on a Mac or a second app to do this.

Tolkara does it alone. The app embeds a packet-tunnel extension that gives the
app a route to the iPad's own developer service. Over that route it implements
Apple's RemotePairing handshake, the CoreDevice tunnel, RemoteXPC service
discovery and the debugserver wire protocol, all written for this project. It
asks the service to prepare one zero-filled region, verifies the result, and
confirms the debugger has detached **before any application code is copied in
or run**. If any step is uncertain, entry is blocked and the app asks to be
restarted.

Pairing keys are created once by `tools/enroll.sh` and kept in a device-only
Keychain group shared by the app and its extension. The tunnel carries a single
private address; no other traffic is routed and nothing leaves the device.

Protocol detail and the history of what was tried are in
[LOCAL_AUTHORIZATION.md](LOCAL_AUTHORIZATION.md).

### Local signing (runtime/SignedImage)

The application's final `__TEXT` pages go into a *page container*: a minimal
arm64 dylib whose first 16 KiB page is its own header and whose single
16 KiB-aligned section holds those pages byte for byte, with the marker symbols
`tolkara_container_v1` and `tolkara_container_final` at its start.
`tools/build_signed_container.py` builds it from the executable, or, for an
application that rewrites its own code at launch, from a capture of its final
pages, and signs it with the user's identity through `tools/sign_guest_local.m`.
That signer is a `codesign` equivalent written only against Security and
CommonCrypto, so that it can later run on the iPad; today containers are built
and signed on a Mac. The launcher looks for the container at
`Documents/LocalSigning/page-container.dylib`.

At startup the runtime `dlopen`s the container, so the kernel validates its
signature and pages. Before any page is mapped, `SignedImage` checks the layout
and binds the container to the executable: the image must be exactly the size of
the executable's `__TEXT` and start with its header and load commands, byte for
byte, which include `LC_UUID`. Every page after the last one the application
rewrites at launch is identical to the executable's own; those pages, which must
include the application's first initializer, are then `vm_remap`ped from the
container into the arena as read-execute. Every page up to and including the
last rewritten one stays anonymous and writable while that initializer runs. The
runtime then compares what that initializer produced with the container, byte
for byte, and only then replaces the range with the validated pages. Any
difference stops startup before more application code runs, and later writes
into signed pages must reproduce the signed bytes exactly. Custom file mappings
of the container are not executable on iPadOS; only pages dyld has validated
are remapped. No debugger is involved.

## launcher/ and profiles/

The launcher is a small UIKit app: import an executable, choose the execution
mode (asked on first launch, changed with Execution mode…), run diagnostics,
press Play. A profile (`profiles/<id>/profile.json`) is packaged at build time
and supplies the application's display name and the folder and executable path
under Documents. Profiles are data; they cannot carry code or patches.

## Testing

`tools/test_emulation.sh` builds and runs standalone C, Objective-C, Swift and
Python tests with ASan and UBSan: memory semantics, malformed Mach-O input,
fixups, packaging, the pairing, tunnel and debug protocols against independent
peers, the page-container contract, the signer and a macOS end-to-end container
load, shader containers, keyboard and text input, and crypto parity with
macOS. Device behaviour has to be checked on a device; record what you tested
in [COMPATIBILITY.md](../COMPATIBILITY.md).
