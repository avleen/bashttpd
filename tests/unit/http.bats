#!/usr/bin/env bats
# Unit tests for lib/bashttpd/http.sh -- pure functions, no network.

setup() {
    load '../test_helper'
    source_lib core http
}

# --- http_urldecode ----------------------------------------------------------

@test "urldecode: plain string is unchanged" {
    run http_urldecode 'hello'
    [[ $status -eq 0 ]]
    [[ $output == 'hello' ]]
}

@test "urldecode: %20 becomes a space" {
    run http_urldecode 'hello%20world'
    [[ $output == 'hello world' ]]
}

@test "urldecode: %2F becomes a slash" {
    run http_urldecode 'a%2Fb'
    [[ $output == 'a/b' ]]
}

@test "urldecode: lowercase hex escapes work too" {
    run http_urldecode 'a%2fb%2c'
    [[ $output == $'a/b,' ]]
}

@test "urldecode: UTF-8 multibyte sequence decodes to the right bytes" {
    # %e2%82%ac is U+20AC EURO SIGN in UTF-8.
    run http_urldecode '%e2%82%ac'
    local expected
    expected=$(printf '\xe2\x82\xac')
    [[ $output == "$expected" ]]
}

@test "urldecode: invalid percent sequence at end of string passes through" {
    run http_urldecode 'abc%'
    [[ $output == 'abc%' ]]
}

@test "urldecode: invalid percent sequence (non-hex) passes through literally" {
    run http_urldecode 'abc%zzdef'
    [[ $output == 'abc%zzdef' ]]
}

@test "urldecode: truncated percent sequence (one hex digit) passes through" {
    run http_urldecode 'abc%2'
    [[ $output == 'abc%2' ]]
}

@test "urldecode: plus sign is NOT converted to space" {
    run http_urldecode 'a+b'
    [[ $output == 'a+b' ]]
}

# --- http_canonicalize_path ---------------------------------------------------

@test "canonicalize: strips query string" {
    run http_canonicalize_path '/a/b?x=1&y=2'
    [[ $status -eq 0 ]]
    [[ $output == '/a/b' ]]
}

@test "canonicalize: collapses ./ segments" {
    run http_canonicalize_path '/a/./b/./c'
    [[ $status -eq 0 ]]
    [[ $output == '/a/b/c' ]]
}

@test "canonicalize: collapses duplicate slashes" {
    run http_canonicalize_path '/a//b///c'
    [[ $status -eq 0 ]]
    [[ $output == '/a/b/c' ]]
}

@test "canonicalize: resolves .. lexically" {
    run http_canonicalize_path '/a/b/../c'
    [[ $status -eq 0 ]]
    [[ $output == '/a/c' ]]
}

@test "canonicalize: .. that would escape the root is rejected" {
    run http_canonicalize_path '/../etc/passwd'
    [[ $status -eq 1 ]]
}

@test "canonicalize: multiple leading .. escaping root is rejected" {
    run http_canonicalize_path '/../../../etc/passwd'
    [[ $status -eq 1 ]]
}

@test "canonicalize: encoded %2e%2e traversal is rejected" {
    run http_canonicalize_path '/%2e%2e/%2e%2e/etc/passwd'
    [[ $status -eq 1 ]]
}

@test "canonicalize: encoded %2e%2e that stays within root resolves normally" {
    run http_canonicalize_path '/a/b/%2e%2e/c'
    [[ $status -eq 0 ]]
    [[ $output == '/a/c' ]]
}

@test "canonicalize: root path stays root" {
    run http_canonicalize_path '/'
    [[ $status -eq 0 ]]
    [[ $output == '/' ]]
}

@test "canonicalize: trailing slash is preserved" {
    run http_canonicalize_path '/subdir/'
    [[ $status -eq 0 ]]
    [[ $output == '/subdir/' ]]
}

@test "canonicalize: no trailing slash stays without one" {
    run http_canonicalize_path '/subdir'
    [[ $status -eq 0 ]]
    [[ $output == '/subdir' ]]
}

@test "canonicalize: encoded NUL is rejected" {
    run http_canonicalize_path '/a%00b'
    [[ $status -eq 1 ]]
}

@test "canonicalize: encoded newline is rejected" {
    run http_canonicalize_path '/a%0ab'
    [[ $status -eq 1 ]]
}

@test "canonicalize: dot-only segment among real ones collapses away" {
    run http_canonicalize_path '/./a/.'
    [[ $status -eq 0 ]]
    [[ $output == '/a' ]]
}

# --- http_parse_request_line --------------------------------------------------

@test "parse request line: valid GET" {
    run bash -c '
        source "'"$LIB_DIR"'/http.sh"
        http_parse_request_line "GET / HTTP/1.1"
        echo "status=$?"
        echo "method=$REQUEST_METHOD"
        echo "uri=$REQUEST_URI"
        echo "version=$REQUEST_HTTP_VERSION"
    '
    [[ $status -eq 0 ]]
    [[ $output == *'status=0'* ]]
    [[ $output == *'method=GET'* ]]
    [[ $output == *'uri=/'* ]]
    [[ $output == *'version=HTTP/1.1'* ]]
}

@test "parse request line: valid HEAD with path and query" {
    run bash -c '
        source "'"$LIB_DIR"'/http.sh"
        http_parse_request_line "HEAD /a/b?x=1 HTTP/1.0"
        echo "status=$?"; echo "method=$REQUEST_METHOD"; echo "uri=$REQUEST_URI"; echo "version=$REQUEST_HTTP_VERSION"
    '
    [[ $output == *'status=0'* ]]
    [[ $output == *'method=HEAD'* ]]
    [[ $output == *'uri=/a/b?x=1'* ]]
    [[ $output == *'version=HTTP/1.0'* ]]
}

@test "parse request line: bad HTTP version yields PARSE_STATUS=505" {
    run bash -c '
        source "'"$LIB_DIR"'/http.sh"
        http_parse_request_line "GET / HTTP/2.0"
        echo "status=$?"; echo "parse_status=$PARSE_STATUS"
    '
    [[ $output == *'status=1'* ]]
    [[ $output == *'parse_status=505'* ]]
}

@test "parse request line: missing version (HTTP/0.9 style) yields 505" {
    run bash -c '
        source "'"$LIB_DIR"'/http.sh"
        http_parse_request_line "GET /"
        echo "status=$?"; echo "parse_status=$PARSE_STATUS"
    '
    [[ $output == *'status=1'* ]]
    [[ $output == *'parse_status=505'* ]]
}

@test "parse request line: garbage with no target yields PARSE_STATUS=400" {
    run bash -c '
        source "'"$LIB_DIR"'/http.sh"
        http_parse_request_line "GARBAGE"
        echo "status=$?"; echo "parse_status=$PARSE_STATUS"
    '
    [[ $output == *'status=1'* ]]
    [[ $output == *'parse_status=400'* ]]
}

@test "parse request line: non-alpha method is rejected as 400" {
    run bash -c '
        source "'"$LIB_DIR"'/http.sh"
        http_parse_request_line "G3T / HTTP/1.1"
        echo "status=$?"; echo "parse_status=$PARSE_STATUS"
    '
    [[ $output == *'status=1'* ]]
    [[ $output == *'parse_status=400'* ]]
}

@test "parse request line: empty line yields PARSE_STATUS=400" {
    run bash -c '
        source "'"$LIB_DIR"'/http.sh"
        http_parse_request_line ""
        echo "status=$?"; echo "parse_status=$PARSE_STATUS"
    '
    [[ $output == *'status=1'* ]]
    [[ $output == *'parse_status=400'* ]]
}

# --- http_parse_header_line ---------------------------------------------------

@test "parse header: simple header lowercases the key and keeps value" {
    run bash -c '
        source "'"$LIB_DIR"'/http.sh"
        http_parse_header_line "Host: example.com"
        echo "status=$?"; echo "key=$HEADER_KEY"; echo "val=$HEADER_VALUE"
    '
    [[ $output == *'status=0'* ]]
    [[ $output == *'key=host'* ]]
    [[ $output == *'val=example.com'* ]]
}

@test "parse header: mixed-case key is lowercased" {
    run bash -c '
        source "'"$LIB_DIR"'/http.sh"
        http_parse_header_line "CONTENT-Type: text/plain"
        echo "key=$HEADER_KEY"
    '
    [[ $output == *'key=content-type'* ]]
}

@test "parse header: surrounding whitespace on the value is trimmed" {
    run bash -c '
        source "'"$LIB_DIR"'/http.sh"
        http_parse_header_line "X-Test:   value with spaces   "
        echo "val=[$HEADER_VALUE]"
    '
    [[ $output == *'val=[value with spaces]'* ]]
}

@test "parse header: no colon is malformed" {
    run bash -c '
        source "'"$LIB_DIR"'/http.sh"
        http_parse_header_line "NotAHeader"
        echo "status=$?"
    '
    [[ $output == *'status=1'* ]]
}

@test "parse header: whitespace in the field name is rejected" {
    run bash -c '
        source "'"$LIB_DIR"'/http.sh"
        http_parse_header_line "Bad Name: value"
        echo "status=$?"
    '
    [[ $output == *'status=1'* ]]
}

@test "parse header: empty field name is rejected" {
    run bash -c '
        source "'"$LIB_DIR"'/http.sh"
        http_parse_header_line ": value"
        echo "status=$?"
    '
    [[ $output == *'status=1'* ]]
}

@test "parse header: empty value is allowed" {
    run bash -c '
        source "'"$LIB_DIR"'/http.sh"
        http_parse_header_line "X-Empty:"
        echo "status=$?"; echo "val=[$HEADER_VALUE]"
    '
    [[ $output == *'status=0'* ]]
    [[ $output == *'val=[]'* ]]
}

# --- http_status_text ---------------------------------------------------------

@test "status text: known codes map to the right reason phrase" {
    [[ "$(http_status_text 200)" == 'OK' ]]
    [[ "$(http_status_text 204)" == 'No Content' ]]
    [[ "$(http_status_text 301)" == 'Moved Permanently' ]]
    [[ "$(http_status_text 400)" == 'Bad Request' ]]
    [[ "$(http_status_text 403)" == 'Forbidden' ]]
    [[ "$(http_status_text 404)" == 'Not Found' ]]
    [[ "$(http_status_text 405)" == 'Method Not Allowed' ]]
    [[ "$(http_status_text 501)" == 'Not Implemented' ]]
    [[ "$(http_status_text 505)" == 'HTTP Version Not Supported' ]]
}

@test "status text: unknown code falls back to Unknown" {
    [[ "$(http_status_text 999)" == 'Unknown' ]]
}

# --- res_send / res_add_header ------------------------------------------------

@test "res_send: status line and headers use CRLF, verified byte-exact" {
    SERVER_TOKEN='bashttpd/test'
    RESPONSE_CONNECTION='close'
    REQUEST_METHOD='GET'
    res_init
    res_send 200 -s 'hello' > "$BATS_TEST_TMPDIR/resp.raw"
    run head -1 "$BATS_TEST_TMPDIR/resp.raw"
    # The first line read by `head` has its trailing \r\n stripped down to
    # nothing by command substitution trimming \n, but \r survives as the
    # last character -- confirm it's there.
    local first_line
    first_line=$(head -c 200 "$BATS_TEST_TMPDIR/resp.raw" | head -1)
    [[ $first_line == *$'\r' ]]
    [[ $first_line == 'HTTP/1.1 200 OK'$'\r' ]]
}

@test "res_send: Content-Length matches the byte length of the body" {
    SERVER_TOKEN='bashttpd/test'
    RESPONSE_CONNECTION='close'
    REQUEST_METHOD='GET'
    res_init
    res_send 200 -s 'hello world' > "$BATS_TEST_TMPDIR/resp.raw"
    local clen
    clen=$(tr -d '\r' < "$BATS_TEST_TMPDIR/resp.raw" | awk 'tolower($1)=="content-length:"{print $2}')
    [[ $clen -eq 11 ]]
}

@test "res_send: HEAD suppresses the body but keeps Content-Length" {
    SERVER_TOKEN='bashttpd/test'
    RESPONSE_CONNECTION='close'
    REQUEST_METHOD='HEAD'
    res_init
    res_send 200 -s 'hello world' > "$BATS_TEST_TMPDIR/resp.raw"
    local clen body
    clen=$(tr -d '\r' < "$BATS_TEST_TMPDIR/resp.raw" | awk 'tolower($1)=="content-length:"{print $2}')
    body=$(sed '1,/^\r*$/d' "$BATS_TEST_TMPDIR/resp.raw")
    [[ $clen -eq 11 ]]
    [[ -z $body ]]
}

@test "res_send: queued headers appear in the response" {
    SERVER_TOKEN='bashttpd/test'
    RESPONSE_CONNECTION='close'
    REQUEST_METHOD='GET'
    res_init
    res_add_header 'Content-Type' 'text/plain; charset=utf-8'
    res_send 200 -s 'hi' > "$BATS_TEST_TMPDIR/resp.raw"
    local ct
    ct=$(tr -d '\r' < "$BATS_TEST_TMPDIR/resp.raw" | awk -F': ' 'tolower($1)=="content-type"{print $2}')
    [[ $ct == 'text/plain; charset=utf-8' ]]
}

@test "res_send_error: produces an HTML body with the right status" {
    SERVER_TOKEN='bashttpd/test'
    RESPONSE_CONNECTION='close'
    REQUEST_METHOD='GET'
    res_init
    res_send_error 404 > "$BATS_TEST_TMPDIR/resp.raw"
    local code
    code=$(head -1 "$BATS_TEST_TMPDIR/resp.raw" | awk '{print $2}')
    [[ $code -eq 404 ]]
    grep -q '404 Not Found' "$BATS_TEST_TMPDIR/resp.raw"
}
