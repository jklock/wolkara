# Notices

Tolkara is released under the MIT License. It uses Apple's public SDK frameworks,
the system zlib library and the Python standard library. The experimental WoW
manifest reader includes adaptations described below.

The following public material was consulted as **reference documentation** for
protocols and formats. No code was copied or translated from these projects.

- Remote Pairing protocol description by Jackson Coxson
  (jkcoxson.com/blog/rppairing-spec)
- pymobiledevice3 (GPL-3.0), consulted for RemoteXPC and service-discovery
  message layouts
- StikJIT integration notes (executable-region preparation protocol)
- Apple HomeKit ADK (Apache-2.0), Pair Verify reference
- Apple open-source objc4 headers, for the Objective-C image registration SPI
- LLVM libunwind_ext.h (Apache-2.0 WITH LLVM-exception), for the Darwin dynamic
  unwind-section lookup SPI declarations; registration code is original
- GDB remote serial protocol and LLDB `debugserver` extension documentation
- RFC 9293 (TCP), RFC 8200 (IPv6), RFC 7748 (X25519), RFC 5054 (SRP)

`translation/CoreServices/USKeyMap.h` is a table of the characters produced by
a standard US ANSI keyboard, checked against macOS behaviour. System trust roots
are not stored in this repository; `tools/export_system_anchors.m` exports the
public certificates from the builder's own Mac at build time. The unsigned build
published with releases leaves them out.

If you contribute code derived from another project, say so in the pull request
and add its licence here.

## Experimental WoW launcher

The BLTE, install-manifest and encoding-manifest readers in
`launcher/WoW/Manifest.m` and the archive reader in `launcher/WoW/CASC.m` were adapted using TACTSharp's `BLTE.cs`,
`InstallInstance.cs`, `EncodingInstance.cs` and `IndexInstance.cs` (https://github.com/wowdev/TACTSharp).
This implementation adds bounded parsing, checksum validation and synthetic tests.
TACTSharp itself and its .NET runtime are not bundled. No game files are included.

TACTSharp's MIT licence:

Copyright (c) 2024 Martin Benjamins

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.


The local CASC index format and archive footer reader in `launcher/WoW/CASC.m`
were adapted with reference to CascLib's `CascIndexFiles.cpp` and
`CascStructs.h` (https://github.com/ladislav-zezula/CascLib).
CascLib is not bundled. Public download/storage format documentation was also
consulted at https://github.com/d07RiV/blizzget/wiki; no blizzget code is copied.

`TKWoWJenkins` adapts Bob Jenkins' `lookup3.c` (May 2006, public domain):
https://burtleburtle.net/bob/c/lookup3.c. It is used for the local index's
format checksum, not for cryptographic authentication.

CascLib's MIT licence:

Copyright (c) 2014 Ladislav Zezula

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
