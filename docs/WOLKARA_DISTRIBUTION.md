# Sharing Wolkara

Assessment: 2026-10-06. Wolkara is a WoW-focused fork of Tolkara. Changing its
name, home screen or distribution channel does not change iOS code-execution
requirements. No public Wolkara IPA, source, notarization submission or Reddit
post has been published as part of this work.

## What is currently demonstrated

The existing personal setup uses Xcode signing, the integrated Developer service
target, Developer Mode and one-time device enrolment. Forever gameplay and
Mac-disconnected reboot/launch were reported on an iPhone 16 Pro Max. Those
reports do not prove cellular-only startup, the latest updater revision, or a
fresh install using another user's signing identity. See [COMPATIBILITY.md](../COMPATIBILITY.md).

The updater can check editions and install patches while open. A first full
real-game download is still unvalidated. The controls editor has simulator and
signed-build coverage; it needs a physical-game session before a release claim.

Normal launches automatically use the route compiled into the app: Developer
service for the integrated target, External JIT for the diagnostics/sideload
target. The home does not offer Local signing or other startup alternatives.
Explicit development arguments retain those tools. Removing the picker does
not remove the route's preparation, enrolment or signing requirements.

## Practical distribution choices

| Route | Installation experience | Wolkara status |
| --- | --- | --- |
| Personal Xcode build | Mac, own developer signing, Developer Mode, initial enrolment | Closest to the setup with recorded gameplay; still a developer workflow. |
| SideStore / AltStore Classic source | Add a source and install an IPA signed through the user's setup; initial setup and execution authorization remain separate | Best candidate for a broader tester pilot, but the External JIT route has not been validated with Wolkara on a device. |
| AltStore PAL source | Marketplace app install and updates | No demonstrated native-execution path for Wolkara. A source alone is insufficient. |

[SideStore's prerequisites](https://docs.sidestore.io/docs/installation/prerequisites)
include a computer for initial installation, an Apple Account and connected
Wi-Fi. Its LocalDevVPN must be active for app installation, updates and refresh.
These are store operations, distinct from downloading WoW content inside Wolkara.

[AltStore Classic's remote-server documentation](https://faq.altstore.io/altstore-classic/remote-altservers)
also describes installing/refreshing without the computer after pairing, using
LocalDevVPN and a connected Wi-Fi network. This does not establish cellular-only
Wolkara launch or solve its executable-memory preparation.

An External JIT build needs an enabler. [StikDebug](https://github.com/StikDebug/StikDebug)
is a candidate: its own instructions require pairing/setup and describe limited
app compatibility on newer iOS releases. We have not tested that combination.
Our loader must still obtain executable memory and confirm debugger detachment
before entering any game code.

[PAL distribution](https://faq.altstore.io/developers/distribute-with-altstore-pal)
requires Apple notarization, marketplace processing and hosting the Alternative
Distribution Package before publishing a source. Our engineering conclusion is
that listing Wolkara there cannot itself authorize execution of downloaded Mac
code. No PAL-compatible execution permission or successful test is claimed.

## Before recommending it to nontechnical users

1. Validate one clean installation from start to finish on a separate device:
   signing, first game download, update, login, restart, input and recovery.
2. For the IPA route, validate External JIT and memory capacity with the actual
   signing tier. Free signing drops increased-memory and extended-address-space
   entitlements in the current packaging workflow; compilation is not proof
   that the full client will fit.
3. Validate login in the distributable build. `tools/package_ipa.sh` excludes
   roots exported from macOS (`TOLKARA_SYSTEM_ROOTS=NO`), unlike the personal build
   tested here. Provide a redistributable trust-store solution if needed; never
   disable TLS validation or bundle private signing/enrolment material.
4. Confirm cold startup using mobile data, with no nearby Mac or Wi-Fi. Current
   documentation records a failure and an unvalidated recovery sequence.
5. Publish only our app/runtime and original assets, retaining MIT/third-party
   notices and the independent-project attribution. Never include game files,
   account data, pairing records, personal identifiers, captures or certificates
   exported from macOS. Users obtain authorized game content themselves.

## Suggested Reddit rollout

Start with a small tester beta: a short demonstration video and one link to the
fork's README with tested devices, exact prerequisites and a reproducible guide.
Use the verified Xcode path first. Once the IPA/JIT path is validated, a GitHub
Release plus a SideStore/AltStore Classic source can provide launcher updates
and reduce manual file handling. Keep the installation guide to that single
validated route, with troubleshooting separately linked.

Describe it as a community experiment until another person can complete the
clean-device flow. Do not advertise one-tap installation, PAL availability,
cellular-only startup, or account safety on the strength of a local build or
simulator test. Updating Wolkara through a source and updating WoW from its CDN
are two different operations.
