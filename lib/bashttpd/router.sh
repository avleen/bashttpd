# shellcheck shell=bash
# lib/bashttpd/router.sh
#
# The configuration DSL. A bashttpd.conf is a bash script sourced once per
# request; these directives are what it calls to route requests. The first
# directive that matches handles the request and marks it done (REQUEST_HANDLED),
# so later directives short-circuit -- mirroring the legacy "first match wins"
# behavior, but without exiting the process.

# on_uri_match REGEX COMMAND [ARGS...]
# If the decoded request path matches REGEX, invoke COMMAND with ARGS followed
# by the capture groups (${BASH_REMATCH[@]}), exactly like the legacy version --
# except matching is done against the canonical decoded path, not the raw URI.
on_uri_match() {
    [[ -n $REQUEST_HANDLED ]] && return 0
    local regex=$1
    shift
    if [[ $REQUEST_PATH =~ $regex ]]; then
        "$@" "${BASH_REMATCH[@]}"
        REQUEST_HANDLED=1
    fi
    return 0
}

# on_method_match METHOD COMMAND [ARGS...]
# Dispatch when the request method equals METHOD (case-insensitive).
on_method_match() {
    [[ -n $REQUEST_HANDLED ]] && return 0
    local method=${1^^}
    shift
    if [[ ${REQUEST_METHOD^^} == "$method" ]]; then
        "$@" "$REQUEST_PATH"
        REQUEST_HANDLED=1
    fi
    return 0
}

# unconditionally COMMAND [ARGS...]
# Catch-all: always dispatch (unless already handled). The decoded path is
# appended as the final argument, matching the legacy calling convention.
unconditionally() {
    [[ -n $REQUEST_HANDLED ]] && return 0
    "$@" "$REQUEST_PATH"
    REQUEST_HANDLED=1
    return 0
}
