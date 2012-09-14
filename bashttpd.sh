#!/bin/bash

# A simple HTTP server written in bash.
#
# Bashttpd will serve text files, and most binaries as Base64 encoded.
#
# Avleen Vig, 2012-09-13
#
# 

if [ "$(id -u)" = "0" ]; then
   echo "Hold on, tiger! Don't run this as root, k?" 1>&2
   exit 1
fi


DOCROOT=/var/www/html

DATE=$( date +"%a, %d %b %Y %H:%M:%S %Z" )
REPLY_HEADERS="Date: ${DATE}
Expires: ${DATE}
Server: Slash Bin Slash Bash"

function get_content_type() {
    URL_PATH=$1
    CONTENT_TYPE=$( file --mime-type ${URL_PATH} | awk '{ print $2 }' )
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

while read line; do
    # If we've reached the end of the headers, break.
    echo ${line} | grep -v '^GET' > /dev/null
    if [ $? -eq 0 ]; then
        break
    fi

    # Look for a GET request
    echo ${line} | grep ^GET > /dev/null
    if [ $? -eq 0 ]; then
        URL_PATH="${DOCROOT}$( echo ${line} | awk '{print $2}' )"
        URL_PATH=$( echo ${URL_PATH} | tr -d '\r' )
    fi
done

[[ "$URL_PATH" == *..* ]] && echo "HTTP/1.0 400 Bad Request\rn";echo "${REPLY_HEADERS}"; exit 

# If URL_PATH isn't set, return 400
if [ -z "${URL_PATH}" ]; then
    echo "HTTP/1.0 400 Bad Request"
    echo "${REPLY_HEADERS}"
    echo
    exit
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
    echo "HTTP/1.0 403 Forbidden"
    echo "${REPLY_HEADERS}"
    echo
    exit
elif [ -d ${URL_PATH} ]; then
    # Return 200 for directory listings
    CONTENT_TYPE="text/plain"
    CONTENT_BODY=$( ls -la ${URL_PATH} )
    CONTENT_LENGTH=$(echo "${CONTENT_BODY}" | wc -c)
    HTTP_RESPONSE="HTTP/1.0 200 OK"
elif [ -d ${URL_PATH} -a ! -x ${URL_PATH} ]; then
    # Return 403 for non-listable directories
    echo "HTTP/1.0 403 Forbidden"
    echo "${REPLY_HEADERS}"
    echo
    exit
else
    echo "HTTP/1.0 404 Not Found"
    echo "${REPLY_HEADERS}"
    echo
    exit
fi

echo -n "${HTTP_RESPONSE}"
echo "${REPLY_HEADERS}"
#echo "Content-length: ${CONTENT_LENGTH}"
echo "Content-type: ${CONTENT_TYPE}"
echo
echo "${CONTENT_BODY}"
exit
