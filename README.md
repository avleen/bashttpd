bashttpd is a basic web server.

Requirements:
  1. `bash`, any recent version should work
  2. `socat` to handle the underlying sockets (I.e., socat TCP4-LISTEN:8080 EXEC:/usr/local/bin/bashttpd.sh)
  3. A healthy dose of insanity

Features:
  1. Serves text and HTML files
  2. Shows directory listings

Limitations (PATCHES WELCOME!):
  1. Cannot yet serve files - we just need a way to encode files correctly on the command line. Any suggestions?
  2. Does not support authentication

Security:
  1. No input filtering yet.

HTTP protocol support:
  403: Returned when a directory is not listable, or a file is not readable
  400: Returned when the first word of the first line is not `GET`
  200: Returned with valid content
  Content-type: Bashttpd uses /usr/bin/file to determine the MIME type to sent to the browser
  1.0: The server doesn't support Host: headers or other HTTP/1.1 features - it barely supports HTTP/1.0!
  

I believe it is possible to have a fairly complete HTTP server written in shell, and I welcome any patches to it!
