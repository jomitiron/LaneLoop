# Platform helpers for the loop scripts: sourced, never run. The kit was first written for Windows with Git Bash; on
# macOS (and Linux) the same calls go to the native tools. Every Windows branch is the code the scripts had before.
#   source "$HERE/platform.sh"          (after loop.conf, so the run's PYTHON wins)
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) PLATFORM=windows ;;
    Darwin) PLATFORM=mac ;;
    *) PLATFORM=linux ;;
esac
PLATFORM_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The run's Python is loop.conf PYTHON. A run folder made before that key existed: python on Windows, python3 elsewhere
# (macOS has no `python`).
if [ -z "${PYTHON:-}" ]; then
    if [ "$PLATFORM" = windows ] || ! command -v python3 >/dev/null 2>&1; then PYTHON=python; else PYTHON=python3; fi
fi

# Git Bash's cygpath turns /c/... paths into Windows ones for Windows tools. A POSIX path needs no conversion.
if ! command -v cygpath >/dev/null 2>&1; then
    cygpath() { printf '%s\n' "${@: -1}"; }
fi

sha1() { if command -v sha1sum >/dev/null 2>&1; then sha1sum; else shasum -a 1; fi; }

# A toast on Windows, a notification on macOS, notify-send on Linux when it's there. Never fails, never waits.
platform_notify() {
    case "$PLATFORM" in
        windows) powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$PLATFORM_HERE/notify.ps1")" "$1" "$2" >/dev/null 2>&1 & ;;
        mac) osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' -e 'end run' \
                 "$1" "${2:- }" >/dev/null 2>&1 & ;;
        *) if command -v notify-send >/dev/null 2>&1; then notify-send "$1" "$2" >/dev/null 2>&1 & fi ;;
    esac
}

# Keep the computer from sleeping for as long as process <pid> runs; the hold ends with it. macOS: caffeinate (idle
# sleep always, system sleep too on mains power). Linux: systemd-inhibit, where systemd has it. Windows: keep_awake.ps1
# (SetThreadExecutionState), waiting on the process's Windows pid; with none readable it holds nothing and says so, on
# stderr and in a toast (waiting on Git Bash's own pid would let go at once). A closed laptop lid still sleeps the
# computer. Never fails, never waits.
keep_awake() {  # <pid> [why]
    local pid="$1" why="${2:-a LaneLoop run is working}" wpid
    [ "${LANELOOP_KEEP_AWAKE:-${METALOOP_KEEP_AWAKE:-1}}" = 0 ] && return 0
    case "$PLATFORM" in
        mac) caffeinate -is -w "$pid" >/dev/null 2>&1 & ;;
        windows) wpid=$(cat "/proc/$pid/winpid" 2>/dev/null)
                 if [ -z "$wpid" ]; then
                     echo "keep_awake: no Windows pid for process $pid (/proc/$pid/winpid): this PC is NOT kept awake" >&2
                     platform_notify "PC not kept awake" "No Windows pid for process $pid: set Sleep to Never for this run"
                 else
                     powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass \
                         -File "$(cygpath -w "$PLATFORM_HERE/keep_awake.ps1")" "$wpid" >/dev/null 2>&1 &
                 fi ;;
        *) if can_inhibit; then
               systemd-inhibit --what=idle:sleep --who=LaneLoop --why="$why" --mode=block \
                   sh -c 'while kill -0 "$1" 2>/dev/null; do sleep 20; done' sh "$pid" >/dev/null 2>&1 &
           fi ;;
    esac
    return 0
}

# Linux: whether systemd-inhibit is here and may take a sleep hold (a container, an SSH login or a CI runner may have
# the command and be refused the hold). A loop is never wrapped in a hold that would stop it from starting.
can_inhibit() {
    command -v systemd-inhibit >/dev/null 2>&1 &&
        systemd-inhibit --what=idle:sleep --who=LaneLoop --why="checking" --mode=block true >/dev/null 2>&1
}

# Sleep <secs>, then set SLEPT to how long the computer was asleep (or suspended) on top of that: 0 below
# SLEEP_GAP_SECS (120), which is scheduling noise. A watcher reports a sleep, so whoever it wakes re-checks everything.
nap() {  # <secs>
    local t0; t0=$(date +%s)
    sleep "$1"
    SLEPT=$(( $(date +%s) - t0 - $1 ))
    [ "$SLEPT" -ge "${SLEEP_GAP_SECS:-120}" ] || SLEPT=0
}

# Seconds the computer has been awake, from an arbitrary start: Python's monotonic clock, which stops while macOS or
# Linux sleeps. Wall-clock time minus this across a stretch is how long the computer slept in it.
awake_secs() { "$PYTHON" -c 'import time; print(int(time.monotonic()))' 2>/dev/null || date +%s; }

# awake_mark starts a stretch; slept_since prints how long the computer slept during it (0 under SLEEP_GAP_SECS).
awake_mark() { MARK_WALL=$(date +%s); MARK_AWAKE=$(awake_secs); }
slept_since() {
    local s=$(( $(date +%s) - MARK_WALL - ($(awake_secs) - MARK_AWAKE) ))
    [ "$s" -ge "${SLEEP_GAP_SECS:-120}" ] || s=0
    echo "$s"
}

# A duration for a log line: 2h 05m, or 14m.
duration() {  # <secs>
    if [ "$1" -ge 3600 ]; then printf '%dh %02dm' $(($1 / 3600)) $(($1 % 3600 / 60)); else printf '%dm' $((($1 + 59) / 60)); fi
}

# The PID listening on a TCP port, or nothing. (BSD netstat has no -o, so on macOS the Windows form always said "free".)
port_pid() {
    if [ "$PLATFORM" = windows ]; then
        netstat -ano | tr -d '\r' | awk -v p=":$1" '$1=="TCP" && $4=="LISTENING" && $2 ~ (p "$") {print $5; exit}'
    else
        lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null | head -n 1
    fi
}

# Stop a process and its children.
kill_tree() {
    if [ "$PLATFORM" = windows ]; then
        taskkill //PID "$1" //T //F >/dev/null 2>&1
    else
        pkill -TERM -P "$1" >/dev/null 2>&1; kill -TERM "$1" >/dev/null 2>&1
    fi
}

# The run's Chrome is the one started with the run's profile (--user-data-dir); its main process has no --type= flag.
chrome_main_pid() {  # <profile dir>   (POSIX; on Windows raise_chrome.ps1 finds it)
    ps axww -o pid= -o command= | awk -v p="--user-data-dir=$1" \
        'index($0, p) && !index($0, "--type=") && !index($0, "awk -v") {print $1; exit}'
}

# Stop the Chrome started with that profile, never the owner's own.
chrome_stop() {  # <profile dir>
    if [ "$PLATFORM" = windows ]; then
        local pat; pat="$(cygpath -w "$1")"
        # -like treats only * ? [ ] as wildcards, so the Windows path goes in as it is
        powershell.exe -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='chrome.exe'\" | Where-Object { \$_.CommandLine -like '*${pat}*' } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force -ErrorAction SilentlyContinue }" >/dev/null 2>&1
    else
        local pid; pid=$(chrome_main_pid "$1")
        [ -z "$pid" ] || kill -TERM "$pid" >/dev/null 2>&1   # the main process takes its helpers with it
    fi
}
