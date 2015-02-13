bashttpd is a simple, configurable web server written in bash

Requirements
-------------

  1. `bash`, any recent version should work
  2. `socat` or `netcat` to handle the underlying sockets. 
  3. A healthy dose of insanity

Examples
---------

      socat TCP4-LISTEN:8080 EXEC:/usr/local/bin/bashttpd

Or

      netcat -lp 8080 -e ./bashttpd

Note that in the `socat` example above, the web server will immediately exit once the first connection closes. If you wish to serve to more than one client - like most servers do, then use the variant:

     socat TCP4-LISTEN:8080,fork EXEC:/usr/local/bin/bashttpd

This way, a new process is spawned for each incoming connection.


Getting started
----------------

  1. Running bashttpd for the first time will generate a default configuration file, bashttpd.conf
  2. Review bashttpd.conf and configure it as you want.
  3. Run bashttpd using netcat or socat, as listed above.

Features
---------

  1. Serves text and HTML files
  2. Shows directory listings
  3. Allows for configuration based on the client-specified URI

Limitations
------------

  1. Does not support authentication
  2. Doesn't strictly adhere to the HTTP spec.

Security
--------

  1. Only rudimentary input handling.  We would not running this on a public machine.

HTTP protocol support
---------------------

  403: Returned when a directory is not listable, or a file is not readable
  400: Returned when the first word of the first line is not `GET`
  200: Returned with valid content
  Content-type: Bashttpd uses /usr/bin/file to determine the MIME type to sent to the browser
  1.0: The server doesn't support Host: headers or other HTTP/1.1 features - it barely supports HTTP/1.0!

As always, your patches/pull requests are welcome!

Testimonials
------------

"If anyone installs that anywhere, they might meet a gruesome end with a rusty fork"
    --- BasHTTPd creator, maintainer
