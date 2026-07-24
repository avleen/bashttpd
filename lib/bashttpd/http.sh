# shellcheck shell=bash
# shellcheck disable=SC2034
# (This module communicates with server.sh and handlers via well-known
# globals -- PARSE_STATUS, REQUEST_*, HEADER_*, RESPONSE_* -- whose
# cross-file consumers are invisible to static analysis.)
# lib/bashttpd/http.sh
#
# Pure HTTP protocol helpers: status text, URL decoding, path canonicalization,
# request-line / header parsing, and response building. Nothing here touches
# the network directly except res_send, which writes to stdout (the socket).
# All functions are self-contained so this file can be sourced standalone and
# unit-tested.

# http_status_text CODE -> reason phrase on stdout.
http_status_text() {
    case $1 in
        200) printf 'OK' ;;
        204) printf 'No Content' ;;
        301) printf 'Moved Permanently' ;;
        302) printf 'Found' ;;
        304) printf 'Not Modified' ;;
        400) printf 'Bad Request' ;;
        403) printf 'Forbidden' ;;
        404) printf 'Not Found' ;;
        405) printf 'Method Not Allowed' ;;
        408) printf 'Request Timeout' ;;
        411) printf 'Length Required' ;;
        413) printf 'Payload Too Large' ;;
        414) printf 'URI Too Long' ;;
        431) printf 'Request Header Fields Too Large' ;;
        500) printf 'Internal Server Error' ;;
        501) printf 'Not Implemented' ;;
        503) printf 'Service Unavailable' ;;
        505) printf 'HTTP Version Not Supported' ;;
        *)   printf 'Unknown' ;;
    esac
}

# http_date -> current time as an RFC 7231 IMF-fixdate (always GMT/UTC).
http_date() {
    LC_ALL=C TZ=UTC date '+%a, %d %b %Y %H:%M:%S GMT'
}

# http_urldecode STRING -> percent-decoded string on stdout.
# '+' is NOT treated as space (that only applies to query components, not the
# path). Invalid percent escapes are passed through literally.
http_urldecode() {
    local str=$1 out='' i=0 c h n
    n=${#str}
    while (( i < n )); do
        c=${str:i:1}
        if [[ $c == '%' && $((i + 2)) -lt $n ]]; then
            h=${str:i+1:2}
            if [[ $h == [0-9A-Fa-f][0-9A-Fa-f] ]]; then
                printf -v c '%b' "\\x$h"
                out+=$c
                (( i += 3 ))
                continue
            fi
        fi
        out+=$c
        (( i++ ))
    done
    printf '%s' "$out"
}

# http_canonicalize_path TARGET -> canonical, decoded path on stdout.
# Strips the query string, percent-decodes, normalizes '.'/'//', resolves '..'
# lexically, and rejects any attempt to escape the root (returns 1). A trailing
# slash on the request is preserved so callers can implement directory
# redirects. Encoded NUL and newline are rejected.
http_canonicalize_path() {
    local target=$1 path decoded
    path=${target%%\?*}

    # Reject encoded control characters that could confuse path handling.
    [[ $path == *%00* ]] && return 1

    decoded=$(http_urldecode "$path")

    # A literal NUL cannot survive in a bash variable; a newline (%0a) would
    # break line-oriented parsing. Reject the latter explicitly.
    [[ $decoded == *$'\n'* || $decoded == *$'\r'* ]] && return 1

    # Ensure an absolute path to begin with.
    [[ $decoded == /* ]] || decoded="/$decoded"

    local trailing=''
    [[ $decoded == */ && $decoded != '/' ]] && trailing='/'

    local -a out=() segs=()
    local seg IFS='/'
    read -ra segs <<< "$decoded"

    for seg in "${segs[@]}"; do
        case $seg in
            ''|.)  continue ;;
            ..)
                (( ${#out[@]} == 0 )) && return 1   # escape above root
                unset 'out[-1]'
                ;;
            *) out+=("$seg") ;;
        esac
    done

    local result
    if (( ${#out[@]} == 0 )); then
        result='/'
    else
        result="/${out[*]}"     # IFS=/ joins the segments
        [[ -n $trailing ]] && result+='/'
    fi

    printf '%s' "$result"
}

# http_parse_request_line LINE
# On success sets globals REQUEST_METHOD, REQUEST_URI (raw target), and
# REQUEST_HTTP_VERSION, and returns 0. On failure sets PARSE_STATUS to the
# HTTP status the caller should return (400 malformed, 505 bad version) and
# returns 1.
http_parse_request_line() {
    local line=$1 method target version
    read -r method target version <<< "$line"

    if [[ -z $method || -z $target ]]; then
        PARSE_STATUS=400
        return 1
    fi

    # Method must be a valid token (uppercase letters cover every method we
    # care about; be strict rather than permissive).
    if [[ ! $method =~ ^[A-Za-z]+$ ]]; then
        PARSE_STATUS=400
        return 1
    fi

    # No version token at all: HTTP/0.9-style request, which we don't support.
    if [[ -z $version ]]; then
        PARSE_STATUS=505
        return 1
    fi

    if [[ $version != 'HTTP/1.0' && $version != 'HTTP/1.1' ]]; then
        PARSE_STATUS=505
        return 1
    fi

    REQUEST_METHOD=$method
    REQUEST_URI=$target
    REQUEST_HTTP_VERSION=$version
    return 0
}

# http_parse_header_line LINE
# On success sets HEADER_KEY (lowercased) and HEADER_VALUE (OWS-trimmed) and
# returns 0. Returns 1 for a malformed header line.
http_parse_header_line() {
    local line=$1 key val
    [[ $line == *:* ]] || return 1

    key=${line%%:*}
    val=${line#*:}

    # Field name must be non-empty and contain no whitespace (obs-fold and
    # bogus continuation lines are rejected).
    [[ -z $key ]] && return 1
    [[ $key == *[[:space:]]* ]] && return 1

    # Trim leading and trailing optional whitespace from the value.
    val=${val#"${val%%[![:space:]]*}"}
    val=${val%"${val##*[![:space:]]}"}

    HEADER_KEY=${key,,}
    HEADER_VALUE=$val
    return 0
}

# ---------------------------------------------------------------------------
# Response building. res_init resets per-request state; res_add_header queues a
# header; res_send emits the full response to stdout.
#
# The connection disposition (RESPONSE_CONNECTION) and request method
# (REQUEST_METHOD) are read as globals: HEAD suppresses the body but keeps
# identical headers.
# ---------------------------------------------------------------------------

res_init() {
    RES_HEADERS=()
    RESPONSE_STATUS=0
    RESPONSE_BYTES=0
    REQUEST_HANDLED=''
}

res_add_header() {
    RES_HEADERS+=("$1: $2")
}

# res_byte_length VAR_NAME STRING -- store the byte length of STRING in VAR_NAME.
# Uses the C locale so multibyte characters are counted as bytes, matching what
# actually goes on the wire.
res_byte_length() {
    local LC_ALL=C
    printf -v "$1" '%s' "${#2}"
}

# res_send CODE [-s STRING | -f FILE]
# Writes the status line, queued headers, the mandatory Content-Length, the
# standard Date/Server/Connection headers, and (unless HEAD) the body.
res_send() {
    local code=$1
    shift
    local mode='empty' src='' len=0

    case ${1:-} in
        -s) mode='string'; src=$2 ;;
        -f) mode='file';   src=$2 ;;
    esac

    if [[ $mode == 'string' ]]; then
        res_byte_length len "$src"
    elif [[ $mode == 'file' ]]; then
        len=$(stat -c '%s' -- "$src" 2>/dev/null) || len=0
    fi

    # Status line + queued headers.
    printf 'HTTP/1.1 %s %s\r\n' "$code" "$(http_status_text "$code")"
    local h
    for h in "${RES_HEADERS[@]}"; do
        printf '%s\r\n' "$h"
    done

    # Standard headers always present.
    printf 'Content-Length: %s\r\n' "$len"
    printf 'Date: %s\r\n' "$(http_date)"
    printf 'Server: %s\r\n' "$SERVER_TOKEN"
    printf 'Connection: %s\r\n' "${RESPONSE_CONNECTION:-close}"
    printf '\r\n'

    # Body (skipped for HEAD, which must otherwise be identical to GET).
    if [[ ${REQUEST_METHOD:-GET} != 'HEAD' ]]; then
        case $mode in
            string) printf '%s' "$src" ;;
            file)   cat -- "$src" ;;
        esac
    fi

    RESPONSE_STATUS=$code
    RESPONSE_BYTES=$len
    REQUEST_HANDLED=1
    return 0
}

# res_send_error CODE -- emit a small HTML error page with the given status.
# Any headers already queued (e.g. Allow for a 405) are preserved.
res_send_error() {
    local code=$1 text body
    text=$(http_status_text "$code")
    printf -v body '<!DOCTYPE html>
<html>
<head><title>%s %s</title></head>
<body>
<h1>%s %s</h1>
<hr>
<p>%s</p>
</body>
</html>
' "$code" "$text" "$code" "$text" "$SERVER_TOKEN"

    res_add_header 'Content-Type' 'text/html; charset=utf-8'
    res_send "$code" -s "$body"
}
