#!/bin/bash
# Discover a connected iPad (USB or paired network) and print the variables the
# rest of the workflow needs, optionally writing DEVICE into local.env.
#
# Why this exists
# ---------------
# `install.sh` and the game-file push both need the device identifier, and a
# person should not have to read `xcrun devicectl` output and copy a UDID by
# hand. This asks CoreDevice for its JSON, keeps physical iPads, and reports the
# values in the exact form `local.env` and the tools use.
#
# It works over USB and over the network: CoreDevice lists both, and the chosen
# device's link is reported. A device that is paired but asleep may appear as
# not connected; wake it or use the cable.
#
# usage: wolkaraforever/tools/device_variables.sh [options]
#
#   (default)            Show the device and the variables, change nothing.
#   --write              Update DEVICE in local.env (created if absent).
#   --force              With --write, replace a different existing DEVICE.
#   --export             Print shell assignments (eval-able) for scripting.
#   --json               Print the chosen device as JSON.
#   --device NAME|UDID   Choose one device when several are attached.
#   --include-simulators Include simulator devices (off by default).
#   -h, --help           Show this text.
#
# Exit status: 0 found; 2 no device or a usage error.
#
# Nothing is written outside local.env (which is ignored by git). Device
# identifiers stay on this Mac; do not paste this output into a commit or log.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
exec python3 - "$@" <<'PY'
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path.cwd()

HELP = """usage: device_variables.sh [--write [--force]] [--export] [--json]
                          [--device NAME|UDID] [--include-simulators]

Prints the variables for a connected iPad (USB or paired network).
  --write            update DEVICE in local.env
  --force            allow --write to replace a different DEVICE
  --export           print shell assignments
  --json             print the chosen device as JSON
  --device X         choose X (name, UDID or CoreDevice identifier)
  --include-simulators  also consider simulated devices"""


def fail(message, code=2):
    print("device_variables: " + message, file=sys.stderr)
    sys.exit(code)


# ---------------------------------------------------------------- arguments
args = sys.argv[1:]
write = force = export = as_json = include_sim = False
want = None
i = 0
while i < len(args):
    a = args[i]
    if a in ("-h", "--help"):
        print(HELP); sys.exit(0)
    elif a == "--write": write = True
    elif a == "--force": force = True
    elif a == "--export": export = True
    elif a == "--json": as_json = True
    elif a == "--include-simulators": include_sim = True
    elif a == "--device":
        i += 1
        if i >= len(args): fail("--device needs a name or UDID")
        want = args[i]
    else:
        fail("unknown option: " + a)
    i += 1

# ---------------------------------------------------------------- devicectl
# Ask CoreDevice for JSON. Handle the two ordinary failures cleanly: xcrun is
# missing (no Xcode), or devicectl exits non-zero (permissions/usb state).
path = None
try:
    with tempfile.NamedTemporaryFile(prefix="wf-devices-", suffix=".json", delete=False) as tmp:
        path = tmp.name
    try:
        subprocess.run(
            ["xcrun", "devicectl", "list", "devices", "--json-output", path],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=True,
        )
    except FileNotFoundError:
        fail("xcrun was not found. Install Xcode and its command-line tools "
             "(wolkaraforever/tools/install_prerequisites.sh).")
    except subprocess.CalledProcessError as error:
        message = (error.stderr or b"").decode("utf-8", "replace").strip()
        fail("devicectl could not list devices"
             + (": " + message if message else " (is the iPad unlocked and trusted?)"))
    try:
        data = json.loads(Path(path).read_text())
    except (OSError, ValueError) as error:
        fail("could not read the device list: %s" % error)
finally:
    if path:
        try: os.unlink(path)
        except OSError: pass

# ---------------------------------------------------------------- normalise
# CoreDevice has moved these fields under `properties`; the older top-level
# dictionaries still work. Read `properties` first, fall back to the old keys.
def normalise(dev):
    p = dev.get("properties") or {}
    hw = p.get("hardware") or dev.get("hardwareProperties") or {}
    sw = p.get("software") or {}
    conn = p.get("connection") or dev.get("connectionProperties") or {}
    st = p.get("state") or {}
    dp = dev.get("deviceProperties") or {}
    osv = sw.get("osVersionNumber")
    if isinstance(osv, dict):
        osv = osv.get("stringValue")
    return {
        "name": st.get("name") or dp.get("name") or "",
        "udid": hw.get("udid") or "",
        "identifier": dev.get("identifier") or "",
        "model": hw.get("marketingName") or "",
        "product_type": hw.get("productType") or "",
        "platform": hw.get("platform") or "",
        "device_type": hw.get("deviceType") or "",
        "reality": hw.get("reality") or ("simulated" if dev.get("visibilityClass") == "simulators" else "physical"),
        "os": osv or dp.get("osVersionNumber") or "",
        "transport": conn.get("transportType") or "",
        "state": conn.get("state") or dp.get("bootState") or "",
        "pairing": conn.get("pairingState") or "",
    }

devices = []
for dev in (data.get("result") or {}).get("devices", []):
    d = normalise(dev)
    if not d["device_type"].startswith("iPad"):
        continue
    if d["platform"] not in ("iOS", "iPadOS"):
        continue
    if not include_sim and d["reality"] != "physical":
        continue
    if not d["udid"]:
        continue
    devices.append(d)

# Connected first, then by name, so the obvious choice is first.
devices.sort(key=lambda d: (d["state"] != "connected", d["name"]))

if not devices:
    fail("no physical iPad found. Connect one by cable (unlock and tap Trust), "
         "or pair it over the network in Xcode > Window > Devices and Simulators, "
         "and enable Developer Mode on the device.")

# ---------------------------------------------------------------- choose one
chosen = None
if want:
    w = want.lower()
    matches = [d for d in devices
               if w in (d["udid"].lower(), d["identifier"].lower(), d["name"].lower())
               or w in d["name"].lower()]
    if len(matches) == 1:
        chosen = matches[0]
    elif not matches:
        fail("no device matches %r. Available: %s" % (want, ", ".join(d["name"] for d in devices)))
    else:
        fail("several devices match %r: %s" % (want, ", ".join(d["name"] for d in matches)))
elif len(devices) == 1:
    chosen = devices[0]
else:
    connected = [d for d in devices if d["state"] == "connected"]
    if len(connected) == 1:
        chosen = connected[0]
    else:
        fail("several iPads are available; choose one with --device:\n  "
             + "\n  ".join("%s  (%s)" % (d["name"], d["udid"]) for d in devices))

# ---------------------------------------------------------------- bundle id
bundle = os.environ.get("TOLKARA_BUNDLE_ID", "")
if not bundle:
    env_path = ROOT / "local.env"
    if env_path.is_file():
        for line in env_path.read_text(errors="replace").splitlines():
            line = line.strip()
            if line.startswith("TOLKARA_BUNDLE_ID="):
                bundle = line.split("=", 1)[1].strip().strip('"\'')
                break

link = {"wired": "USB", "localNetwork": "Network", "sameMachine": "Simulator"}.get(
    chosen["transport"], chosen["transport"] or "unknown")

if as_json:
    out = dict(chosen)
    out["link"] = link
    out["bundle_id"] = bundle
    print(json.dumps(out, indent=2))
    sys.exit(0)

if export:
    def q(v): return "'" + str(v).replace("'", "'\\''") + "'"
    print("DEVICE=" + q(chosen["udid"]))
    print("DEVICE_NAME=" + q(chosen["name"]))
    print("DEVICE_MODEL=" + q(chosen["model"]))
    print("DEVICE_OS=" + q(chosen["os"]))
    print("DEVICE_CONNECTION=" + q(link))
    if bundle:
        print("TOLKARA_BUNDLE_ID=" + q(bundle))
    sys.exit(0)

print("Device: %s" % chosen["name"])
print("  UDID:     %s" % chosen["udid"])
print("  Model:    %s (%s)" % (chosen["model"], chosen["product_type"]))
print("  OS:       %s" % chosen["os"])
print("  Link:     %s" % link)
print("  State:    %s%s" % (chosen["state"], " (" + chosen["pairing"] + ")" if chosen["pairing"] else ""))
print("")
print("Variables for local.env (ignored by git):")
print("  DEVICE=%s" % chosen["udid"])
if bundle:
    print("  TOLKARA_BUNDLE_ID=%s" % bundle)
else:
    print("  TOLKARA_BUNDLE_ID=<set your own bundle identifier>")
print("  DEVICE_NAME=%s" % chosen["name"])
print("  DEVICE_MODEL=%s" % chosen["model"])
print("  DEVICE_OS=%s" % chosen["os"])
print("  DEVICE_CONNECTION=%s" % link)

# ---------------------------------------------------------------- --write
if write:
    env_path = ROOT / "local.env"
    if env_path.is_file():
        lines = env_path.read_text(errors="replace").splitlines()
    else:
        example = ROOT / "local.env.example"
        lines = (example.read_text(errors="replace").splitlines()
                 if example.is_file()
                 else ["# Local settings for WolkaraForever. Ignored by git.", ""])
    current = None
    for line in lines:
        s = line.strip()
        if s.startswith("DEVICE="):
            current = s.split("=", 1)[1].strip().strip('"\'')
            break
    if current and current != chosen["udid"] and not force:
        fail("local.env already has a different DEVICE (%s). Pass --force to replace it." % current)
    replaced = False
    for n, line in enumerate(lines):
        if line.strip().startswith("DEVICE="):
            lines[n] = "DEVICE=" + chosen["udid"]
            replaced = True
            break
    if not replaced:
        if not lines:
            lines = ["# Local settings for WolkaraForever. Ignored by git.", ""]
        lines.append("DEVICE=" + chosen["udid"])
    tmp = env_path.with_name(env_path.name + ".tmp")
    tmp.write_text("\n".join(lines) + "\n")
    os.replace(tmp, env_path)
    print("")
    print("Wrote DEVICE=%s to %s" % (chosen["udid"], env_path))
PY
