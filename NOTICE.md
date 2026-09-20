# Notices

Tolkara is original work released under the MIT License. It bundles and links
no third-party source code or libraries; it uses only Apple's public SDK
frameworks and the Python standard library.

The following public material was consulted as **reference documentation** for
protocols and formats. No code was copied or translated from these projects.

- Remote Pairing protocol description by Jackson Coxson
  (jkcoxson.com/blog/rppairing-spec)
- pymobiledevice3 (GPL-3.0), consulted for RemoteXPC and service-discovery
  message layouts
- StikJIT integration notes (executable-region preparation protocol)
- Apple HomeKit ADK (Apache-2.0), Pair Verify reference
- Apple open-source objc4 headers, for the Objective-C image registration SPI
- GDB remote serial protocol and LLDB `debugserver` extension documentation
- RFC 9293 (TCP), RFC 8200 (IPv6), RFC 7748 (X25519), RFC 5054 (SRP)

`translation/CoreServices/USKeyMap.h` is a table of the characters produced by
a standard US ANSI keyboard, checked against macOS behaviour. System trust roots
are not stored in this repository; `tools/export_system_anchors.m` exports the
public certificates from the builder's own Mac at build time.

If you contribute code derived from another project, say so in the pull request
and add its licence here.
