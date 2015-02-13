#!/usr/bin/env bash
#
# A simple, configurable HTTP server written in bash.
#
# See LICENSE for licensing information.
#
# Original author: Avleen Vig, 2012
# Reworked by:     Josh Cartwright, 2012

warn() { echo "WARNING: $@" >&2; }

[ -r bashttpd.conf ] || {
   cat >bashttpd.conf <<'EOF'
#
# bashttpd.conf - configuration for bashttpd
#
# The behavior of bashttpd is dictated by the evaluation
# of rules specified in this configuration file.  Each rule
# is evaluated until one is matched.  If no rule is matched,
# bashttpd will serve a 500 Internal Server Error.
#
# The format of the rules are:
#    on_uri_match REGEX command [args]
#    unconditionally command [args]
#
# on_uri_match:
#   On an incoming request, the URI is checked against the specified
#   (bash-supported extended) regular expression, and if encounters a match the
#   specified command is executed with the specified arguments.
#
#   For additional flexibility, on_uri_match will also pass the results of the
#   regular expression match, ${BASH_REMATCH[@]} as additional arguments to the
#   command.
#
# unconditionally:
#   Always serve via the specified command.  Useful for catchall rules.
#
# The following commands are available for use:
#
#   serve_file FILE
#     Statically serves a single file.
#
#   serve_dir_with_tree DIRECTORY
#     Statically serves the specified directory using 'tree'.  It must be
#     installed and in the PATH.
#
#   serve_dir_with_ls DIRECTORY
#     Statically serves the specified directory using 'ls -al'.
#
#   serve_dir  DIRECTORY
#     Statically serves a single directory listing.  Will use 'tree' if it is
#     installed and in the PATH, otherwise, 'ls -al'
#
#   serve_dir_or_file_from DIRECTORY
#     Serves either a directory listing (using serve_dir) or a file (using
#     serve_file).  Constructs local path by appending the specified root
#     directory, and the URI portion of the client request.
#
#   serve_static_string STRING
#     Serves the specified static string with Content-Type text/plain.
#
# Examples of rules:
#
# on_uri_match '^/issue$' serve_file "/etc/issue"
#
#   When a client's requested URI matches the string '/issue', serve them the
#   contents of /etc/issue
#
# on_uri_match 'root' serve_dir /
#
#   When a client's requested URI has the word 'root' in it, serve up
#   a directory listing of /
#
# DOCROOT=/var/www/html
# on_uri_match '/(.*)' serve_dir_or_file_from "$DOCROOT"
#   When any URI request is made, attempt to serve a directory listing
#   or file content based on the request URI, by mapping URI's to local
#   paths relative to the specified "$DOCROOT"
#

unconditionally serve_static_string 'Hello, world!  You can configure bashttpd by modifying bashttpd.conf.'

# More about commands:
#
# It is possible to somewhat easily write your own commands.  An example
# may help.  The following example will serve "Hello, $x!" whenever
# a client sends a request with the URI /say_hello_to/$x:
#
# serve_hello() {
#    add_response_header "Content-Type" "text/plain"
#    send_response_ok_exit <<< "Hello, $2!"
# }
# on_uri_match '^/say_hello_to/(.*)$' serve_hello
#
# Like mentioned before, the contents of ${BASH_REMATCH[@]} are passed
# to your command, so its possible to use regular expression groups
# to pull out info.
#
# With this example, when the requested URI is /say_hello_to/Josh, serve_hello
# is invoked with the arguments '/say_hello_to/Josh' 'Josh',
# (${BASH_REMATCH[0]} is always the full match)
EOF
   warn "Created bashttpd.conf using defaults.  Please review it/configure before running bashttpd again."
   exit 1
}

recv() { echo "< $@" >&2; }
send() { echo "> $@" >&2;
         printf '%s\r\n' "$*"; }

[[ $UID = 0 ]] && warn "It is not recommended to run bashttpd as root."

DATE=$(date +"%a, %d %b %Y %H:%M:%S %Z")
declare -a RESPONSE_HEADERS=(
      "Date: $DATE"
   "Expires: $DATE"
    "Server: Slash Bin Slash Bash"
)

add_response_header() {
   RESPONSE_HEADERS+=("$1: $2")
}

declare -a HTTP_RESPONSE=(
   [200]="OK"
   [400]="Bad Request"
   [403]="Forbidden"
   [404]="Not Found"
   [405]="Method Not Allowed"
   [500]="Internal Server Error"
)

send_response() {
   local code=$1
   send "HTTP/1.0 $1 ${HTTP_RESPONSE[$1]}"
   for i in "${RESPONSE_HEADERS[@]}"; do
      send "$i"
   done
   send
   while read -r line; do
      send "$line"
   done
}

send_response_ok_exit() { send_response 200; exit 0; }

fail_with() {
   send_response "$1" <<< "$1 ${HTTP_RESPONSE[$1]}"
   exit 1
}

serve_file() {
   local file=$1

   CONTENT_TYPE=
   case "$file" in
     *\.css)
       CONTENT_TYPE="text/css"
       ;;
     *\.js)
       CONTENT_TYPE="text/javascript"
       ;;
     *)
       read -r CONTENT_TYPE   < <(file -b --mime-type "$file")
       ;;
   esac

   add_response_header "Content-Type"   "$CONTENT_TYPE";

   read -r CONTENT_LENGTH < <(stat -c'%s' "$file")         && \
      add_response_header "Content-Length" "$CONTENT_LENGTH"

   send_response_ok_exit < "$file"
}

serve_dir_with_tree()
{
   local dir="$1" tree_vers tree_opts basehref x

   add_response_header "Content-Type" "text/html"

   # The --du option was added in 1.6.0.
   read x tree_vers x < <(tree --version)
   [[ $tree_vers == v1.6* ]] && tree_opts="--du"

   send_response_ok_exit < \
      <(tree -H "$2" -L 1 "$tree_opts" -D "$dir")
}

serve_dir_with_ls()
{
   local dir=$1

   add_response_header "Content-Type" "text/plain"

   send_response_ok_exit < \
      <(ls -la "$dir")
}

serve_dir() {
   local dir=$1

   # If `tree` is installed, use that for pretty output.
   which tree &>/dev/null && \
      serve_dir_with_tree "$@"

   serve_dir_with_ls "$@"

   fail_with 500
}

serve_dir_or_file_from() {
   local URL_PATH=$1/$3
   shift

   # sanitize URL_PATH
   URL_PATH=${URL_PATH//[^a-zA-Z0-9_~\-\.\/]/}
   [[ $URL_PATH == *..* ]] && fail_with 400

   # Serve index file if exists in requested directory
   [[ -d $URL_PATH && -f $URL_PATH/index.html && -r $URL_PATH/index.html ]] && \
      URL_PATH="$URL_PATH/index.html"

   if [[ -f $URL_PATH ]]; then
      [[ -r $URL_PATH ]] && \
         serve_file "$URL_PATH" "$@" || fail_with 403
   elif [[ -d $URL_PATH ]]; then
      [[ -x $URL_PATH ]] && \
         serve_dir  "$URL_PATH" "$@" || fail_with 403
   fi

   fail_with 404
}

serve_static_string() {
   add_response_header "Content-Type" "text/plain"
   send_response_ok_exit <<< "$1"
}

on_uri_match() {
   local regex=$1
   shift

   [[ $REQUEST_URI =~ $regex ]] && \
      "$@" "${BASH_REMATCH[@]}"
}

unconditionally() {
   "$@" "$REQUEST_URI"
}

# Request-Line HTTP RFC 2616 $5.1
read -r line || fail_with 400

# strip trailing CR if it exists
line=${line%%$'\r'}
recv "$line"

read -r REQUEST_METHOD REQUEST_URI REQUEST_HTTP_VERSION <<<"$line"

[ -n "$REQUEST_METHOD" ] && \
[ -n "$REQUEST_URI" ] && \
[ -n "$REQUEST_HTTP_VERSION" ] \
   || fail_with 400

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

source "${BASH_SOURCE[0]%/*}"/bashttpd.conf
fail_with 500
