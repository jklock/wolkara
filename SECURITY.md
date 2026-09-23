# Security

Tolkara's authorization module handles pairing keys and talks to the iPad's
developer service, and its loader parses untrusted binary input. Please report
vulnerabilities privately, by email to vk@tolkara.org or through GitHub's "Report a
vulnerability" form on this repository, rather than in a public issue. Include the affected file, the input
or sequence that triggers the problem, and the device and OS version.

In scope: memory-safety bugs in the Mach-O, nib, shader-container,
code-signature or protocol parsers; anything that lets pairing keys leave the
device-only Keychain; any way the local tunnel could carry traffic other than
its single private route; any path by which application code could run before
debugger detachment is confirmed (Developer service); and, for Local signing,
any way code from the rewritten range could run before its unpack verification,
a container page could run without the container's size, header and load
commands matching the executable, or a write into signed pages could change
them.

Out of scope: the fact that a development-signed app can execute unsigned code
after the developer service prepares memory, or can load a library signed with
the same developer identity. Both are documented platform behaviour for
development and the basis of the two execution modes.

Never post pairing records, provisioning profiles, device identifiers or logs
containing account information in issues.
