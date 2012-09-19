#!/usr/bin/env bash
# A simple HTTP server written in bash.
#
# Bashttpd will serve text files, and most binaries as Base64 encoded.
#
# Avleen Vig, 2012-09-13

if [ "$(id -u)" = "0" ]; then
   echo "Hold on, tiger! Don't run this as root, k?" 1>&2
   exit 1
fi

recv() { echo "< $@" >&2; }
send() { echo "> $@" >&2;
         printf '%s\r\n' "$*"; }

warn() { echo "WARNING: $@" >&2; }

[ -r bashttpd.conf ] || {
   warn "bashttpd.conf does not exist.  Creating using defaults."
   cat >bashttpd.conf <<-EOF
	# bashttpd.conf - configuration for bashttpd
	#
	# DOCROOT is the root directory used for serving files
	# It should not contain a trailing slash
	DOCROOT=/var/www/html
	EOF
}

source bashttpd.conf

DATE=$( date +"%a, %d %b %Y %H:%M:%S %Z" )
declare -a RESPONSE_HEADERS=(
      "Date: $DATE"
   "Expires: $DATE"
    "Server: Slash Bin Slash Bash"
)

send_response_headers() {
   for i in "${RESPONSE_HEADERS[@]}"; do
      send "$i"
   done
}

declare -a HTTP_ERROR=(
    [400]="Bad Request"
    [403]="Forbidden"
    [404]="Not Found"
    [405]="Method Not Allowed"
    [500]="Internal Server Error"
)

fail_with() {
    send "HTTP/1.0 $1 ${HTTP_ERROR[$1]}"
    send_response_headers
    send
    send "$1 ${HTTP_ERROR[$1]}"
    exit 1
}

function filter_url() {
    URL_PATH=$1
    URL_PATH=${URL_PATH//[^a-zA-Z0-9_~\-\.\/]/}
}

function get_content_type() {
    URL_PATH=$1
    CONTENT_TYPE=$( file -b --mime-type ${URL_PATH} )
}

function get_content_body() {
    URL_PATH=$1
    CONTENT_TYPE=$2
    if [[ ${CONTENT_TYPE} =~ "^text" ]]; then
        CONTENT_BODY="$( cat ${URL_PATH} )"
    else
        CONTENT_BODY="$( cat ${URL_PATH} )"
    fi
}

function get_content_length() {
    CONTENT_BODY="$1"
    CONTENT_LENGTH=$( echo ${CONTENT_BODY} | wc -c )
}

if ! [ -d "$DOCROOT" ]; then
    echo >&2 "Error: \$DOCROOT '$DOCROOT' does not exist."
    fail_with 500
fi

# Request-Line HTTP RFC 2616 $5.1
read -r line || fail_bad_request

# strip trailing CR if it exists
line=${line%%$'\r'}
recv "$line"

read -r REQUEST_METHOD REQUEST_URI REQUEST_HTTP_VERSION <<<"$line"

[ -n "$REQUEST_METHOD" ] && \
[ -n "$REQUEST_URI" ] && \
[ -n "$REQUEST_HTTP_VERSION" ] \
   || fail_bad_request

# Only GET is supported at this time
[ "$REQUEST_METHOD" = "GET" ] || fail_with 405

declare -a REQUEST_HEADERS

while read -r line; do
    line=${line%%$'\r'}
    recv "$line"

    # If we've reached the end of the headers, break.
    [ -z "$line" ] && break

    REQUEST_HEADERS+=("$line")
done

URL_PATH="$DOCROOT/$REQUEST_URI"
filter_url "$URL_PATH"

[[ "$URL_PATH" == *..* ]] && fail_with 400
[ -z "$URL_PATH" ]        && fail_with 400

# Serve index file if exists in requested directory
if [ -d ${URL_PATH} -a -f ${URL_PATH}/index.html -a -r ${URL_PATH}/index.html ]; then
    URL_PATH=${URL_PATH}/index.html
fi

# Check the URL requested.
# If it's a text file, serve it directly.
# If it's a binary file, base64 encode it first.
# If it's a directory, perform an "ls -la".
# Otherwise, return a 404.
if [ -f ${URL_PATH} -a -r ${URL_PATH} ]; then
    # Return 200 and file contents
    get_content_type "${URL_PATH}"
    get_content_body "${URL_PATH}" "${CONTENT_TYPE}"
    get_content_length "${CONTENT_BODY}"
    HTTP_RESPONSE="HTTP/1.0 200 OK"
elif [ -f ${URL_PATH} -a ! -r ${URL_PATH} ]; then
    # Return 403 for unreadable files
    fail_with 403
elif [ -d ${URL_PATH} ]; then
    # Return 200 for directory listings.
    # If `tree` is installed, use that for pretty output.
    if which tree >/dev/null; then
        CONTENT_TYPE="text/html"
        # The --du option was added in 1.6.0.
        if [[ $(tree --version | cut -f2 -d' ') == v1.5* ]]; then
            tree_opts=
        else
            tree_opts="--du"
        fi
        # The baseHREF should be path without DOCROOT or trailing slashes.
        basehref="${URL_PATH#$DOCROOT}"
        basehref="${basehref%%/}"
        CONTENT_BODY="$(tree -H "$basehref" -L 1 $tree_opts -D ${URL_PATH})"
    else
        CONTENT_TYPE="text/plain"
        CONTENT_BODY=$( ls -la ${URL_PATH} )
    fi
    CONTENT_LENGTH=$(echo "${CONTENT_BODY}" | wc -c)
    HTTP_RESPONSE="HTTP/1.0 200 OK"
elif [ -d ${URL_PATH} -a ! -x ${URL_PATH} ]; then
    # Return 403 for non-listable directories
    fail_with 403
else
    fail_with 404
fi

send "${HTTP_RESPONSE}"
send_response_headers
#echo "Content-length: ${CONTENT_LENGTH}"
send "Content-type: ${CONTENT_TYPE}"
send
while read line; do
   send "$line"
done <<< "${CONTENT_BODY}"
exit
