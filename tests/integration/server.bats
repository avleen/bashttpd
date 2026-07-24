#!/usr/bin/env bats
# Integration tests against a live bashttpd server serving a temp docroot.

setup() {
    load '../test_helper'

    DOCROOT="$BATS_TEST_TMPDIR/docroot"
    mkdir -p "$DOCROOT/subdir"

    INDEX_BODY='<html><body>Index page</body></html>'
    printf '%s' "$INDEX_BODY" > "$DOCROOT/index.html"

    printf 'hello from subdir\n' > "$DOCROOT/subdir/hello.txt"

    NOTE_BODY='plain note text'
    printf '%s' "$NOTE_BODY" > "$DOCROOT/note.txt"

    head -c 4096 /dev/urandom > "$DOCROOT/blob.bin"

    SPACE_BODY='space file content'
    printf '%s' "$SPACE_BODY" > "$DOCROOT/my file.txt"

    UNREADABLE="$DOCROOT/secret.txt"
    printf 'top secret' > "$UNREADABLE"
    chmod 000 "$UNREADABLE"

    start_server -d "$DOCROOT"
}

teardown() {
    chmod 700 "$UNREADABLE" 2>/dev/null || true
    stop_server
}

# --- basic GET -----------------------------------------------------------

@test "GET / returns 200 with correct Content-Type and Content-Length" {
    local headers
    headers=$(curl -s -D - -o "$BATS_TEST_TMPDIR/body.out" "$SERVER_BASE/")
    local code ct clen
    code=$(http_status_code "$headers")
    ct=$(header_value "$headers" 'Content-Type')
    clen=$(header_value "$headers" 'Content-Length')
    [[ $code -eq 200 ]]
    [[ $ct == 'text/html; charset=utf-8' ]]
    [[ $clen -eq ${#INDEX_BODY} ]]
    diff <(printf '%s' "$INDEX_BODY") "$BATS_TEST_TMPDIR/body.out"
}

# --- directory redirect / listing -----------------------------------------

@test "GET /subdir (no trailing slash) returns 301 to /subdir/" {
    local headers
    headers=$(curl -s -D - -o /dev/null "$SERVER_BASE/subdir")
    local code loc
    code=$(http_status_code "$headers")
    loc=$(header_value "$headers" 'Location')
    [[ $code -eq 301 ]]
    [[ $loc == '/subdir/' ]]
}

@test "GET /subdir/ lists the directory contents" {
    run curl -s "$SERVER_BASE/subdir/"
    [[ $status -eq 0 ]]
    [[ $output == *'hello.txt'* ]]
}

# --- 404 / 403 -------------------------------------------------------------

@test "GET missing path returns 404" {
    run curl -s -o /dev/null -w '%{http_code}' "$SERVER_BASE/does/not/exist"
    [[ $output == '404' ]]
}

@test "GET an unreadable file returns 403 (skipped when running as root)" {
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        skip "running as root bypasses file permission checks"
    fi
    run curl -s -o /dev/null -w '%{http_code}' "$SERVER_BASE/secret.txt"
    [[ $output == '403' ]]
}

# --- HEAD --------------------------------------------------------------------

@test "HEAD returns 200, no body, and the same Content-Length as GET" {
    local get_headers head_headers get_clen head_clen head_body
    get_headers=$(curl -s -D - -o /dev/null "$SERVER_BASE/note.txt")
    head_headers=$(curl -s -I "$SERVER_BASE/note.txt")
    get_clen=$(header_value "$get_headers" 'Content-Length')
    head_clen=$(header_value "$head_headers" 'Content-Length')
    head_body=$(curl -s --head "$SERVER_BASE/note.txt" | sed '1,/^\r*$/d')
    [[ $(http_status_code "$head_headers") -eq 200 ]]
    [[ $get_clen -eq $head_clen ]]
    [[ $get_clen -eq ${#NOTE_BODY} ]]
    [[ -z $head_body ]]
}

# --- method handling -----------------------------------------------------

@test "POST to a GET-only route returns 405 with an Allow header" {
    local headers code allow
    headers=$(curl -s -D - -o /dev/null -X POST -d 'x=1' "$SERVER_BASE/")
    code=$(http_status_code "$headers")
    allow=$(header_value "$headers" 'Allow')
    [[ $code -eq 405 ]]
    [[ $allow == 'GET, HEAD, OPTIONS' ]]
}

@test "OPTIONS returns 204 with an Allow header" {
    local headers code allow
    headers=$(curl -s -D - -o /dev/null -X OPTIONS "$SERVER_BASE/")
    code=$(http_status_code "$headers")
    allow=$(header_value "$headers" 'Allow')
    [[ $code -eq 204 ]]
    [[ $allow == 'GET, HEAD, OPTIONS' ]]
}

# --- keep-alive / connection handling --------------------------------------

@test "keep-alive: two requests on one curl invocation reuse a single connection" {
    # -o /dev/null must be repeated once per URL -- curl's -o is a
    # per-transfer option, and with only one instance the second URL's body
    # would fall through to stdout instead of being discarded.
    run curl -s -o /dev/null -o /dev/null -w '%{num_connects} ' \
        "$SERVER_BASE/note.txt" "$SERVER_BASE/index.html"
    [[ $status -eq 0 ]]
    local total=0 n
    for n in $output; do total=$(( total + n )); done
    [[ $total -eq 1 ]]
}

@test "Connection: close forces a fresh connection for each request" {
    run curl -s -o /dev/null -o /dev/null -w '%{num_connects} ' -H 'Connection: close' \
        "$SERVER_BASE/note.txt" "$SERVER_BASE/index.html"
    [[ $status -eq 0 ]]
    local total=0 n
    for n in $output; do total=$(( total + n )); done
    [[ $total -eq 2 ]]
}

# --- percent-encoded paths / binary integrity ------------------------------

@test "percent-encoded space in filename resolves correctly" {
    local code body
    code=$(curl -s -o /dev/null -w '%{http_code}' "$SERVER_BASE/my%20file.txt")
    body=$(curl -s "$SERVER_BASE/my%20file.txt")
    [[ $code -eq 200 ]]
    [[ $body == "$SPACE_BODY" ]]
}

@test "binary file is transferred byte-identical" {
    curl -s "$SERVER_BASE/blob.bin" -o "$BATS_TEST_TMPDIR/blob.out"
    cmp -s "$DOCROOT/blob.bin" "$BATS_TEST_TMPDIR/blob.out"
}

@test "binary file gets an octet-stream Content-Type" {
    run curl -s -o /dev/null -D - "$SERVER_BASE/blob.bin"
    local ct
    ct=$(header_value "$output" 'Content-Type')
    [[ $ct == 'application/octet-stream' ]]
}

# --- path traversal ----------------------------------------------------------

@test "path traversal via --path-as-is does not leak files outside the docroot" {
    local code
    code=$(curl -s --path-as-is -o "$BATS_TEST_TMPDIR/trav.out" -w '%{http_code}' \
        "$SERVER_BASE/../../../../etc/passwd")
    [[ $code == 400 || $code == 404 ]]
    if [[ -s "$BATS_TEST_TMPDIR/trav.out" ]]; then
        run grep -q 'root:' "$BATS_TEST_TMPDIR/trav.out"
        [[ $status -ne 0 ]]
    fi
}

# --- raw protocol edge cases (via nc) ---------------------------------------

@test "a malformed request line returns 400 Bad Request" {
    local resp
    resp=$(raw_request "$SERVER_PORT" 'GARBAGE\r\n\r\n')
    local first
    first=$(printf '%s\n' "$resp" | head -1 | tr -d '\r')
    [[ $first == 'HTTP/1.1 400 Bad Request' ]]
}

@test "HTTP/2.0 in the request line returns 505" {
    local resp
    resp=$(raw_request "$SERVER_PORT" 'GET / HTTP/2.0\r\nHost: x\r\n\r\n')
    local first
    first=$(printf '%s\n' "$resp" | head -1 | tr -d '\r')
    [[ $first == 'HTTP/1.1 505 HTTP Version Not Supported' ]]
}

@test "an HTTP/0.9-style request line (no version) returns 505" {
    local resp
    resp=$(raw_request "$SERVER_PORT" 'GET /\r\n\r\n')
    local first
    first=$(printf '%s\n' "$resp" | head -1 | tr -d '\r')
    [[ $first == 'HTTP/1.1 505 HTTP Version Not Supported' ]]
}

@test "HTTP/1.1 without a Host header returns 400" {
    local resp
    resp=$(raw_request "$SERVER_PORT" 'GET / HTTP/1.1\r\n\r\n')
    local first
    first=$(printf '%s\n' "$resp" | head -1 | tr -d '\r')
    [[ $first == 'HTTP/1.1 400 Bad Request' ]]
}

@test "Transfer-Encoding: chunked returns 501 Not Implemented" {
    local resp
    resp=$(raw_request "$SERVER_PORT" 'POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n')
    local first
    first=$(printf '%s\n' "$resp" | head -1 | tr -d '\r')
    [[ $first == 'HTTP/1.1 501 Not Implemented' ]]
}

@test "a request body is fully drained so a following request on the same connection still works" {
    local body='a=1&b=2'
    local clen=${#body}
    local reqfile="$BATS_TEST_TMPDIR/two-requests.raw"

    # Build the raw byte stream in a file (redirection preserves exact bytes,
    # unlike a $(...) capture which would strip the trailing blank-line CRLF).
    {
        printf 'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\nConnection: keep-alive\r\n\r\n%s' "$clen" "$body"
        printf 'GET /note.txt HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n'
    } > "$reqfile"

    local resp
    resp=$(timeout 5 nc -q1 127.0.0.1 "$SERVER_PORT" < "$reqfile")

    local -a statuses
    mapfile -t statuses < <(printf '%s\n' "$resp" | tr -d '\r' | grep -o '^HTTP/1\.1 [0-9]\{3\}')
    [[ ${#statuses[@]} -eq 2 ]]
    [[ ${statuses[0]} == 'HTTP/1.1 405' ]]   # POST isn't allowed by the default docroot route
    [[ ${statuses[1]} == 'HTTP/1.1 200' ]]
    [[ $resp == *"$NOTE_BODY"* ]]
}
