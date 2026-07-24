#!/usr/bin/env bats
# Integration tests for the bin/bashttpd CLI subcommands (no live server
# needed for most of these).

setup() {
    load '../test_helper'
}

@test "--version prints the version" {
    run "$BASHTTPD_BIN" --version
    [[ $status -eq 0 ]]
    [[ $output =~ ^bashttpd\ [0-9]+\.[0-9]+ ]]
}

@test "version subcommand prints the version" {
    run "$BASHTTPD_BIN" version
    [[ $status -eq 0 ]]
    [[ $output =~ ^bashttpd\ [0-9]+\.[0-9]+ ]]
}

@test "--help mentions serve and handle" {
    run "$BASHTTPD_BIN" --help
    [[ $status -eq 0 ]]
    [[ $output == *'serve'* ]]
    [[ $output == *'handle'* ]]
}

@test "help subcommand mentions serve and handle" {
    run "$BASHTTPD_BIN" help
    [[ $status -eq 0 ]]
    [[ $output == *'serve'* ]]
    [[ $output == *'handle'* ]]
}

@test "init-config writes an example config file" {
    cd "$BATS_TEST_TMPDIR"
    run "$BASHTTPD_BIN" init-config myconf.conf
    [[ $status -eq 0 ]]
    [[ -f myconf.conf ]]
    grep -q 'on_uri_match' myconf.conf
}

@test "init-config refuses to overwrite an existing file" {
    cd "$BATS_TEST_TMPDIR"
    printf 'sentinel-content\n' > existing.conf
    run "$BASHTTPD_BIN" init-config existing.conf
    [[ $status -ne 0 ]]
    # The original file must be untouched.
    run cat existing.conf
    [[ $output == 'sentinel-content' ]]
}

@test "init-config with default destination writes ./bashttpd.conf" {
    cd "$BATS_TEST_TMPDIR"
    run "$BASHTTPD_BIN" init-config
    [[ $status -eq 0 ]]
    [[ -f bashttpd.conf ]]
}

@test "--tls without --cert/--key fails with a nonzero status" {
    run "$BASHTTPD_BIN" --tls
    [[ $status -ne 0 ]]
    [[ $output == *'--tls requires'* || $output == *'cert'* ]]
}

@test "unknown option fails with a nonzero status" {
    run "$BASHTTPD_BIN" --not-a-real-option
    [[ $status -ne 0 ]]
}

@test "unreadable config file fails with a nonzero status" {
    run "$BASHTTPD_BIN" --config "$BATS_TEST_TMPDIR/does-not-exist.conf" -p 0
    [[ $status -ne 0 ]]
}

@test "bad docroot fails with a nonzero status" {
    run "$BASHTTPD_BIN" -d "$BATS_TEST_TMPDIR/no-such-dir" -p 0
    [[ $status -ne 0 ]]
}

@test "invalid port fails with a nonzero status" {
    run "$BASHTTPD_BIN" -p notaport -d "$BATS_TEST_TMPDIR"
    [[ $status -ne 0 ]]
}

@test "root compatibility shim --help works" {
    run "$REPO_ROOT/bashttpd" --help
    [[ $status -eq 0 ]]
    [[ $output == *'serve'* ]]
    [[ $output == *'handle'* ]]
}

@test "root compatibility shim --version works" {
    run "$REPO_ROOT/bashttpd" --version
    [[ $status -eq 0 ]]
    [[ $output =~ ^bashttpd\ [0-9]+\.[0-9]+ ]]
}
