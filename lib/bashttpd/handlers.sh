# shellcheck shell=bash
# lib/bashttpd/handlers.sh
#
# Content handlers invoked by the router DSL: static files, directory listings
# (rendered in pure bash, no `tree` dependency), docroot serving with traversal
# protection, redirects, and small compatibility shims for the legacy config
# vocabulary (add_response_header, fail_with, send_response_ok_exit).

# html_escape STRING -> HTML-escaped string on stdout. Pure parameter
# expansion, no external processes.
html_escape() {
    local s=$1
    s=${s//&/&amp;}
    s=${s//</&lt;}
    s=${s//>/&gt;}
    s=${s//\"/&quot;}
    printf '%s' "$s"
}

# serve_file FILE -- send a single file with a guessed Content-Type.
serve_file() {
    local file=$1
    if [[ ! -f $file ]]; then
        res_send_error 404
        return
    fi
    if [[ ! -r $file ]]; then
        res_send_error 403
        return
    fi
    res_add_header 'Content-Type' "$(mime_type_for "$file")"
    res_add_header 'Last-Modified' "$(LC_ALL=C TZ=UTC date -r "$file" '+%a, %d %b %Y %H:%M:%S GMT' 2>/dev/null)"
    res_send 200 -f "$file"
}

# serve_dir DIRECTORY -- render an HTML directory listing in pure bash.
serve_dir() {
    local dir=$1
    local disp=${REQUEST_PATH:-/}
    local esc_disp entry name href rows='' body

    esc_disp=$(html_escape "$disp")

    # Parent link (except at the docroot's displayed root).
    if [[ $disp != '/' ]]; then
        rows+=$'    <li><a href="../">../</a></li>\n'
    fi

    # Directories first, then files, both alphabetical. Uses globbing only.
    local -a dirs=() files=()
    local prev_nullglob prev_dotglob
    shopt -q nullglob && prev_nullglob=1 || prev_nullglob=0
    shopt -q dotglob && prev_dotglob=1 || prev_dotglob=0
    shopt -s nullglob
    shopt -u dotglob

    for entry in "$dir"/*; do
        name=${entry##*/}
        if [[ -d $entry ]]; then
            dirs+=("$name")
        else
            files+=("$name")
        fi
    done

    (( prev_nullglob )) || shopt -u nullglob
    (( prev_dotglob )) && shopt -s dotglob

    for name in "${dirs[@]}"; do
        href=$(html_escape "$name")
        rows+="    <li><a href=\"${href}/\">$(html_escape "$name")/</a></li>"$'\n'
    done
    for name in "${files[@]}"; do
        href=$(html_escape "$name")
        rows+="    <li><a href=\"${href}\">$(html_escape "$name")</a></li>"$'\n'
    done

    printf -v body '<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>Index of %s</title>
</head>
<body>
<h1>Index of %s</h1>
<ul>
%s</ul>
<hr>
<p>%s</p>
</body>
</html>
' "$esc_disp" "$esc_disp" "$rows" "$SERVER_TOKEN"

    res_add_header 'Content-Type' 'text/html; charset=utf-8'
    res_send 200 -s "$body"
}

# serve_dir_with_ls DIRECTORY -- legacy compatibility: plain-text `ls -la`.
serve_dir_with_ls() {
    local dir=$1 out
    out=$(ls -la -- "$dir" 2>/dev/null)
    res_add_header 'Content-Type' 'text/plain; charset=utf-8'
    res_send 200 -s "$out"$'\n'
}

# serve_dir_or_file_from DOCROOT -- map the request path under DOCROOT and serve
# a file or directory listing. Relies on the already-canonicalized REQUEST_PATH
# (no '..' can survive canonicalization), so traversal is structurally
# impossible here. Serves index.html when present; issues a 301 to add a
# trailing slash when a directory is requested without one.
serve_dir_or_file_from() {
    local docroot=$1
    local reqpath=${REQUEST_PATH:-/}
    local target="${docroot%/}$reqpath"

    if [[ -d $target ]]; then
        if [[ $reqpath != */ ]]; then
            local loc="${reqpath}/"
            [[ -n $QUERY_STRING ]] && loc+="?$QUERY_STRING"
            redirect_to "$loc" 301
            return
        fi
        if [[ -f "${target%/}/index.html" && -r "${target%/}/index.html" ]]; then
            serve_file "${target%/}/index.html"
            return
        fi
        if [[ -r $target && -x $target ]]; then
            serve_dir "$target"
        else
            res_send_error 403
        fi
        return
    fi

    if [[ -e $target ]]; then
        if [[ -f $target && -r $target ]]; then
            serve_file "$target"
        else
            res_send_error 403
        fi
        return
    fi

    res_send_error 404
}

# serve_static_string STRING -- serve a literal string as text/plain.
serve_static_string() {
    res_add_header 'Content-Type' 'text/plain; charset=utf-8'
    res_send 200 -s "$1"$'\n'
}

# redirect_to URL [CODE] -- issue a redirect (default 302) to URL.
redirect_to() {
    local url=$1 code=${2:-302} body esc
    esc=$(html_escape "$url")
    printf -v body '<!DOCTYPE html>
<html>
<head><title>%s %s</title></head>
<body><p>Redirecting to <a href="%s">%s</a></p></body>
</html>
' "$code" "$(http_status_text "$code")" "$esc" "$esc"
    res_add_header 'Location' "$url"
    res_add_header 'Content-Type' 'text/html; charset=utf-8'
    res_send "$code" -s "$body"
}

# ---------------------------------------------------------------------------
# Legacy compatibility shims. These keep old bashttpd.conf files working.
# Crucially, none of them exit the process (the old versions did) -- they set
# REQUEST_HANDLED and return so the keep-alive loop can continue.
# ---------------------------------------------------------------------------

# add_response_header NAME VALUE -- legacy alias for res_add_header.
add_response_header() {
    res_add_header "$1" "$2"
}

# fail_with CODE -- legacy alias that sends an error page for CODE.
fail_with() {
    res_send_error "$1"
}

# send_response_ok_exit -- legacy: send a 200 with the body read from stdin.
# Content-Type defaults to text/plain unless the caller already queued one.
send_response_ok_exit() {
    local body has_ct=0 h
    for h in "${RES_HEADERS[@]}"; do
        [[ ${h,,} == content-type:* ]] && has_ct=1
    done
    (( has_ct )) || res_add_header 'Content-Type' 'text/plain; charset=utf-8'
    body=$(cat)
    res_send 200 -s "$body"$'\n'
}
