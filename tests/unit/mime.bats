#!/usr/bin/env bats
# Unit tests for lib/bashttpd/mime.sh -- pure functions, no network.

setup() {
    load '../test_helper'
    source_lib core mime
}

@test "mime: html" {
    [[ "$(mime_type_for foo.html)" == 'text/html; charset=utf-8' ]]
}

@test "mime: htm" {
    [[ "$(mime_type_for foo.htm)" == 'text/html; charset=utf-8' ]]
}

@test "mime: css" {
    [[ "$(mime_type_for style.css)" == 'text/css; charset=utf-8' ]]
}

@test "mime: js" {
    [[ "$(mime_type_for app.js)" == 'text/javascript; charset=utf-8' ]]
}

@test "mime: mjs" {
    [[ "$(mime_type_for app.mjs)" == 'text/javascript; charset=utf-8' ]]
}

@test "mime: json (not tagged text/*, no charset)" {
    [[ "$(mime_type_for data.json)" == 'application/json' ]]
}

@test "mime: png" {
    [[ "$(mime_type_for pic.png)" == 'image/png' ]]
}

@test "mime: svg" {
    [[ "$(mime_type_for icon.svg)" == 'image/svg+xml' ]]
}

@test "mime: woff2" {
    [[ "$(mime_type_for font.woff2)" == 'font/woff2' ]]
}

@test "mime: wasm" {
    [[ "$(mime_type_for mod.wasm)" == 'application/wasm' ]]
}

@test "mime: txt gets a charset" {
    [[ "$(mime_type_for note.txt)" == 'text/plain; charset=utf-8' ]]
}

@test "mime: md gets a charset" {
    [[ "$(mime_type_for readme.md)" == 'text/markdown; charset=utf-8' ]]
}

@test "mime: extension matching is case-insensitive" {
    [[ "$(mime_type_for FOO.HTML)" == 'text/html; charset=utf-8' ]]
    [[ "$(mime_type_for Photo.PNG)" == 'image/png' ]]
    [[ "$(mime_type_for Script.Js)" == 'text/javascript; charset=utf-8' ]]
}

@test "mime: unknown extension does not crash and returns a non-empty type" {
    local f="$BATS_TEST_TMPDIR/blob.zzzunknown"
    printf '\x01\x02\x03binarydata' > "$f"
    run mime_type_for "$f"
    [[ $status -eq 0 ]]
    [[ -n $output ]]
}

@test "mime: unknown extension on a binary file falls back to octet-stream (via file(1) or default)" {
    local f="$BATS_TEST_TMPDIR/blob.zzzunknown"
    # A byte sequence that isn't valid text, so file(1) -- if used -- should
    # not misidentify it as a text/* type either.
    head -c 256 /dev/urandom > "$f"
    run mime_type_for "$f"
    [[ $status -eq 0 ]]
    [[ $output != text/* ]]
}

@test "mime: unknown extension on a plain-text file gets a charset if file(1) identifies it as text" {
    local f="$BATS_TEST_TMPDIR/note.zzzunknown"
    printf 'just some plain ascii text\n' > "$f"
    run mime_type_for "$f"
    [[ $status -eq 0 ]]
    if command -v file >/dev/null 2>&1; then
        local detected
        detected=$(file -b --mime-type -- "$f")
        if [[ $detected == text/* ]]; then
            [[ $output == *'charset=utf-8'* ]]
        else
            [[ $output == "$detected" ]]
        fi
    else
        [[ $output == 'application/octet-stream' ]]
    fi
}

@test "mime: no extension at all still resolves to something" {
    local f="$BATS_TEST_TMPDIR/noext"
    printf 'data' > "$f"
    run mime_type_for "$f"
    [[ $status -eq 0 ]]
    [[ -n $output ]]
}
