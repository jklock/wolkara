# Security

Tolkara's authorization module handles pairing keys and talks to the iPad's
developer service, and its loader parses untrusted binary input. Please report
vulnerabilities privately, by email to vk@tolkara.org or through GitHub's "Report a
vulnerability" form on this repository, rather than in a public issue. Include the affected file, the input
or sequence that triggers the problem, and the device and OS version.

In scope: memory-safety bugs in the Mach-O, nib, shader-container or protocol
parsers; anything that lets pairing keys leave the device-only Keychain; any way
the local tunnel could carry traffic other than its single private route; any
path by which application code could run before debugger detachment is confirmed.

Out of scope: the fact that a development-signed app can execute unsigned code
after the developer service prepares memory. That is documented platform
behaviour for development and the basis of the project.

Never post pairing records, provisioning profiles, device identifiers or logs
containing account information in issues.
