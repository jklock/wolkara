# Contributing

Thanks for helping. The most useful contributions are API coverage for a new
application, a compatibility report, and device test results.

## Ground rules

These are not negotiable, because they are what keeps the project a
compatibility layer:

- Never commit third-party application code, assets, shaders, captured memory,
  or anything copied out of macOS or iPadOS. Tests use our own synthetic
  fixtures from `testguest/` and `tests/`.
- Never patch, re-sign or repackage an application's executable. Only Tolkara's
  own code is signed.
- No features that read or change a running application's memory beyond loading
  it, no input automation, and no workarounds for anti-cheat, licence or
  integrity checks. See "Policy" in the [README](README.md).
- Never commit signing teams, device identifiers, pairing records, provisioning
  profiles, credentials, or files from `build/` and `logs/`. Personal settings
  belong in the ignored `local.env`.
- If your change is based on someone else's code, say so and add its licence to
  [NOTICE.md](NOTICE.md). Reading public protocol documentation is fine.

## Workflow

```bash
tools/test_emulation.sh
```

must pass; it enforces `-Wall -Wextra -Werror` and runs under ASan and UBSan.
Add a focused test for memory bounds, malformed input, protocol failures and
adapter behaviour you touch. Tests are standalone executables or Python
`unittest` files named `tests/test_*.{c,m,swift,py}`.

Style: four-space indentation in source files, two in YAML; match the code
around you and do not reformat unrelated lines. Keep the module prefixes
(`gm_`, `gi_`, `ng_` in the runtime, `AK` in the translation layer, `TK` in
authorization).

Pull requests should explain the problem, the resulting behaviour, the commands
you ran with their results, and what is still untested. A simulator pass does
not prove Metal or native-execution behaviour; say which device you tested on.

## Supporting a new application

1. Build with your executable (`GUEST_EXE`); `build/native-*/SURFACE.md` lists
   every macOS symbol it imports and which are missing.
2. Run it and read `Documents/native-guest.log`. Generated stubs log the first
   call to each unimplemented function.
3. Implement what it needs under `translation/<Framework>/`, with a test.
4. Add a profile under `profiles/` and a row in
   [COMPATIBILITY.md](COMPATIBILITY.md).
