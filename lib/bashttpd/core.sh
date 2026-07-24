# shellcheck shell=bash
# lib/bashttpd/core.sh
#
# Core setup for bashttpd: version constants, logging helpers, and a couple
# of small utilities shared across the other modules. Sourced first, so the
# constants and functions defined here are available everywhere.

# Version / server identity. Bumped from the legacy 1.x line.
BASHTTPD_VERSION='2.0'
# shellcheck disable=SC2034  # consumed by http.sh/server.sh response headers
SERVER_TOKEN="bashttpd/${BASHTTPD_VERSION}"

# ---------------------------------------------------------------------------
# Logging. Everything goes to stderr so it never contaminates the HTTP
# response written to stdout. log_info is gated behind BASHTTPD_VERBOSE.
# ---------------------------------------------------------------------------

log_info() {
    [[ ${BASHTTPD_VERBOSE:-0} == 1 ]] && printf '[info] %s\n' "$*" >&2
    return 0
}

log_warn() {
    printf '[warn] %s\n' "$*" >&2
    return 0
}

log_error() {
    printf '[error] %s\n' "$*" >&2
    return 0
}

# core_init: one-time per-process setup for the request handler. Warns when
# running as root (a bad idea for a toy HTTP server) and applies sane shell
# options. We intentionally avoid `set -e` in the request hot path: a single
# failing builtin should not tear down a live connection.
core_init() {
    # Do not let a broken pipe (client hung up) kill the process abruptly;
    # the request loop checks write/read results instead.
    trap '' PIPE

    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        log_warn 'running as root is not recommended.'
    fi
}
