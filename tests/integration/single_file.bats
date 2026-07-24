#!/usr/bin/env bats
# Integration tests for the self-contained single-file build (dist/bashttpd).
#
# The build is produced by scripts/build-single.sh, then a *copy* of the single
# file is dropped into an otherwise-empty directory (no lib/, no repo) and
# exercised from there -- proving it needs neither lib/ nor BASHTTPD_LIB_DIR at
# runtime and behaves like bin/bashttpd. Server lifecycle reuses the shared
# start_server/stop_server helpers by pointing BASHTTPD_BIN at the copy.

setup() {
    load '../test_helper'

    # Build the artifact (idempotent; a no-op once dist/ is up to date).
    run "$REPO_ROOT/scripts/build-single.sh"
    [[ $status -eq 0 ]]
    [[ -x "$REPO_ROOT/dist/bashttpd" ]]

    # Copy the single file into an empty dir with nothing else around it.
    STANDALONE_DIR="$BATS_TEST_TMPDIR/standalone"
    mkdir -p "$STANDALONE_DIR"
    cp "$REPO_ROOT/dist/bashttpd" "$STANDALONE_DIR/bashttpd"
    chmod +x "$STANDALONE_DIR/bashttpd"

    # Point the shared server helpers at the standalone copy.
    BASHTTPD_BIN="$STANDALONE_DIR/bashttpd"

    DOCROOT="$BATS_TEST_TMPDIR/docroot"
    mkdir -p "$DOCROOT"
    INDEX_BODY='<html><body>single-file index</body></html>'
    printf '%s' "$INDEX_BODY" > "$DOCROOT/index.html"
    NOTE_BODY='plain note text'
    printf '%s' "$NOTE_BODY" > "$DOCROOT/note.txt"
}

teardown() {
    stop_server
}

@test "single-file: build produced an executable dist/bashttpd" {
    [[ -x "$REPO_ROOT/dist/bashttpd" ]]
    run head -1 "$REPO_ROOT/dist/bashttpd"
    [[ $output == '#!/usr/bin/env bash' ]]
}

@test "single-file: version works from a standalone copy (no lib/, no repo)" {
    run "$STANDALONE_DIR/bashttpd" version
    [[ $status -eq 0 ]]
    [[ $output =~ ^bashttpd\ [0-9]+\.[0-9]+ ]]
}

@test "single-file: the standalone dir contains only the one file" {
    run find "$STANDALONE_DIR" -mindepth 1
    [[ $status -eq 0 ]]
    [[ $output == "$STANDALONE_DIR/bashttpd" ]]
}

@test "single-file: serve from the standalone copy answers 200 / 404 / HEAD" {
    start_server -d "$DOCROOT"

    local code
    code=$(curl -s -o "$BATS_TEST_TMPDIR/body.out" -w '%{http_code}' "$SERVER_BASE/")
    [[ $code -eq 200 ]]
    diff <(printf '%s' "$INDEX_BODY") "$BATS_TEST_TMPDIR/body.out"

    code=$(curl -s -o /dev/null -w '%{http_code}' "$SERVER_BASE/does/not/exist")
    [[ $code -eq 404 ]]

    local head_headers head_body
    head_headers=$(curl -s -I "$SERVER_BASE/note.txt")
    [[ $(http_status_code "$head_headers") -eq 200 ]]
    [[ $(header_value "$head_headers" 'Content-Length') -eq ${#NOTE_BODY} ]]
    head_body=$(curl -s --head "$SERVER_BASE/note.txt" | sed '1,/^\r*$/d')
    [[ -z $head_body ]]
}

@test "single-file: handle mode serves one connection over stdin/stdout (inetd-style)" {
    local resp first
    resp=$(printf 'GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n' \
        | BASHTTPD_DOCROOT="$DOCROOT" "$STANDALONE_DIR/bashttpd" handle)
    first=$(printf '%s\n' "$resp" | head -1 | tr -d '\r')
    [[ $first == 'HTTP/1.1 200 OK' ]]
    [[ $resp == *"$INDEX_BODY"* ]]
}
