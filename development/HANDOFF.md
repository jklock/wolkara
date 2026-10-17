# Handoff status: 2026-10-17

The user approved the corrected-logo app icon, Hold/Toggle as the supported voice
modes, and the visible controller-button collision warning. Root `logo.png` is retained.

## Implemented and focused-tested

- Corrected-logo W medallion icon in default, dark and tinted appearances;
  reproducible layer-aware renderer and visual size review (`ICON.md`).
- Real ZIPFoundation/Swift extraction and Objective-C store import lifecycle tests;
  CRC validation, preservation of existing destinations and cleanup on early failure.
- CurseForge response/request tests and malformed JSON/file-entry crash fixes.
- Removed unsupported trigger execution; safe rejection of retired mappings, repeat
  suppression, and mode precedence over imported patterns. Voice: 244 checks.
- Updated runnable docs and authoritative audit dispositions.
- Platform suite continues after the known signer failure; the validator requires
  completion evidence, records commands and redacts configured signing/device values.

## Candidate validation

Run `wolkara/tools/validate.sh --full --device` from a clean candidate. Its generated
`development/validation/<sha>.md` is authoritative; a failing run stays in the record.
An evidence-only follow-up commit does not change the executable tree that was tested.
Do not edit generated records or imply that the known upstream signing comparison passed.

## Remaining physical observations

On the final installed candidate, record real speech/final transcript and audio before
and after dictation (speaker, headphones, Bluetooth), a real controller mapping and system
gesture restoration, and live-game chat/repair behavior. The scripted matrix and synthetic
fixtures cannot supply physical input. Live CurseForge protected downloads additionally
need an approved Core API key. Do not call these verified from simulator results.

The archive extraction/import path is now exercised with real ZIPs locally; a Files-picker
import on iPad remains useful end-to-end platform confirmation, not a substitute for that
coverage. Never force past the pilot's running-client/update guard or alter a live client's
store to manufacture a passing result.
