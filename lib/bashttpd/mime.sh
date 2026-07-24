# shellcheck shell=bash
# lib/bashttpd/mime.sh
#
# MIME type resolution. A static extension table handles the common cases
# without spawning a process; anything unknown falls back to file(1) and, as a
# last resort, application/octet-stream. text/* types are tagged utf-8.

# mime_type_for FILE -> Content-Type value on stdout.
mime_type_for() {
    local file=$1 ext type
    ext=${file##*.}
    ext=${ext,,}

    case $ext in
        html|htm)  type='text/html' ;;
        css)       type='text/css' ;;
        js|mjs)    type='text/javascript' ;;
        json)      type='application/json' ;;
        xml)       type='application/xml' ;;
        txt|text)  type='text/plain' ;;
        md|markdown) type='text/markdown' ;;
        csv)       type='text/csv' ;;
        svg)       type='image/svg+xml' ;;
        png)       type='image/png' ;;
        jpg|jpeg)  type='image/jpeg' ;;
        gif)       type='image/gif' ;;
        webp)      type='image/webp' ;;
        ico)       type='image/x-icon' ;;
        avif)      type='image/avif' ;;
        woff)      type='font/woff' ;;
        woff2)     type='font/woff2' ;;
        ttf)       type='font/ttf' ;;
        otf)       type='font/otf' ;;
        pdf)       type='application/pdf' ;;
        zip)       type='application/zip' ;;
        gz|tgz)    type='application/gzip' ;;
        tar)       type='application/x-tar' ;;
        mp3)       type='audio/mpeg' ;;
        mp4)       type='video/mp4' ;;
        webm)      type='video/webm' ;;
        wasm)      type='application/wasm' ;;
        sh)        type='text/x-shellscript' ;;
        *)         type='' ;;
    esac

    if [[ -z $type ]]; then
        # Unknown extension: ask file(1) if available, else generic binary.
        if command -v file >/dev/null 2>&1; then
            type=$(file -b --mime-type -- "$file" 2>/dev/null)
        fi
        [[ -z $type ]] && type='application/octet-stream'
    fi

    # Tag text types with a charset so browsers render them correctly.
    case $type in
        text/*) printf '%s; charset=utf-8' "$type" ;;
        *)      printf '%s' "$type" ;;
    esac
}
