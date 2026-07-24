#!/usr/bin/env bats
# Unit tests for lib/bashttpd/router.sh -- the config DSL dispatch functions.

setup() {
    load '../test_helper'
    source_lib core router
    REQUEST_HANDLED=''
    CALLS=()
}

# A recording handler: appends the arguments it was called with, joined by
# a separator, to the CALLS array so tests can assert on exactly what the
# router passed through.
record() {
    CALLS+=("$*")
}

@test "on_uri_match: dispatches when the regex matches and sets REQUEST_HANDLED" {
    REQUEST_PATH='/hello/world'
    on_uri_match '^/hello/(.*)$' record
    [[ ${#CALLS[@]} -eq 1 ]]
    [[ -n $REQUEST_HANDLED ]]
}

@test "on_uri_match: does not dispatch when the regex does not match" {
    REQUEST_PATH='/other'
    on_uri_match '^/hello/(.*)$' record
    [[ ${#CALLS[@]} -eq 0 ]]
    [[ -z $REQUEST_HANDLED ]]
}

@test "on_uri_match: BASH_REMATCH capture groups are appended after the given args" {
    REQUEST_PATH='/say_hello_to/Ada'
    on_uri_match '^/say_hello_to/(.*)$' record fixed-arg
    [[ ${#CALLS[@]} -eq 1 ]]
    # record receives: fixed-arg, ${BASH_REMATCH[@]} => fixed-arg /say_hello_to/Ada Ada
    [[ "${CALLS[0]}" == 'fixed-arg /say_hello_to/Ada Ada' ]]
}

@test "on_uri_match: multiple capture groups all appear in order" {
    REQUEST_PATH='/files/docs/report.pdf'
    on_uri_match '^/files/([^/]+)/([^/]+)$' record
    [[ "${CALLS[0]}" == '/files/docs/report.pdf docs report.pdf' ]]
}

@test "on_uri_match: first match wins -- a second matching rule is skipped" {
    REQUEST_PATH='/hello'
    on_uri_match '^/hello$' record first
    on_uri_match '^/hello$' record second
    [[ ${#CALLS[@]} -eq 1 ]]
    [[ "${CALLS[0]}" == 'first /hello' ]]
}

@test "on_uri_match: once handled, later on_method_match is also skipped" {
    REQUEST_PATH='/hello'
    REQUEST_METHOD='GET'
    on_uri_match '^/hello$' record uri-rule
    on_method_match GET record method-rule
    [[ ${#CALLS[@]} -eq 1 ]]
    [[ "${CALLS[0]}" == 'uri-rule /hello' ]]
}

@test "on_method_match: dispatches on a case-insensitive method match" {
    REQUEST_PATH='/x'
    REQUEST_METHOD='get'
    on_method_match GET record
    [[ ${#CALLS[@]} -eq 1 ]]
    [[ "${CALLS[0]}" == '/x' ]]
}

@test "on_method_match: does not dispatch on a different method" {
    REQUEST_PATH='/x'
    REQUEST_METHOD='POST'
    on_method_match GET record
    [[ ${#CALLS[@]} -eq 0 ]]
}

@test "on_method_match: first match wins across two method rules" {
    REQUEST_PATH='/x'
    REQUEST_METHOD='POST'
    on_method_match GET record get-rule
    on_method_match POST record post-rule
    [[ ${#CALLS[@]} -eq 1 ]]
    [[ "${CALLS[0]}" == 'post-rule /x' ]]
}

@test "unconditionally: always dispatches and appends REQUEST_PATH as the final arg" {
    REQUEST_PATH='/anything'
    unconditionally record fixed
    [[ ${#CALLS[@]} -eq 1 ]]
    [[ "${CALLS[0]}" == 'fixed /anything' ]]
    [[ -n $REQUEST_HANDLED ]]
}

@test "unconditionally: is skipped once REQUEST_HANDLED is already set" {
    REQUEST_PATH='/anything'
    REQUEST_HANDLED=1
    unconditionally record fixed
    [[ ${#CALLS[@]} -eq 0 ]]
}

@test "unconditionally: acts as a catch-all after non-matching on_uri_match rules" {
    REQUEST_PATH='/nope'
    on_uri_match '^/only-this$' record specific
    unconditionally record catchall
    [[ ${#CALLS[@]} -eq 1 ]]
    [[ "${CALLS[0]}" == 'catchall /nope' ]]
}
