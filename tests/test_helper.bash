# tests/test_helper.bash
#
# Shared helpers for the bats test suite: repo-root resolution, sourcing pure
# lib modules, starting/stopping a live bashttpd server on a private port, and
# small assertion helpers used by both unit and integration tests.
#
# All helpers are careful to avoid text-pattern process matching (pkill -f)
# since the search pattern can match the invoking shell's own command line
# and kill the wrong thing. Instead we track exact PIDs: bin/bashttpd execs
# straight into socat (no intermediate fork), so `bin/bashttpd serve ... &`
# followed by capturing $! gives the *exact* PID of the listener process.

# --- Repo root ---------------------------------------------------------------
# BATS_TEST_DIRNAME is tests/unit or tests/integration; the repo root is one
# level above tests/.
repo_root() {
    local dir="${BATS_TEST_DIRNAME:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
    ( cd "$dir/../.." && pwd )
}

REPO_ROOT="$(repo_root)"
BASHTTPD_BIN="$REPO_ROOT/bin/bashttpd"
LIB_DIR="$REPO_ROOT/lib/bashttpd"

# source_lib MODULE... -- source one or more pure lib/bashttpd/*.sh modules
# directly into the current shell, for unit testing without a live server.
source_lib() {
    local m
    for m in "$@"; do
        # shellcheck source=/dev/null
        source "$LIB_DIR/$m.sh"
    done
}

# --- Free port discovery ------------------------------------------------------
# _port_in_use PORT -- succeeds (0) if something is already listening on
# 127.0.0.1:PORT, fails otherwise. Uses bash's /dev/tcp so no extra tools are
# needed.
_port_in_use() {
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
    local rc=$?
    exec 3<&- 2>/dev/null
    exec 3>&- 2>/dev/null
    return $rc
}

# pick_free_port -- print a free TCP port on stdout. Tries random ports in the
# high range derived from $RANDOM until one looks free.
pick_free_port() {
    local port tries
    for (( tries = 0; tries < 100; tries++ )); do
        port=$(( 20000 + (RANDOM % 25000) ))
        if ! _port_in_use "$port"; then
            printf '%s' "$port"
            return 0
        fi
    done
    return 1
}

# --- Server lifecycle ---------------------------------------------------------
# start_server [bashttpd-serve-args...]
# Starts `bin/bashttpd serve` on 127.0.0.1:<free port> with the given extra
# args (e.g. -d DOCROOT, -c CONFIG, --tls --cert ... --key ...), waits for it
# to accept connections, and sets:
#   SERVER_PID, SERVER_PORT, SERVER_LOG, SERVER_BASE (scheme://host:port)
# Returns 1 (and dumps the server log) if it never becomes ready.
start_server() {
    local extra_args=("$@")
    local scheme=http a
    for a in "${extra_args[@]}"; do
        [[ $a == --tls ]] && scheme=https
    done

    SERVER_PORT=$(pick_free_port) || { echo "no free port found" >&2; return 1; }
    SERVER_LOG="${BATS_TEST_TMPDIR:-/tmp}/server-$SERVER_PORT.log"
    SERVER_BASE="$scheme://127.0.0.1:$SERVER_PORT"

    # bin/bashttpd execs straight into socat/ncat -- no intermediate fork --
    # so $! below is the exact PID of the listener process.
    "$BASHTTPD_BIN" serve -a 127.0.0.1 -p "$SERVER_PORT" "${extra_args[@]}" \
        >"$SERVER_LOG" 2>&1 < /dev/null &
    SERVER_PID=$!

    # Wait for readiness via curl's own retry engine (no manual sleep loop).
    # -k tolerates the self-signed TLS cert; harmless for plain http.
    if ! timeout 10 curl -ks -o /dev/null \
            --retry 200 --retry-delay 0 --retry-connrefused --retry-all-errors \
            --max-time 8 \
            "$SERVER_BASE/" 2>/dev/null
    then
        if ! kill -0 "$SERVER_PID" 2>/dev/null; then
            echo "server process exited before becoming ready; log:" >&2
            cat "$SERVER_LOG" >&2 || true
        else
            echo "server never became ready; log:" >&2
            cat "$SERVER_LOG" >&2 || true
        fi
        return 1
    fi

    return 0
}

# _kill_tree PID SIGNAL -- send SIGNAL to PID and (recursively) its children,
# found by exact PID relationship (pgrep -P), never by text pattern.
_kill_tree() {
    local pid=$1 sig=$2 child
    if command -v pgrep >/dev/null 2>&1; then
        for child in $(pgrep -P "$pid" 2>/dev/null); do
            _kill_tree "$child" "$sig"
        done
    fi
    kill -"$sig" "$pid" 2>/dev/null
}

# stop_server -- terminate the server started by start_server and reap it, so
# no listener or handler process is left behind. Safe to call multiple times.
stop_server() {
    local pid=${SERVER_PID:-}
    [[ -n $pid ]] || return 0

    if kill -0 "$pid" 2>/dev/null; then
        _kill_tree "$pid" TERM
        # Wait for the exact PID to exit, bounded, without a manual sleep-poll
        # loop: `tail --pid` blocks until the process exits.
        if command -v tail >/dev/null 2>&1; then
            timeout 3 tail --pid="$pid" -f /dev/null 2>/dev/null
        fi
        kill -0 "$pid" 2>/dev/null && _kill_tree "$pid" KILL
    fi
    wait "$pid" 2>/dev/null
    SERVER_PID=''
}

# --- Small assertion helpers ---------------------------------------------------

# status_line_of HEADERS -> the HTTP status code (second word of first line).
http_status_code() {
    printf '%s' "$1" | head -1 | tr -d '\r' | awk '{print $2}'
}

# header_value HEADERS NAME -> the value of header NAME (case-insensitive),
# with a single leading space stripped.
header_value() {
    printf '%s\n' "$1" | tr -d '\r' | awk -v want="${2,,}:" '
        { key = tolower($1) }
        key == want { $1=""; sub(/^ /,""); print; exit }
    '
}

# raw_request PORT REQUEST_BYTES [TIMEOUT] -> send raw bytes to 127.0.0.1:PORT
# and print whatever comes back, using nc. Used for protocol-edge-case tests
# where curl won't let us send malformed request lines.
raw_request() {
    local port=$1 payload=$2 t=${3:-3}
    printf '%b' "$payload" | timeout "$t" nc -q1 127.0.0.1 "$port" 2>/dev/null
}
