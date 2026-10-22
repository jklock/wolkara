# WolkaraForever — user-facing changelog

Everything below is something a person using the app sees, touches, or experiences.
It covers this fork's own history — from the first commit made here
(`2026-10-01`) to `1.0.0` — so it does not repeat Tolkara's engine work except
where that work changed what the app does for the user.

The engine underneath is [Tolkara](https://github.com/tolkara/tolkara); this
repository is the WoW-facing layer on top of it.

---

## 1.0.0 — 2026-10-22

### The home page

- **One screen for the game.** WolkaraForever opens on a single themed home page
  instead of a menu tree: the mark and the state at the top, Play, then four
  section boxes — **GAME EDITION**, **ADD-ON MANAGER**, **VOICE & INPUT MANAGER**,
  **PERFORMANCE & UI MANAGER** — in a fixed, documented order.
- **The client is ours to prepare.** The edition row offers **Forever · Beta**,
  **Classic Era**, **Classic**, **Retail** and **Retail · Beta**. Region offers
  Europe, Americas, Korea and Taiwan; language offers English and Spanish. These
  choose what gets downloaded and prepared; they never change the game account.
- **One font size, one grey.** Every row, heading, state line and detail uses the
  same text size, so a switch is not smaller than the button beside it; hierarchy
  comes from weight and colour. A row that cannot be used is one explicit grey —
  the same grey everywhere, including both switches, which used to dim to a
  different value than the rows around them.
- **States that say what is happening.** `Starting…` while the game is being
  prepared (and every row that would change something is grey), **Running** once
  the game's own window is up, `Game closed` when the game has quit, and an
  explicit failure message with what to do next. The state text no longer clips at
  large accessibility sizes.
- **The voice section is Voice & Input Manager**, because it holds the microphone,
  the speech permission and the key/button mapping rows, not voice alone.
- **The page survives.** One check per launch, popups instead of pushing you off
  the page, a palette applied everywhere (gold on dark), and a log that outlives
  the run.

### Installing, updating and starting the game

- **Automatic, verified updates.** WolkaraForever checks for updates, downloads
  with resumable CASC staging, verifies checksums, and reuses game data that has
  not changed instead of fetching it again. A required update finishes before Play
  becomes available; updates keep your settings and add-ons.
- **Real progress.** A preparation view shows the stage and an elapsed clock that
  keeps counting while a debugger is paused.
- **Repair instead of despair.** **Verify and repair game files** revalidates the
  local client when something is damaged, including truncated CASC index
  generations, and never writes a generation the client did not author.
- **Play is honest.** One guest per process, so Play cannot silently do nothing:
  after a session the page says `Game closed` and offers **Close WolkaraForever**,
  because the only way to play again is a fresh launch. Starting twice, or
  installing over a live game, is refused rather than done.
- **Three execution modes, chosen in the app** — Developer service, Local signing,
  or External JIT — with the same chooser and the same words, changeable later
  from the settings menu.

### Add-ons

- **Add-on Manager.** **Installed** lists what is on this device with search and
  refresh; select one to **Disable**, **Restore**, **Pin this version**,
  **Unpin updates** or **Remove managed package**. WolkaraForever keeps a manifest
  of what it installed and removes only what it created — your own folders are
  left alone. The **plus** button imports a single archive from Files, and
  **Open Add-on Directory** opens the folder itself.
- **Browse CurseForge, like the site.** The browse page lists real projects with
  artwork, name and current file, total downloads, popularity rank, last update
  date, category, game version and author. **Sort** offers Featured, Popularity,
  Last Updated, Name, Author, Total Downloads and Release Date, and tapping the
  field in use reverses its order. **Filters** narrows to one game version or
  category, and can be cleared. **Columns** chooses which of the six fields are
  shown and remembers that choice; it never hides the name. The count above the
  list follows both filters and sorting.
- **Downloads that do not lose files.** Imported archives are checked against the
  size they declare about themselves; failures that used to leave half an add-on
  behind now leave nothing behind.
- **Download Mac-Ever** in one tap.

### Forever UI: your interface, kept safe

- **Backup WoW UI Configuration** writes a verified ZIP of `WTF` and `Interface`
  into `WTF/Backups` and names it.
- **Reset to Default Graphical Settings** asks first, backs up first, and removes
  *only* graphics and display settings from `Config.wtf`. Accounts, locale, audio,
  input, gamepad configuration, bindings, SavedVariables and unknown lines are
  kept byte for byte.
- **Restore WoW UI Configuration** opens Files at your backups; a snapshot of the
  current state is taken first, so a restore can itself be undone and older
  backups are kept.
- **Gamepad UI** (a switch) writes `SET GamePadEnable` for Forever's next start.
- **Performance Overlay** (a switch) shows frame rate, frame time, thermal state,
  battery, memory and Low Power Mode in the game; it is off by default, applies
  immediately and can be moved. The in-game controller settings carry the same
  switch.
- **Open Settings Folder** opens the Forever `WTF` folder.

### Touch controls and the on-screen toolbar

- **A toolbar at the top centre** over the game: cursor, keyboard, gamepad,
  settings and **Leave game**.
- **Touch trackpad** with two-finger scrolling, three-finger middle click, hold and
  slide for drag.
- **On-screen gamepad** with ring controls around both sticks, an editor for the
  layout, size and opacity settings, an alignment grid, optional haptics, and a
  layout that persists.
- **A keyboard that exists.** When iPadOS hides the software keyboard — it reports
  an empty keyboard frame on this device, which used to leave the login screen
  impossible to type into — the controls supply their own keys: qwerty, a numbers
  and symbols page, shift, backspace, space, return, `@` and `.`, plus a key that
  hands the keyboard back to iPadOS for dictation's microphone. What you type goes
  into the field the game has focused.
- **A draft that replaces the field.** The editor is a real, visible draft;
  **Replace** replaces the focused game field and an empty draft clears it, so
  nothing is sent while you are still composing.
- **Keys you have taken stay yours.** A key mapped for voice is not forwarded to
  the game, where that is possible at all.

### Controllers

- **Any button, on any controller.** Physical pads work, including their extra
  buttons; the app reports what a pad has and what it does, and warns about the one
  chord to avoid.
- **Share works** — measured at every layer it could reach — by using the
  screenshot the system takes from it: tap to start dictation, tap again to stop,
  and the words are typed into the game.

### Voice and dictation

- **Voice & Input Manager** holds **Use a button to talk**, **Map a button**
  (keyboard or controller), **Clear**, **Hold to talk** or **Press to start and
  stop**, **Send it straight away**, **Add a space after the text**, **Words to
  expect**, and **Keep the game from seeing it** for a mapped key.
- **Test Voice** checks a mapping before you open the game, and says whether voice
  is off, waiting for the button, listening, or finalising.
- **Permissions (Microphone, Speech)** takes you straight to this app's page in
  iPad Settings.
- **Dictation types into the game's own text input**, not into a draft, so the
  transcript lands in the focused field; Return is only sent when you asked for
  auto-submit. The microphone is asked for at launch, released when you leave the
  game or the app, and recorded in the log rather than silently held.
- **Fixed by measurement, not guesswork:** the capture format, the capture mode
  for a nearby voice, the audio-session owner, and the digital-silence
  investigation that ended with a working microphone.

### Quitting, returning and closing

- **Leave game** (the house on the toolbar) exists for screens with no quit of
  their own — the login screen is one — and never half-asks the client to quit.
- **A closing page** with the mark and a five-second countdown, telling you to open
  WolkaraForever again; it now also has a **Close WolkaraForever** button, because
  a page that only leaves by itself leaves you with nothing to press if it does
  not.
- **Quit from the game's own menu** and WolkaraForever returns to the home page
  saying `Game closed`, with the close action available.
- **The game keeps running when you switch apps**, as a Mac app would, instead of
  being suspended and killed for memory.

### Diagnostics, trust and the small print

- **Settings menu**: Manage add-ons, Verify and repair game files, Diagnostics and
  logs, and About and open-source licences.
- **The app tests itself on the device** — Forever UI, CurseForge, add-on archives,
  the recovery path — and reports what each check measured.
- **The licences the app is obliged to ship** are composed into About and reported
  in its own log; upstream's notices were previously shipped under this project's
  name.
- **Privacy kept in place.** The CurseForge key lives only in this device's
  Keychain; pairing material, credentials and device identifiers stay out of the
  repository, and validation records name the iPad's model and OS, never its
  identifier.

### Appearance and documentation

- **A new app icon**: a gilded T in a ringed night landscape, redrawn at every size
  and appearance.
- **An illustrated user guide** with screenshots of the home page, add-on manager,
  voice configuration, test voice and settings.
- **Guides for every audience**: from-zero setup, build and run, device workflow,
  maintaining the layer, and the architecture of what runs where.

### iPhone

- **iPhone support**, tested on iPhone 16 Pro and later, with the keyboard and touch
  trackpad working there.

---

## Notes on scope

- The original game executable is never modified: it is imported as hash-verified
  data and never patched or re-signed.
- Nothing here automates the game. Input routing, dictation and the on-screen
  controls are WolkaraForever's own code being tested and used, not a bot playing
  the game.
- Three execution modes exist because the user chooses one: Developer service
  prepares memory and detaches before any game code runs; External JIT asks a
  sideloading tool to prepare memory and refuses guest entry while a debugger is
  attached; Local signing signs only a page container derived locally from the
  game's final code pages, with the user's own identity.
