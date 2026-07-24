# shellcheck shell=bash
# shellcheck disable=SC2034
# (Sets per-request globals -- HTTP_HOST, REQUEST_PATH, QUERY_STRING,
# REQUEST_BODY -- whose consumers are handlers and user config files
# invisible to static analysis.)
# lib/bashttpd/server.sh
#
# The per-connection request loop. stdin/stdout are one TCP (or TLS) connection.
# Handles request framing, keep-alive, header/body limits, method dispatch, and
# access logging. Each request resets response state, evaluates the user config
# (or a built-in default route), and continues the loop -- handlers never exit
# the process.

# Tunables (overridable via environment).
: "${BASHTTPD_TIMEOUT:=5}"            # idle read timeout, seconds (keep-alive)
: "${BASHTTPD_MAX_REQUESTS:=100}"     # max requests per connection
: "${BASHTTPD_MAX_BODY:=1048576}"     # max request body bytes (1 MiB)
: "${BASHTTPD_MAX_LINE:=8190}"        # max request-line / header-line length
: "${BASHTTPD_MAX_HEADERS:=100}"      # max header count

# server_client_addr -> best-effort client address from the listener's env.
server_client_addr() {
    printf '%s' "${SOCAT_PEERADDR:-${NCAT_REMOTE_ADDR:--}}"
}

# server_log_access -- one access-log line per request, to stderr.
server_log_access() {
    local client
    client=$(server_client_addr)
    printf '%s - "%s %s %s" %s %s\n' \
        "$client" \
        "${REQUEST_METHOD:--}" \
        "${REQUEST_URI:--}" \
        "${REQUEST_HTTP_VERSION:--}" \
        "${RESPONSE_STATUS:-000}" \
        "${RESPONSE_BYTES:-0}" >&2
}

# server_dispatch -- route the request. Prefer the user config (sourced fresh
# each request, like the legacy design). With no config, fall back to serving a
# docroot (GET/HEAD only) or a hello-world string.
server_dispatch() {
    if [[ -n ${BASHTTPD_CONFIG:-} && -r ${BASHTTPD_CONFIG:-} ]]; then
        # shellcheck source=/dev/null  # user-supplied config, unknowable here
        source "$BASHTTPD_CONFIG"
        return
    fi

    # Built-in default only serves safe, read-only methods.
    [[ $REQUEST_METHOD == 'GET' || $REQUEST_METHOD == 'HEAD' ]] || return

    if [[ -n ${BASHTTPD_DOCROOT:-} ]]; then
        serve_dir_or_file_from "$BASHTTPD_DOCROOT"
    else
        serve_static_string 'Hello, world! bashttpd is running. Configure it with a bashttpd.conf or -d DOCROOT.'
    fi
}

# server_send_simple_error CODE -- reset state, force close, send error page.
# Used for protocol-level failures where continuing the connection is unsafe.
server_send_simple_error() {
    RESPONSE_CONNECTION='close'
    res_init
    res_send_error "$1"
    server_log_access
}

# server_handle_connection -- the main loop. Returns when the connection should
# close (timeout, EOF, error, Connection: close, or request cap reached).
server_handle_connection() {
    local req_count=0 line

    while (( req_count < BASHTTPD_MAX_REQUESTS )); do
        # --- Request line (with idle keep-alive timeout) --------------------
        if ! IFS= read -r -t "$BASHTTPD_TIMEOUT" line; then
            return 0    # timeout or client closed the connection
        fi
        line=${line%$'\r'}

        # Tolerate a single leading blank line (some clients emit CRLF before
        # a request); don't count it against the request cap.
        if [[ -z $line ]]; then
            continue
        fi

        (( req_count++ ))

        if (( ${#line} > BASHTTPD_MAX_LINE )); then
            server_send_simple_error 414
            return 0
        fi

        # Reset per-request globals used by handlers/logging.
        REQUEST_METHOD='' REQUEST_URI='' REQUEST_HTTP_VERSION=''
        REQUEST_PATH='' QUERY_STRING='' HTTP_HOST='' REQUEST_BODY=''

        if ! http_parse_request_line "$line"; then
            server_send_simple_error "${PARSE_STATUS:-400}"
            return 0
        fi

        # --- Headers --------------------------------------------------------
        local -A HEADERS=()
        local header_count=0 bad_headers=0
        while IFS= read -r -t "$BASHTTPD_TIMEOUT" line; do
            line=${line%$'\r'}
            [[ -z $line ]] && break

            if (( ${#line} > BASHTTPD_MAX_LINE )); then
                server_send_simple_error 431
                return 0
            fi

            (( header_count++ ))
            if (( header_count > BASHTTPD_MAX_HEADERS )); then
                server_send_simple_error 431
                return 0
            fi

            if http_parse_header_line "$line"; then
                HEADERS[$HEADER_KEY]=$HEADER_VALUE
            else
                bad_headers=1
            fi
        done || return 0    # EOF/timeout mid-headers: drop the connection

        if (( bad_headers )); then
            server_send_simple_error 400
            return 0
        fi

        HTTP_HOST=${HEADERS[host]:-}

        # HTTP/1.1 requires a Host header.
        if [[ $REQUEST_HTTP_VERSION == 'HTTP/1.1' && -z ${HEADERS[host]+set} ]]; then
            server_send_simple_error 400
            return 0
        fi

        # --- Keep-alive decision --------------------------------------------
        local conn=${HEADERS[connection]:-}
        conn=${conn,,}
        local keepalive
        if [[ $REQUEST_HTTP_VERSION == 'HTTP/1.1' ]]; then
            keepalive=1
            [[ $conn == *close* ]] && keepalive=0
        else
            keepalive=0
            [[ $conn == *keep-alive* ]] && keepalive=1
        fi

        # --- Request body ---------------------------------------------------
        if [[ -n ${HEADERS[transfer-encoding]+set} ]]; then
            # We do not implement chunked/other transfer codings.
            RESPONSE_CONNECTION='close'
            res_init
            res_send_error 501
            server_log_access
            return 0
        fi

        local clen=${HEADERS[content-length]:-0}
        if [[ -n $clen && ! $clen =~ ^[0-9]+$ ]]; then
            server_send_simple_error 400
            return 0
        fi
        [[ -z $clen ]] && clen=0

        if (( clen > BASHTTPD_MAX_BODY )); then
            RESPONSE_CONNECTION='close'
            res_init
            res_send_error 413
            server_log_access
            return 0
        fi

        if (( clen > 0 )); then
            # Drain exactly clen bytes so keep-alive framing survives, even if
            # the body is ignored by the handler.
            IFS= read -r -N "$clen" -t "$BASHTTPD_TIMEOUT" REQUEST_BODY
        fi

        # --- Compute path / query, set the connection disposition -----------
        if ! REQUEST_PATH=$(http_canonicalize_path "$REQUEST_URI"); then
            server_send_simple_error 400
            return 0
        fi
        QUERY_STRING=''
        [[ $REQUEST_URI == *\?* ]] && QUERY_STRING=${REQUEST_URI#*\?}

        if (( keepalive )) && (( req_count < BASHTTPD_MAX_REQUESTS )); then
            RESPONSE_CONNECTION='keep-alive'
        else
            RESPONSE_CONNECTION='close'
        fi

        res_init

        # --- Method handling ------------------------------------------------
        case $REQUEST_METHOD in
            OPTIONS)
                # OPTIONS * or OPTIONS /path -> 204 with Allow.
                res_add_header 'Allow' 'GET, HEAD, OPTIONS'
                res_send 204
                ;;
            GET|HEAD|POST|PUT|DELETE|PATCH)
                server_dispatch
                if [[ -z $REQUEST_HANDLED ]]; then
                    if [[ $REQUEST_METHOD == 'GET' || $REQUEST_METHOD == 'HEAD' ]]; then
                        res_send_error 404
                    else
                        res_add_header 'Allow' 'GET, HEAD, OPTIONS'
                        res_send_error 405
                    fi
                fi
                ;;
            *)
                res_send_error 501
                ;;
        esac

        server_log_access

        # --- Loop or close --------------------------------------------------
        if [[ $RESPONSE_CONNECTION != 'keep-alive' ]]; then
            return 0
        fi
    done

    return 0
}
