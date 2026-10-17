#!/usr/bin/env bash
#
# Pilot the app on the device without breaking it.
#
# Why this exists: stopping the app at the wrong moment, killing a live session,
# or installing while the game or its updater is mid-write, is what corrupted the
# client's store twice. Every step here therefore looks at the device first and
# refuses when the answer is "not now", rather than assuming. Refusing is the
# feature.
#
#   wolkara/tools/pilot.sh state             what the device is doing right now
#   wolkara/tools/pilot.sh stop [--force]    stop it, asking first and waiting
#   wolkara/tools/pilot.sh install [--force] stop, then build and install
#   wolkara/tools/pilot.sh launch            the launcher, so its own checks run
#   wolkara/tools/pilot.sh game              straight into the game, no checks
#   wolkara/tools/pilot.sh wait [--timeout s] block until it is up, or until it fails
#   wolkara/tools/pilot.sh view              screenshot, log, whether it crashed or asserted
#   wolkara/tools/pilot.sh crash             read the newest crash report out loud
#   wolkara/tools/pilot.sh log [lines] [pat] the app's own log, from Documents
#   wolkara/tools/pilot.sh leave [bundle]    put the app in the background for real
#   wolkara/tools/pilot.sh return            bring it back to the front
#   wolkara/tools/pilot.sh cycle             state, install, launch, wait, view
#
# Every command that launches records the newest error file and the newest crash report
# first, so "did it fail?" is answered by comparing, never by a file name written down
# in this script. Either kind of new file is a failure; a growing log is not success.
#
# Both places have to be watched. A crash after the client is up leaves a file in its own
# Errors/ folder, but one before it writes anything - an exception in -viewDidLoad, say -
# aborts the process and touches nothing there. On 2026-10-16 that read as a clean launch
# until the system crash log was read by hand, which is why it is watched here now.
#
set -u

root=$(cd "$(dirname "$0")/../.." && pwd)
[ -f "$root/wolkara/tools/env.sh" ] && . "$root/wolkara/tools/env.sh"
# The device and the bundle id come from the repository root's ignored local.env,
# like every other tool here. Nothing about one particular iPad belongs in a commit.
DEVICE=${DEVICE:-}
BUNDLE=${BUNDLE:-${TOLKARA_BUNDLE_ID:-}}
GAME=${PILOT_GAME:-Documents/World of Warcraft/_classic_beta_}

say()  { printf '  %s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
die()  { printf 'pilot: %s\n' "$*" >&2; exit 2; }
[ -n "$DEVICE" ] || die "Set DEVICE=<iPad UDID> in local.env (see local.env.example)."
[ -n "$BUNDLE" ] || die "Set TOLKARA_BUNDLE_ID in local.env (see local.env.example)."

# Work files, in one directory of this run's own. They used to be fixed names under
# /tmp, which two pilots - or one pilot and a leftover from yesterday - would share:
# the second run would compare against the first run's baseline and call a crash
# "no new crash report". PILOT_SESSION lets a caller keep a session to look at.
SESSION=${PILOT_SESSION:-$(mktemp -d -t pilot)}
STATE=$SESSION/state.txt
BASELINE=$SESSION/baseline.txt
CRASH_BASELINE=$SESSION/crash-baseline.txt
STARTS_BASELINE=$SESSION/starts-baseline.txt
LAUNCH_MODE=$SESSION/mode.txt
GUEST_LOG=$SESSION/guest.log
APP_LOG=$SESSION/app.log
PROCESSES=$SESSION/processes.txt
FILES=$SESSION/files.json
CRASHES=$SESSION/crashes.json
ERRORS=$SESSION/errors
CRASH_DIR=$SESSION/crash
STAGED="Documents/.tolkara-updates"
mkdir -p "$ERRORS" "$CRASH_DIR"
# ---------------------------------------------------------------------------
# What the device is doing. One python helper, because the answers come from
# three different commands and comparing timestamps in shell is how mistakes
# happen.
# ---------------------------------------------------------------------------
refresh_state() {
    # Every one of these can fail, and a failed inspection that reads as "nothing
    # there" is the most dangerous thing this script could do: it would report "the
    # client did not assert" because it could not look. So the exit codes are kept and
    # carried into the state, and everything that concludes anything checks them.
    local processes_ok=1 files_ok=1 crashes_ok=1
    xcrun devicectl device info processes --device "$DEVICE" 2>/dev/null > "$PROCESSES" || processes_ok=0
    # JSON, not the table. The table wraps its columns in the middle of the date and
    # reflows them by terminal width, and a parse that silently finds no error file reads
    # exactly like "the client did not assert" - the one answer that must never be wrong.
    xcrun devicectl device info files --device "$DEVICE" --domain-type appDataContainer \
        --domain-identifier "$BUNDLE" --username mobile \
        --json-output "$FILES" >/dev/null 2>&1 || files_ok=0
    # And the other place a failure shows up. Crash reports are written by the system, not
    # by the app, so they are not in the container above and no amount of looking there
    # will find one.
    xcrun devicectl device info files --device "$DEVICE" --domain-type systemCrashLogs \
        --json-output "$CRASHES" >/dev/null 2>&1 || crashes_ok=0

    rm -f "$GUEST_LOG"
    xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
        --domain-identifier "$BUNDLE" --source "Documents/native-guest.log" \
        --destination "$GUEST_LOG" >/dev/null 2>&1 || true

    python3 - "$SESSION" "$STAGED" "$processes_ok" "$files_ok" "$crashes_ok" <<'PY' > "$STATE"
import datetime, json, pathlib, re, sys

session = sys.argv[1]
staged_prefix = sys.argv[2]
processes_ok, files_ok, crashes_ok = (int(value) for value in sys.argv[3:6])
def in_session(name):
    return str(pathlib.Path(session) / name)
now = datetime.datetime.now(datetime.timezone.utc)

def read(path):
    try:
        return pathlib.Path(path).read_text(errors="replace").splitlines()
    except FileNotFoundError:
        return []

def entries():
    try:
        with open(in_session("files.json")) as handle:
            listed = json.load(handle)
    except (OSError, ValueError):
        return []
    return listed.get("result", {}).get("files", []) or []

def age_of(entry):
    stamp = entry.get("metadata", {}).get("lastModDate")
    if not stamp:
        return None
    try:
        when = datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00"))
    except ValueError:
        return None
    return (now - when).total_seconds()

files = entries()

app = 0
for line in read(in_session("processes.txt")):
    if re.search(r"Tolkara\.app/Tolkara(\s|$)", line):
        app += 1
        break

# An update in progress: files staged for the next launch, written moments ago. This is
# the one state in which stopping the app does real damage.
recent = 0
for entry in files:
    name = entry.get("relativePath") or entry.get("name") or ""
    if not name.startswith(staged_prefix + "/"):
        continue
    age = age_of(entry)
    if age is not None and 0 <= age < 120:
        recent += 1

# The names carry their own date, so the last one sorts last and is the newest.
error_files = sorted(((e.get("relativePath") or ""), age_of(e)) for e in files
                     if re.search(r"_Error_\d+\.txt$", e.get("relativePath") or ""))
newest = error_files[-1][0].rsplit("/", 1)[-1] if error_files else "none"
newest_age = error_files[-1][1] if error_files else None

starts = [l for l in read(in_session("guest.log")) if "startup_return=" in l]
last = starts[-1].split("startup_return=", 1)[-1].strip() if starts else "none"
# A live session: the guest started, nothing has finished it, and its log was written to
# recently. The log outlives app restarts and holds every launch this install has done,
# so an old PASS on its own says nothing about now - without the age it would call every
# visit to the launcher a live game.
log_age = None
for entry in files:
    if (entry.get("relativePath") or "").endswith("native-guest.log"):
        log_age = age_of(entry)
live = 1 if (app and last == "PASS" and log_age is not None and log_age < 3600) else 0

# The system crash log. `.cpu_resource` reports are periodic microstackshots, not
# failures, and the dash in `Tolkara-<date>` is what keeps them out of this count.
crashes = []
try:
    with open(in_session("crashes.json")) as handle:
        logged = json.load(handle)
except (OSError, ValueError):
    logged = {}
for entry in logged.get("result", {}).get("files", []) or []:
    name = (entry.get("relativePath") or entry.get("name") or "").rsplit("/", 1)[-1]
    if not name.endswith(".ips") or not re.match(r"Tolkara-\d", name):
        continue
    crashes.append((name, age_of(entry)))
crashes.sort(key=lambda item: (item[1] if item[1] is not None else 1e18))
newest_crash = crashes[0][0] if crashes else "none"
newest_crash_age = crashes[0][1] if crashes else None

print("app_running=%d" % app)
# One flag for the whole inspection. Without it, a device that could not be looked at
# and a device with nothing wrong would produce the same output, and only one of those
# is safe to act on.
print("inspection_ok=%d" % (1 if (processes_ok and files_ok and crashes_ok) else 0))
print("update_writing=%d" % recent)
print("newest_error=%s" % newest)
print("newest_error_age=%s" % ("none" if newest_age is None else int(newest_age)))
print("error_count=%d" % len(error_files))
print("guest_start=%s" % last)
print("guest_starts=%d" % len(starts))
print("guest_log_age=%s" % ("none" if log_age is None else int(log_age)))
print("session_live=%d" % live)
print("crash_newest=%s" % newest_crash)
print("crash_newest_age=%s" % ("none" if newest_crash_age is None else int(newest_crash_age)))
print("crash_count=%d" % len(crashes))
pathlib.Path(in_session("newest-error")).write_text(newest)
pathlib.Path(in_session("newest-crash")).write_text(newest_crash)
PY

    # Then fetch the one file that matters. `copy from` handed a directory copies nothing
    # at all - which reads exactly like "the client did not assert", the answer that must
    # never be wrong. It also wants the destination to be the file, not the folder.
    rm -rf "$ERRORS" && mkdir -p "$ERRORS"
    newest=$(cat "$SESSION/newest-error" 2>/dev/null || echo none)
    if [ "$newest" != "none" ]; then
        xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
            --domain-identifier "$BUNDLE" --source "$GAME/Errors/$newest" \
            --destination "$ERRORS/$newest" >/dev/null 2>&1 || true
    fi
}

state_value() { sed -n "s/^$1=//p" "$STATE"; }

verdict() {
    refresh_state
    if [ "$(state_value inspection_ok)" != "1" ]; then
        say "THE DEVICE COULD NOT BE INSPECTED. Nothing below can be trusted:" >&2
        say "  processes=$([ -s "$PROCESSES" ] && echo listed || echo failed) files=$([ -s "$FILES" ] && echo listed || echo failed) crash logs=$([ -s "$CRASHES" ] && echo listed || echo failed)" >&2
        say "  (unlock the iPad and check the cable, then try again)" >&2
    fi
    local over=""
    [ "$(state_value session_live)" = "1" ] && over="   <-- a game session is live"
    say "app running:    $(state_value app_running)$over"
    say "update writing: $(state_value update_writing) file(s) in the last 2 minutes"
    say "guest log says: $(state_value guest_start)"
    say "error files:    $(state_value error_count), newest $(state_value newest_error)"
    say "crash reports:  $(state_value crash_count), newest $(state_value crash_newest), $(state_value crash_newest_age)s ago"
}

app_pid() {
    xcrun devicectl device info processes --device "$DEVICE" 2>/dev/null \
        | grep -E "Tolkara\.app/Tolkara([[:space:]]|$)" | grep -v "\.appex" \
        | awk 'NR==1 {print $1}'
}

# The client is the only thing here that writes to its own store, and it does so
# while a session or an update is running. Both must be over before its files are
# replaced.
require_safe_to_install() {
    local force=${1:-}
    [ "$force" = "--force" ] && return 0
    refresh_state
    # Fail closed. A device that cannot be inspected might be mid-update, and the whole
    # point of this guard is that guessing wrong there damages the client's store.
    if [ "$(state_value inspection_ok)" != "1" ]; then
        die "the device could not be inspected, so whether it is safe to install is unknown.
       Unlock the iPad and check the cable, or override with --force if you are certain."
    fi
    if [ "$(state_value update_writing)" != "0" ]; then
        die "an update is writing right now - leave the app alone and try again when it stops.
       (Only override if you are certain: --force)"
    fi
}

cmd_state() {
    # The work files are per-run, so say where this run's are. Nothing else points at them.
    say "session:        $SESSION"
    verdict
}

# ---------------------------------------------------------------------------
# Stopping. Ask first, wait for the answer, and never send a signal the client
# cannot act on unless the user asks for it in so many words.
# ---------------------------------------------------------------------------
stop_app() {
    local force=${1:-}
    local pid; pid=$(app_pid)
    if [ -z "$pid" ]; then
        say "not running"
        return 0
    fi
    say "asking pid $pid to stop (SIGTERM, so the client can close its stores)"
    xcrun devicectl device process signal --device "$DEVICE" --pid "$pid" --signal SIGTERM >/dev/null 2>&1 || true
    local waited=0
    while [ -n "$(app_pid)" ] && [ "$waited" -lt 20 ]; do
        sleep 2
        waited=$((waited + 2))
    done
    if [ -z "$(app_pid)" ]; then
        say "gone after ${waited}s"
        return 0
    fi
    if [ "$force" != "--force" ]; then
        die "it is still running after 20s. It is not stopped and nothing was installed.
       A session can take a while to close its files; wait a moment and try again.
       Killing it mid-write is what damaged the client's store before, so this
       script will not do that unless you say so: --force"
    fi
    say "still running, and --force was given: killing it (this is the risky one)"
    xcrun devicectl device process signal --device "$DEVICE" --pid "$pid" --signal SIGKILL >/dev/null 2>&1 || true
    waited=0
    while [ -n "$(app_pid)" ] && [ "$waited" -lt 20 ]; do
        sleep 2
        waited=$((waited + 2))
    done
    [ -z "$(app_pid)" ] || die "it would not stop even with SIGKILL; nothing was installed"
    say "gone"
}

cmd_stop() {
    local force=${1:-}
    if [ "$force" = "--dry-run" ]; then
        refresh_state
        local pid; pid=$(app_pid)
        if [ -z "$pid" ]; then
            say "dry run: not running, nothing to stop"
        else
            say "dry run: would ask pid $pid to stop, and would not force it"
        fi
        [ "$(state_value update_writing)" = "0" ] || say "dry run: but an update is writing"
        return 0
    fi
    require_safe_to_install "$force"
    stop_app "$force"
}

# ---------------------------------------------------------------------------
# Installing and launching
# ---------------------------------------------------------------------------
cmd_install() {
    local force=${1:-}
    step "state before touching anything"; verdict
    step "stopping"
    require_safe_to_install "$force"
    stop_app "$force"
    step "building and installing"
    # No --replace-running: this script has already stopped what was running, so
    # anything running now started in between and must not be killed for us.
    "$root/wolkara/tools/install.sh" || die "install failed"
    # install.sh ends by enrolling, and enrolling starts the app so that it can do the
    # protected import - so the moment it returns, something is running again. Left
    # alone that is the app the user ends up watching, and 'launch' refuses because
    # something is already up, which is why 'cycle' could not reach its own launch on
    # 2026-10-16. Stopped here, gracefully and with the same force setting, so that the
    # launch that follows is an ordinary one from a clean slate.
    step "stopping what the install left running"
    stop_app "$force"
}

record_baseline() {
    printf '%s\n' "$(state_value newest_error)" > "$BASELINE"
    printf '%s\n' "$(state_value crash_newest)" > "$CRASH_BASELINE"
    printf '%s\n' "$(state_value guest_starts)" > "$STARTS_BASELINE"
}

cmd_launch() {
    local game=${1:-}
    # Never --terminate-existing: that is how a live session is killed from under
    # the user. If something is running, that is the user's business.
    if [ -n "$(app_pid)" ]; then
        die "the app is already running (pid $(app_pid)). Not launching, and not stopping it.
       Use 'pilot.sh stop' first if it is yours to stop, or just use the iPad."
    fi
    refresh_state
    if [ "$(state_value inspection_ok)" != "1" ]; then
        die "the device could not be inspected, so whether anything is running is unknown.
       Not launching on a guess. Unlock the iPad and check the cable."
    fi
    # Before the launch, so that afterwards we can tell a log written by this build from
    # one left behind by the last one.
    log_launch_count > "$SESSION/log-launches-before"
    record_baseline
    say "starting from error baseline $(cat "$BASELINE") and crash baseline $(cat "$CRASH_BASELINE")"
    if [ "$game" = "--game" ]; then
        printf 'game\n' > "$LAUNCH_MODE"
        say "straight into the game: the launcher's own checks and repair are skipped"
        xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE" \
            --local-game-startup >/dev/null 2>&1 || die "launch failed"
    else
        printf 'launcher\n' > "$LAUNCH_MODE"
        xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE" \
            >/dev/null 2>&1 || die "launch failed"
    fi
    say "launched"
}

# Block until the answer is known, rather than guessing at a fixed wait. What counts as
# an answer depends on what was launched, and the guest log's own last line cannot be it:
# it outlives app restarts, so yesterday's PASS reads as today's success. A guest start is
# therefore only counted when the log has gained one since the baseline, and a launcher is
# only believed once it has stayed up through the first few seconds - which is where a
# crash at launch lands, as measured on 2026-10-16.
cmd_wait() {
    local timeout=180
    [ "${1:-}" = "--timeout" ] && timeout=${2:-180}
    local settle=12
    [ "$timeout" -lt "$settle" ] && settle=$timeout
    local baseline; baseline=$(cat "$BASELINE" 2>/dev/null || echo none)
    local crash_baseline; crash_baseline=$(cat "$CRASH_BASELINE" 2>/dev/null || echo none)
    local starts_baseline; starts_baseline=$(cat "$STARTS_BASELINE" 2>/dev/null || echo 0)
    local mode; mode=$(cat "$LAUNCH_MODE" 2>/dev/null || echo launcher)
    if [ "$mode" = "game" ]; then
        say "waiting up to ${timeout}s for the guest to start, or for the client to fail"
    else
        say "waiting up to ${timeout}s for the launcher to stay up, or for the client to fail"
    fi
    local waited=0
    local blind=0
    while [ "$waited" -lt "$timeout" ]; do
        sleep 2
        waited=$((waited + 2))
        refresh_state
        # Nothing may be concluded from an inspection that did not happen. This keeps
        # waiting rather than calling a device it cannot see "fine".
        if [ "$(state_value inspection_ok)" != "1" ]; then
            blind=$((blind + 1))
            printf '!'
            continue
        fi
        # A crash is the faster and more final answer, so it is asked for first: the
        # process is already gone by the time one appears.
        local crash; crash=$(state_value crash_newest)
        if [ "$crash" != "$crash_baseline" ]; then
            printf '\n'
            say "CRASHED after ${waited}s: $crash"
            say "the app died before writing anything of its own - run: pilot.sh crash"
            return 1
        fi
        local newest; newest=$(state_value newest_error)
        if [ "$newest" != "$baseline" ]; then
            printf '\n'
            say "ASSERTED after ${waited}s: $newest"
            return 1
        fi
        if [ "$(state_value guest_starts)" -gt "$starts_baseline" ] 2>/dev/null; then
            printf '\n'
            say "the guest started after ${waited}s (no new error file, no new crash report)"
            return 0
        fi
        if [ "$mode" = "launcher" ] && [ "$(state_value app_running)" = "1" ] && [ "$waited" -ge "$settle" ]; then
            printf '\n'
            say "the launcher is up after ${waited}s (no new error file, no new crash report)"
            return 0
        fi
        if [ "$(state_value app_running)" = "0" ] && [ "$mode" = "launcher" ]; then
            printf '\n'
            say "the app is gone after ${waited}s, and wrote nothing to say why"
            say "check it by hand: pilot.sh state, and the iPad's own console"
            return 1
        fi
        printf '.'
    done
    printf '\n'
    if [ "$blind" -gt 0 ]; then
        say "nothing conclusive in ${timeout}s, and $blind of those looks could not see the device"
        say "so 'no new error file' would be a guess, not an answer"
        return 1
    fi
    say "nothing conclusive in ${timeout}s: no new error file, no new crash report"
    return 1
}

cmd_view() {
    step "screen"
    if xcrun devicectl device capture screenshot --device "$DEVICE" --destination "$SESSION/screen.png" >/dev/null 2>&1; then
        sips -Z 1100 "$SESSION/screen.png" --out "$SESSION/screen-small.png" >/dev/null 2>&1 && say "look at $SESSION/screen-small.png"
    else
        say "no screenshot (the device may be locked)"
    fi
    step "did the client assert?"
    refresh_state
    if [ "$(state_value inspection_ok)" != "1" ]; then
        say "THE DEVICE COULD NOT BE INSPECTED, so 'no new error file' would be a guess:"
        say "  processes=$([ -s "$PROCESSES" ] && echo listed || echo failed) files=$([ -s "$FILES" ] && echo listed || echo failed) crash logs=$([ -s "$CRASHES" ] && echo listed || echo failed)"
        step "state"
        return 0
    fi
    local baseline; baseline=$(cat "$BASELINE" 2>/dev/null || echo none)
    local newest; newest=$(state_value newest_error)
    say "baseline: $baseline"
    say "newest:   $newest"
    if [ "$baseline" = "none" ]; then
        # Nothing was launched by this script, so "new" cannot be judged. Saying otherwise
        # would turn an old assert into a fresh alarm every time.
        say "no baseline: this script has not launched anything, so 'new' cannot be judged"
        say "the newest error file was written $(state_value newest_error_age)s ago"
    elif [ "$newest" = "$baseline" ]; then
        say "no new error file: the client did not assert"
    elif [ -f "$ERRORS/$newest" ]; then
        say "A NEW ERROR FILE. Read it before going any further:"
        grep -m3 -E "Error:|Exception:" "$ERRORS/$newest" 2>/dev/null | sed 's/^/    /'
    else
        say "A NEW ERROR FILE: $newest"
        say "it could not be fetched - read it on the device before going any further"
    fi
    step "did it crash?"
    local crash_baseline; crash_baseline=$(cat "$CRASH_BASELINE" 2>/dev/null || echo none)
    local crash; crash=$(state_value crash_newest)
    say "baseline: $crash_baseline"
    say "newest:   $crash ($(state_value crash_newest_age)s ago)"
    if [ "$crash_baseline" = "none" ]; then
        say "no baseline: this script has not launched anything, so 'new' cannot be judged"
    elif [ "$crash" = "$crash_baseline" ]; then
        say "no new crash report"
    else
        say "A NEW CRASH REPORT. Read it: pilot.sh crash"
    fi
    step "what the app last said"
    tail -8 "$GUEST_LOG" 2>/dev/null | cut -c1-150 | sed 's/^/  /'
    step "the app's own log"
    rm -f "$APP_LOG"
    xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
        --domain-identifier "$BUNDLE" --source "Documents/wolkara.log" \
        --destination "$APP_LOG" >/dev/null 2>&1 || true
    if [ -s "$APP_LOG" ]; then
        tail -12 "$APP_LOG" | cut -c1-170 | sed 's/^/  /'
        grep -q "\[fatal\]" "$APP_LOG" && say "IT SAYS SOMETHING FATAL: pilot.sh log"
    else
        say "no Documents/wolkara.log yet"
    fi
    step "state"
    say "app running:    $(state_value app_running)"
    say "guest log says: $(state_value guest_start) (written $(state_value guest_log_age)s ago)"
}

# The app's own log. It exists because stderr does not survive: the host's lines
# only reached a console that is not attached, and the platform only redirects them
# into native-guest.log once a guest starts. Anything the launcher says while it is
# opening, and anything it says while it is dying, is in this file.
# How many times the app says it has been launched. Read before a launch and again after
# it, so "is this log from the run I just did?" is answered by the file itself rather than
# by a timestamp or by whatever happens to be sitting in the container. The first version
# of the validation record read a log written by an earlier build and marked it PASS.
log_launch_count() {
    local destination=$SESSION/app-count.log
    rm -f "$destination"
    xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
        --domain-identifier "$BUNDLE" --source "Documents/wolkara.log" \
        --destination "$destination" >/dev/null 2>&1 || true
    if [ -s "$destination" ]; then
        grep -c ' launched ---$' "$destination" 2>/dev/null || echo 0
    else
        echo 0
    fi
}

cmd_log() {
    local lines=${1:-60}
    local pattern=${2:-.}
    rm -f "$APP_LOG"
    xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
        --domain-identifier "$BUNDLE" --source "Documents/wolkara.log" \
        --destination "$APP_LOG" >/dev/null 2>&1 || true
    [ -s "$APP_LOG" ] || die "no log on the device yet: $BUNDLE has not written Documents/wolkara.log"
    local total; total=$(wc -l < "$APP_LOG" | tr -d ' ')
    say "Documents/wolkara.log, $total lines; the last $lines matching /$pattern/"
    grep -E "$pattern" "$APP_LOG" | tail -"$lines" | cut -c1-200 | sed 's/^/  /'
    # Whether this log is from the run that is being judged. A container holds one log
    # across launches, so "the app logged something" is not evidence about this launch.
    local before; before=$(cat "$SESSION/log-launches-before" 2>/dev/null || echo none)
    if [ "$before" != none ]; then
        local now; now=$(grep -c ' launched ---$' "$APP_LOG" 2>/dev/null || echo 0)
        if [ "$now" -gt "$before" ]; then
            say "this log holds the launch from this run ($before before it, $now now)"
        else
            say "NO LAUNCH FROM THIS RUN IS IN THIS LOG ($before before it, $now now)"
            say "so what is above was written by an earlier build, whatever it says"
        fi
    fi
    if grep -q "\[fatal\]" "$APP_LOG"; then
        step "it says something fatal"
        grep -n "\[fatal\]" "$APP_LOG" | tail -4 | cut -c1-200 | sed 's/^/  /'
        say "the full report, with the stack, is in the same file"
    fi
}

# A crash before the app writes its own Errors/ file leaves the system report as the
# only evidence, and the exception is in there with the frames that raised it. This
# turns that into something readable without a trip through Xcode.
cmd_crash() {
    refresh_state
    local name; name=$(cat "$SESSION/newest-crash" 2>/dev/null || echo none)
    [ "$name" = "none" ] && die "no crash reports on the device"
    rm -rf "$CRASH_DIR" && mkdir -p "$CRASH_DIR"
    xcrun devicectl device copy from --device "$DEVICE" --domain-type systemCrashLogs \
        --source "$name" --destination "$CRASH_DIR/$name" >/dev/null 2>&1 \
        || die "could not fetch $name from the device"
    say "$name, written $(state_value crash_newest_age)s ago"
    python3 - "$CRASH_DIR/$name" <<'PY'
import json, sys

raw = open(sys.argv[1], errors="replace").read().split("\n", 1)
try:
    body = json.loads(raw[1])
except (IndexError, ValueError):
    print("     this report is not the JSON form; read it by hand")
    raise SystemExit(0)

print("     exception:   %s" % json.dumps(body.get("exception", {})))
print("     termination: %s" % json.dumps(body.get("termination", {}))[:220])
asi = body.get("asi")
if asi:
    print("     as reported: %s" % json.dumps(asi)[:220])
images = body.get("usedImages", [])
for thread in body.get("threads", []):
    if not thread.get("triggered"):
        continue
    print("     faulting thread:")
    for frame in thread.get("frames", [])[:20]:
        index = frame.get("imageIndex", 0)
        image = images[index].get("name") if index < len(images) else "?"
        print("       %s %s" % (image, frame.get("symbol") or hex(frame.get("imageOffset", 0))))
PY
}

# Putting the app away and bringing it back, which is a real thing to test and used to be
# something only a person could do by tapping Home. Launching another app is enough: iPadOS
# backgrounds ours. What is being checked afterwards is the app's own log, because nothing on
# this Mac can see which app is in front.
cmd_leave() {
    local other=${1:-com.apple.Preferences}
    local pid; pid=$(app_pid)
    [ -n "$pid" ] || die "the app is not running, so there is nothing to put away.
       Launch it first (pilot.sh launch), then leave."
    say "opening $other, which puts the app in the background"
    xcrun devicectl device process launch --device "$DEVICE" "$other" >/dev/null 2>&1 \
        || die "could not open $other; is the iPad unlocked?"
    sleep 2
    # Still running, and that is the point: this is backgrounding, not a stop.
    say "the app is now $( [ -n "$(app_pid)" ] && echo 'in the background (still running)' || echo 'GONE, which is not what this does' )"
}

cmd_return() {
    say "bringing the app back to the front"
    xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE" >/dev/null 2>&1 \
        || die "could not bring $BUNDLE back; is the iPad unlocked?"
    sleep 2
}

case "${1:-state}" in
    state)   cmd_state ;;
    stop)    cmd_stop "${2:-}" ;;
    install) cmd_install "${2:-}" ;;
    launch)  cmd_launch ;;
    game)    cmd_launch --game ;;
    wait)    cmd_wait "${2:-}" "${3:-}" ;;
    view)    cmd_view ;;
    crash)   cmd_crash ;;
    log)     cmd_log "${2:-}" "${3:-}" ;;
    leave)   cmd_leave "${2:-}" ;;
    return)  cmd_return ;;  # `return` is a shell keyword; the case label is a plain word here
    cycle)
        cmd_install "${2:-}"
        cmd_launch
        cmd_wait --timeout "${3:-240}"
        cmd_view
        ;;
    *) die "unknown command: $1" ;;
esac
