#!/usr/bin/env bash
# Upload an H5 frontend zip to https://upload.zhenguanyu.com/h5/ and print the
# resulting CDN URL.
#
# Discovered facts (2026-05-21):
#   - Endpoint   : POST https://upload.zhenguanyu.com/upfile
#   - Form field : `file`  (Huploadify `fileObjName: 'file'`)
#   - Size limit : 10 MB   (Huploadify `fileSizeLimit: 1024*1024*10`)
#   - File types : '*.*'   (no extension whitelist)
#   - Auth       : currently open from corp network; NO cookie / token needed
#   - Response   : the URL of the uploaded asset, plain text, one line
#
# If the endpoint ever starts requiring SSO (you'll see a 302 to login or a
# non-URL response body), fall back to the browser upload at
# https://upload.zhenguanyu.com/h5/ and paste the returned URL by hand.
#
# Usage:
#   scripts/upload-h5.sh path/to/file.zip
#   scripts/upload-h5.sh   # auto-picks newest flowscope-h5-*.zip in repo root

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ENDPOINT="https://upload.zhenguanyu.com/upfile"
MAX_BYTES=$((10 * 1024 * 1024))

if [ $# -gt 0 ]; then
    FILE="$1"
else
    # shellcheck disable=SC2012
    FILE=$(ls -t flowscope-h5-*.zip 2>/dev/null | head -1 || true)
    if [ -z "${FILE:-}" ]; then
        echo "error: no file argument and no flowscope-h5-*.zip in $(pwd)" >&2
        exit 2
    fi
    echo ">>> auto-selected: $FILE"
fi

if [ ! -f "$FILE" ]; then
    echo "error: '$FILE' does not exist" >&2
    exit 2
fi

SIZE=$(wc -c < "$FILE" | tr -d ' ')
if [ "$SIZE" -gt "$MAX_BYTES" ]; then
    echo "error: '$FILE' is $SIZE bytes, exceeds 10MB upload limit" >&2
    exit 2
fi

LOCAL_SHA=$(shasum -a 256 "$FILE" | awk '{print $1}')
echo ">>> uploading $FILE ($(du -h "$FILE" | cut -f1), sha256 ${LOCAL_SHA:0:12}…)"

# `--fail-with-body` makes curl exit non-zero on >=400 *and* still print body.
RESPONSE=$(curl -sS --fail-with-body -X POST \
    -F "file=@${FILE};type=application/zip" \
    "$ENDPOINT")

# Server replies with a single URL line on success.
if [[ ! "$RESPONSE" =~ ^https?://[^[:space:]]+$ ]]; then
    echo "error: upload endpoint returned non-URL response:" >&2
    echo "$RESPONSE" >&2
    exit 1
fi

URL="$RESPONSE"
echo ">>> uploaded -> $URL"

echo ">>> verifying remote checksum…"
TMP=$(mktemp -t flowscope-h5-verify.XXXX.zip)
trap 'rm -f "$TMP"' EXIT
curl -sS --fail "$URL" -o "$TMP"
REMOTE_SHA=$(shasum -a 256 "$TMP" | awk '{print $1}')

if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
    echo "error: checksum mismatch!" >&2
    echo "  local : $LOCAL_SHA" >&2
    echo "  remote: $REMOTE_SHA" >&2
    exit 1
fi
echo ">>> sha256 match ✅"

echo
echo "URL: $URL"
