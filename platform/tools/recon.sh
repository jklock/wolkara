#!/bin/bash
# Recon of a macOS executable. usage: recon.sh <executable> [outdir=build/recon]
# Raw output stays under build/ (gitignored); only SURFACE.md is meant for the repo.
set -uo pipefail
EXE=$1; OUT=${2:-build/recon}; mkdir -p "$OUT"
cd "$(dirname "$0")/.."
{
echo "== file ==";        file "$EXE"; ls -l "$EXE"
echo "== archs ==";       lipo -archs "$EXE"
echo "== header ==";      otool -arch arm64 -hv "$EXE" | tail -2
echo "== build version =="; otool -arch arm64 -l "$EXE" | grep -A6 -E "LC_BUILD_VERSION|LC_VERSION_MIN"
echo "== segments ==";    otool -arch arm64 -l "$EXE" | awk '/segname/{s=$2} /vmsize/{v=$2} /filesize/{print s, "vmsize", v, "filesize", $2}' | uniq
echo "== fixups/TLS/special load commands =="
otool -arch arm64 -l "$EXE" | grep -E "cmd LC_(DYLD_CHAINED_FIXUPS|DYLD_INFO|DYLD_EXPORTS_TRIE|MAIN|UNIXTHREAD|ENCRYPTION|RPATH|CODE_SIGNATURE|LOAD_WEAK|REEXPORT)" | sort | uniq -c
otool -arch arm64 -l "$EXE" | grep -E "sectname __thread|S_THREAD_LOCAL" | sort | uniq -c
echo "== header room =="
python3 - "$EXE" <<'PY'
import sys, subprocess, re
o = subprocess.run(["otool","-arch","arm64","-l",sys.argv[1]],capture_output=True,text=True).stdout
size = int(re.search(r"sizeofcmds\s+(\d+)", subprocess.run(["otool","-arch","arm64","-h","-v",sys.argv[1]],capture_output=True,text=True).stdout) .group(1)) if False else None
offs = [int(x) for x in re.findall(r"\n\s+offset (\d+)", o) if int(x) > 0]
hdr = subprocess.run(["otool","-arch","arm64","-h",sys.argv[1]],capture_output=True,text=True).stdout.split("\n")[-2].split()
print("sizeofcmds", hdr[6], "first section offset", min(offs), "free", min(offs) - 32 - int(hdr[6]))
PY
echo "== rpaths ==";      otool -arch arm64 -l "$EXE" | grep -A2 LC_RPATH | grep path
echo "== linked libraries =="; otool -arch arm64 -L "$EXE"
echo "== code signature =="; codesign -dvvv --entitlements - "$EXE" 2>&1 | grep -vE "^Hash|CandidateCDHash|^CDHash"
echo "== import count =="; dyld_info -arch arm64 -imports "$EXE" | grep -c "(from"
} > "$OUT/recon.txt" 2>&1
python3 tools/classify.py "$EXE" --out SURFACE.md
echo "report: $OUT/recon.txt"
