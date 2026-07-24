#!/usr/bin/env bats
# Integration tests for TLS support: generate a cert with scripts/gen-cert.sh,
# start the server with --tls, and confirm HTTPS works while plain HTTP to the
# same port does not.

setup() {
    load '../test_helper'

    CERT="$BATS_TEST_TMPDIR/server.crt"
    KEY="$BATS_TEST_TMPDIR/server.key"

    run "$REPO_ROOT/scripts/gen-cert.sh" "$CERT" "$KEY"
    [[ $status -eq 0 ]]
    [[ -f $CERT ]]
    [[ -f $KEY ]]

    DOCROOT="$BATS_TEST_TMPDIR/docroot"
    mkdir -p "$DOCROOT"
    printf 'tls index\n' > "$DOCROOT/index.html"

    start_server --tls --cert "$CERT" --key "$KEY" -d "$DOCROOT"
}

teardown() {
    stop_server
}

@test "gen-cert.sh writes a private key with restrictive permissions" {
    local perms
    perms=$(stat -c '%a' "$KEY")
    [[ $perms == 600 ]]
}

@test "HTTPS request to the TLS listener succeeds" {
    run curl -sk -o /dev/null -w '%{http_code}' "$SERVER_BASE/"
    [[ $status -eq 0 ]]
    [[ $output == '200' ]]
}

@test "HTTPS response body is served correctly over TLS" {
    run curl -sk "$SERVER_BASE/"
    [[ $status -eq 0 ]]
    [[ $output == 'tls index' ]]
}

@test "a plain HTTP request to the TLS port does not get a valid HTTP response" {
    local plain_url="http://127.0.0.1:$SERVER_PORT/"
    run curl -s --max-time 3 -o /dev/null -w '%{http_code}' "$plain_url"
    # Either curl fails outright (connection reset/handshake garbage) or the
    # response is not a normal 200 -- either way, it must not succeed as if
    # it were a plain HTTP request.
    [[ $status -ne 0 || $output != '200' ]]
}
