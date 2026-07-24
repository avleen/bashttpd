# bashttpd

An HTTP/1.1 server written entirely in `bash`. No, really.

bashttpd exists to answer a question nobody asked: how far can you push
`read`, `printf`, and parameter expansion before it starts to look like a
web server? The answer, after the 2.0 overhaul, is: keep-alive, TLS,
regex-based routing, directory listings, and a config DSL — all without a
single line of Perl, Python, or Node. It's genuinely useful for quick static
serving, local demos, CI fixtures, and inetd/socat vintage deployments. It is
not, and will never be, something you point at the internet.

## Requirements

- `bash` >= 4 (associative arrays and friends)
- `socat` or `ncat` — one of the two, to accept connections and hand them to
  the server
- `openssl` — only if you want `--tls`
- `curl` and `bats` — only for running the test suite

## Quick start

```console
$ bin/bashttpd init-config          # writes ./bashttpd.conf from the example
$ bin/bashttpd serve -p 8080 -d ./public
bashttpd 2.0 listening on http://0.0.0.0:8080 (socat)
  docroot: /path/to/public
```

With no `-d`/`-c` and no `bashttpd.conf` in the current directory, `serve`
just answers every `GET`/`HEAD` with a small "Hello, world!" string, so you
always have something to curl:

```console
$ curl http://localhost:8080/
Hello, world! bashttpd is running. Configure it with a bashttpd.conf or -d DOCROOT.
```

## CLI reference

```
Usage: bashttpd [serve] [options]
       bashttpd handle                 (serve one connection on stdin/stdout)
       bashttpd init-config [FILE]     (write an example config)
       bashttpd version | help
```

`serve` is the default subcommand if none is given.

| Option | Default | Description |
|---|---|---|
| `-p`, `--port PORT` | `8080` (`8443` with `--tls`) | Listen port |
| `-a`, `--bind ADDR` | `0.0.0.0` | Bind address |
| `-c`, `--config FILE` | `./bashttpd.conf` if present | Config file (see below) |
| `-d`, `--docroot DIR` | — | Serve this directory when no config is given |
| `--tls` | off | Enable TLS (requires `--cert` and `--key`) |
| `--cert FILE` | — | TLS certificate (PEM) |
| `--key FILE` | — | TLS private key (PEM) |
| `--timeout SECS` | `5` | Idle / keep-alive read timeout |
| `--max-requests N` | `100` | Max requests served per connection |
| `-v`, `--verbose` | off | Verbose logging to stderr |
| `--inetd` | — | Alias for the `handle` subcommand |
| `--version` | — | Print version and exit |
| `-h`, `--help` | — | Show usage |

Other subcommands:

- **`handle`** — serve exactly one connection on stdin/stdout, then exit.
  This is what `serve` execs per accepted connection (via socat/ncat's
  "run this command" mode), and it's also the entry point for classic
  inetd-style invocation.
- **`init-config [FILE]`** — copy `etc/bashttpd.conf.example` to `FILE`
  (default `bashttpd.conf`). Refuses to overwrite an existing file.
- **`version`** — print `bashttpd 2.0`.
- **`help`** — print the usage block above.

`serve` picks `socat` if it's on `PATH`, otherwise falls back to `ncat`. If
neither is installed, it exits with an error telling you to invoke `handle`
directly from your own listener.

## Configuration

`bashttpd.conf` is an ordinary bash script, sourced fresh for **every**
request. Its job is to call routing directives; the first one that matches
handles the request and later directives are skipped — same "first match
wins" model as legacy bashttpd, just without `exit`ing the process each time.

Request state available to your config:

| Variable | Meaning |
|---|---|
| `REQUEST_METHOD` | `GET`, `POST`, etc. |
| `REQUEST_URI` | raw target, e.g. `/a/b%20c?x=1` |
| `REQUEST_PATH` | decoded, canonicalized path, e.g. `/a/b c` |
| `QUERY_STRING` | everything after `?` |
| `REQUEST_HTTP_VERSION` | `HTTP/1.0` or `HTTP/1.1` |
| `HTTP_HOST` | the `Host:` header value |
| `REQUEST_BODY` | request body for POST/PUT, up to the size cap |

Routing directives:

- `on_uri_match REGEX COMMAND [ARGS...]` — if `REGEX` matches
  `REQUEST_PATH`, run `COMMAND ARGS... "${BASH_REMATCH[@]}"` (so `$1` is the
  whole match, `$2` the first capture group, and so on).
- `on_method_match METHOD COMMAND [ARGS...]` — run `COMMAND` when the
  request method equals `METHOD` (case-insensitive).
- `unconditionally COMMAND [ARGS...]` — catch-all; always dispatches if
  nothing has matched yet. The decoded path is appended as the last argument.

Built-in content commands:

- `serve_file FILE` — send one file, MIME type guessed from its extension
  (falling back to `file(1)`, then `application/octet-stream`).
- `serve_dir DIRECTORY` — an HTML directory listing, rendered in pure bash.
- `serve_dir_with_ls DIRECTORY` — legacy plain-text `ls -la` listing.
- `serve_dir_or_file_from DOCROOT` — map `REQUEST_PATH` under `DOCROOT`:
  serves `index.html` if present, otherwise a file or a listing, and issues
  a `301` to add a trailing slash when a directory is requested without one.
- `serve_static_string STRING` — serve a literal string as `text/plain`.
- `redirect_to URL [CODE]` — redirect (default `302`).

Legacy aliases still work, so old-style config files drop in unchanged:
`add_response_header`, `fail_with`, `send_response_ok_exit`.

A custom handler using a regex capture group — `GET /say_hello_to/Ada`
returns `Hello, Ada!`:

```bash
serve_hello() {
    add_response_header 'Content-Type' 'text/plain; charset=utf-8'
    send_response_ok_exit <<< "Hello, $2!"
}
on_uri_match '^/say_hello_to/(.*)$' serve_hello
```

See `etc/bashttpd.conf.example` for the full annotated example, including a
static-docroot fallback.

## TLS

Generate a throwaway self-signed cert (EC, `CN=localhost`, SANs for
`localhost`/`127.0.0.1`, 365 days):

```console
$ scripts/gen-cert.sh                # writes certs/server.crt, certs/server.key
```

Then serve over HTTPS (default TLS port is `8443`):

```console
$ bin/bashttpd --tls --cert certs/server.crt --key certs/server.key -d ./public
$ curl -k https://localhost:8443/
```

`-k` is required because it's a self-signed cert — bashttpd is not in the
business of getting you a real one.

## Classic socat / inetd usage

The top-level `bashttpd` file (not `bin/bashttpd`) is a compatibility shim
for the original invocation style. It forwards to `bin/bashttpd`, and when
called with no arguments and stdin isn't a terminal (i.e. it's a socket from
socat/inetd), it drops straight into `handle` mode:

```console
$ socat TCP4-LISTEN:8080,fork EXEC:/path/to/bashttpd
```

Or the traditional `netcat -e` style:

```console
$ netcat -lp 8080 -e ./bashttpd
```

Note that without `,fork`, `socat` exits after the first connection closes.

## Architecture

`bin/bashttpd` is a thin CLI: it parses options, then either execs
`socat`/`ncat` as a forking listener (`serve`) or sources the library and
handles one connection directly (`handle`). Everything that matters lives in
`lib/bashttpd/`, split by concern so each piece can be read (and tested) on
its own:

```
bashttpd                    # root compat shim for classic socat/inetd usage
bin/bashttpd                # CLI: option parsing, subcommands, listener exec
lib/bashttpd/
  core.sh                   # version constant, logging, core_init
  http.sh                   # status text, URL decode, path canonicalization,
                             #   request-line/header parsing, response writer
  mime.sh                   # extension -> Content-Type table + file(1) fallback
  router.sh                 # config DSL: on_uri_match / on_method_match /
                             #   unconditionally
  handlers.sh               # serve_file, serve_dir, serve_dir_or_file_from,
                             #   redirects, legacy aliases
  server.sh                 # the per-connection request loop (framing,
                             #   keep-alive, limits, dispatch, access log)
etc/bashttpd.conf.example    # annotated example config
scripts/gen-cert.sh          # self-signed cert generator for --tls
tests/                       # bats test suite
```

## HTTP/1.1 feature list

What's actually supported:

- Request line + header parsing with sane limits (max header/request-line
  length, max header count, max body size).
- `GET`, `HEAD`, `POST`, `PUT`, `DELETE`, `PATCH` dispatched to your config;
  `OPTIONS` answered directly with `204` + `Allow`; anything else gets `501`.
- Keep-alive: HTTP/1.1 connections stay open (idle timeout + a max-requests
  cap per connection) unless `Connection: close` is sent; HTTP/1.0 is
  close-by-default unless `Connection: keep-alive` is sent.
- `Host:` header required on HTTP/1.1 requests (`400` if missing).
- `Content-Length` request bodies, capped and drained even if the handler
  ignores them.
- Correct `Content-Length`, `Date`, `Server`, and `Connection` response
  headers on every response; a small HTML error page for non-2xx statuses.

What's explicitly **not** supported, on purpose:

- Chunked (or any other) request `Transfer-Encoding` — rejected with `501`.
- Byte-range requests (`Range:` / `206 Partial Content`).
- Conditional requests (`If-Modified-Since`, `ETag`, `304`) — `serve_file`
  sends `Last-Modified` but nothing ever checks it.
- Path safety is **lexical only**: `REQUEST_PATH` has `.`/`..`/`//` resolved
  and can't climb above the root, but symlinks inside your docroot are
  followed as-is. Don't symlink your docroot to something you don't want
  served.

## Testing

```console
$ tests/run              # if present
$ bats --recursive tests/
```

Tests exercise the HTTP layer with real `curl` requests against a `handle`
or `serve` instance, plus unit-level bats checks on the library functions
(URL decoding, path canonicalization, MIME lookup, etc.).

## Security

This is still a bash script parsing untrusted input from a raw socket. It's
better-behaved than the 1.x line — real status codes, request limits, no
symlink-following footguns beyond what's noted above — but it is a toy
implementation of HTTP, not a hardened one. Do not run it on a public
interface. Do not put it in front of anything you care about. You have been
warned, twice now.

## License

MIT-style; see [LICENSE](LICENSE).

## Testimonials

> "If anyone installs that anywhere, they might meet a gruesome end with a
> rusty fork"
>
> — BasHTTPd creator, maintainer
