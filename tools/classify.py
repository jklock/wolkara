#!/usr/bin/env python3
"""Classify a macOS binary's import surface against the iPhoneOS SDK.

usage: classify.py <macOS executable>... [--sdk PATH] [--out SURFACE.md] [--map build/guest-map.json]
                   [--raw build/surface.json]

With several executables the surface is their union, so one set of
compatibility libraries serves every application in the launcher's library.

Per symbol:   present | elsewhere (exported on iOS, but by a different library) | missing
Per library:  system  (all symbols present -> only the path layout is rewritten)
              reexport-shim (library exists on iOS but lacks some symbols -> shim adds them and re-exports the real one)
              full-shim (library does not exist on iOS)
SURFACE.md contains symbol *names* of Apple APIs only; nothing from the binary itself.
"""
import argparse, collections, json, os, re, subprocess, sys

DEFAULT_SDK = "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk"
KEYS = {"symbols": "", "weak-symbols": "", "thread-local-symbols": "",
        "objc-classes": "_OBJC_CLASS_$_", "objc-eh-types": "_OBJC_EHTYPE_$_", "objc-ivars": "_OBJC_IVAR_$_"}


REEXPORTS = {}   # install name -> [install names it re-exports]
TBD_PATH = {}    # install name -> .tbd file


def parse_tbd(path):
    """-> {install_name: set(symbols)} for every document in the .tbd (v4 text)."""
    text = open(path, errors="replace").read()
    out = {}
    for doc in text.split("--- !tapi-tbd")[1:]:
        m = re.search(r"install-name:\s*'?([^'\n]+)'?", doc)
        if not m:
            continue
        syms = out.setdefault(m.group(1).strip(), set())
        TBD_PATH.setdefault(m.group(1).strip(), path)
        for lst in re.findall(r"reexported-libraries:.*?libraries:\s*\[(.*?)\]", doc, re.S):
            REEXPORTS.setdefault(m.group(1).strip(), []).extend(x.strip().strip("'\"") for x in lst.split(","))
        exports = doc.split("\nexports:", 1)
        body = exports[1] if len(exports) > 1 else ""
        body = re.split(r"\n(?:reexports|undefineds):", body)[0] + "".join(re.findall(r"\nreexports:(.*?)(?=\n\w|\Z)", doc, re.S))
        for key, prefix in KEYS.items():
            for lst in re.findall(r"\b" + key + r":\s*\[(.*?)\]", body, re.S):
                for s in lst.split(","):
                    s = s.strip().strip("'\"")
                    if s and not s.startswith("$ld$"):
                        syms.add(prefix + s)
                        if key == "objc-classes":
                            syms.add("_OBJC_METACLASS_$_" + s)
    return out


def load_sdk(sdk):
    libs = {}
    for root, _, files in os.walk(sdk):
        if "/PrivateFrameworks" in root:
            continue
        for f in files:
            if f.endswith(".tbd"):
                for name, syms in parse_tbd(os.path.join(root, f)).items():
                    libs.setdefault(name, set()).update(syms)
    # fold re-exported libraries into their umbrella, transitively
    def closure(name, seen):
        for r in REEXPORTS.get(name, []):
            if r not in seen:
                seen.add(r); closure(r, seen)
        return seen
    for name in list(libs):
        for r in closure(name, set()):
            libs[name] = libs[name] | libs.get(r, set())
    return libs


def lazy_symbols(exe):
    """Symbols bound through __la_symbol_ptr are functions; everything else is treated as data."""
    r = subprocess.run(["dyld_info", "-arch", "arm64", "-fixups", exe], capture_output=True, text=True)
    out, any_lazy = set(), False
    for line in r.stdout.splitlines():
        f = line.split()
        if len(f) >= 5 and f[3] == "lazy-bind":
            out.add(f[4].split("/", 1)[1]); any_lazy = True
    return out if any_lazy else None   # None: chained fixups, no lazy info -> name heuristic


def lib_key(install_name):
    """macOS and iOS install names differ in layout; compare by leaf name."""
    return os.path.basename(install_name)


def imports(exe):
    r = subprocess.run(["dyld_info", "-arch", "arm64", "-imports", exe], capture_output=True, text=True)
    res = []
    for line in r.stdout.splitlines():
        m = re.match(r"\s*(?:0x[0-9A-Fa-f]+\s+)?(\S+)\s*(\[weak[-_]import\])?\s*\(from ([^)]+)\)", line)  # ordinal column only with chained fixups
        if m:
            res.append((m.group(1), m.group(3), bool(m.group(2))))
    return res


def linked(exe):
    r = subprocess.run(["otool", "-arch", "arm64", "-L", exe], capture_output=True, text=True)
    return [l.split(" (compat")[0].strip() for l in r.stdout.splitlines()[1:]]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("exe", nargs="+"); ap.add_argument("--sdk", default=DEFAULT_SDK)
    ap.add_argument("--out", default="SURFACE.md"); ap.add_argument("--map", default="build/guest-map.json")
    ap.add_argument("--raw", default="build/surface.json")
    a = ap.parse_args()

    sdk = load_sdk(a.sdk)
    by_leaf = collections.defaultdict(set)
    for name, syms in sdk.items():
        by_leaf[lib_key(name)].update(syms)
    ios_name = {lib_key(n): n for n in sdk if not n.startswith("/usr/lib/swift")}
    everything = set().union(*sdk.values())
    # libSystem re-exports /usr/lib/system/*; treat all of those as libSystem.
    provider = {}
    for name, syms in sdk.items():
        if name.startswith("/usr/lib/swift"):
            continue
        for x in syms:
            if x not in provider or len(name) < len(provider[x]):
                provider[x] = name
    per_lib, plan_syms, seen = collections.OrderedDict(), {}, set()
    for exe in a.exe:
        lazy = lazy_symbols(exe)

        def kind(sym):
            if sym.startswith("_OBJC_CLASS_$_"): return "class"
            if sym.startswith("_OBJC_METACLASS_$_"): return "metaclass"
            if lazy is not None: return "func" if sym in lazy else "data"
            return "data" if re.match(r"_(k[A-Z]|g[A-Z]|NS\w+(Key|Notification|Mode|Name|Type|Number)$|NSApp$)", sym) else "func"

        exe_libs = linked(exe)
        for l in exe_libs:
            if l not in per_lib:
                per_lib[l] = {"present": [], "elsewhere": [], "missing": []}
        leaf_of = {}
        for l in exe_libs:
            leaf_of[re.sub(r"\.(\w+\.)?dylib$", "", lib_key(l))] = l   # dyld_info prints 'libSystem', 'AppKit'
        for sym, frm, weak in imports(exe):
            l = leaf_of.get(frm) or next((x for x in exe_libs if lib_key(x).startswith(frm)), None)
            if l is None:
                per_lib.setdefault(frm, {"present": [], "elsewhere": [], "missing": []}); l = frm
            if (l, sym) in seen:
                continue   # the first executable importing a symbol decides its kind
            seen.add((l, sym))
            have = by_leaf.get(lib_key(l), set())
            # Umbrella frameworks on iOS re-export sub-libraries not modelled here; "elsewhere" is the safety net.
            cls = "present" if sym in have else "elsewhere" if sym in everything else "missing"
            per_lib[l][cls].append(sym + (" (weak)" if weak else ""))
            if cls != "present":
                plan_syms.setdefault(l, []).append([sym, kind(sym), provider.get(sym)])

    mapping, rows, tot, plan = {}, [], collections.Counter(), {}
    shim_name = lambda leaf: "@rpath/ak" + re.sub(r"\.dylib$", "", leaf) + ".dylib"
    for l, c in per_lib.items():
        leaf = lib_key(l)
        n = {k: len(v) for k, v in c.items()}
        tot.update(n)
        exists = leaf in ios_name
        # Export presence does not guarantee desktop-compatible semantics.
        # Hand-written adapters must also be built for otherwise native APIs.
        adapter_dir=os.path.join(os.path.dirname(__file__), '..', 'translation', re.sub(r'\.dylib$', '', leaf))
        has_adapter=os.path.isdir(adapter_dir) and any(name.endswith(('.c','.m')) for name in os.listdir(adapter_dir))
        if l.startswith("@"):
            kind = "bundled"
        elif exists and not c["missing"] and not c["elsewhere"] and not has_adapter:
            kind = "system"; mapping[l] = ios_name[leaf]
        elif exists:
            kind = "reexport-shim"; mapping[l] = shim_name(leaf)
        else:
            kind = "full-shim"; mapping[l] = shim_name(leaf)
        if kind.endswith("shim"):
            real = ios_name.get(leaf)
            plan[leaf] = {"install_name": mapping[l], "real": real, "real_tbd": TBD_PATH.get(real),
                          "symbols": plan_syms.get(l, []),
                          "provider_tbds": sorted({TBD_PATH[p] for _, _, p in plan_syms.get(l, []) if p})}
        rows.append((l, kind, n))

    os.makedirs(os.path.dirname(a.map) or ".", exist_ok=True)
    json.dump(mapping, open(a.map, "w"), indent=1)
    json.dump({"sdk": a.sdk, "translation": plan, "per_lib": per_lib}, open(a.raw, "w"), indent=1)

    with open(a.out, "w") as f:
        f.write("# SURFACE — import surface vs iPhoneOS SDK\n\nGenerated by tools/classify.py; do not edit.\n\n")
        f.write(f"Totals: **{tot['present']} present**, **{tot['elsewhere']} present elsewhere**, **{tot['missing']} missing** "
                f"across {len(per_lib)} linked libraries.\n\n| library | plan | present | elsewhere | missing |\n|---|---|---:|---:|---:|\n")
        for l, kind, n in rows:
            f.write(f"| `{l}` | {kind} | {n['present']} | {n['elsewhere']} | {n['missing']} |\n")
        for l, c in per_lib.items():
            if c["missing"] or c["elsewhere"]:
                f.write(f"\n## {lib_key(l)}\n")
                for k in ("missing", "elsewhere"):
                    if c[k]:
                        f.write(f"\n**{k}** ({len(c[k])})\n\n" + "\n".join(f"- `{s}`" for s in sorted(c[k])) + "\n")
    print(f"present={tot['present']} elsewhere={tot['elsewhere']} missing={tot['missing']} libs={len(per_lib)} -> {a.out}, {a.map}")


if __name__ == "__main__":
    main()
