#!/usr/bin/env bash
# Upload an arbitrary file to https://upload.zhenguanyu.com/h5/ and print the
# resulting CDN URL.
#
# Originally written for H5 frontend zip uploads; now also handles raw binaries
# (e.g. the flowscope CLI release artifact, ~72 MB).
#
# Discovered facts (2026-05-21):
#   - Endpoint   : POST https://upload.zhenguanyu.com/upfile
#   - Form field : `file`  (Huploadify `fileObjName: 'file'`)
#   - File types : '*.*'   (no extension whitelist)
#   - Auth       : currently open from corp network; NO cookie / token needed
#   - Response   : the URL of the uploaded asset, plain text, one line
#
# Size limit:
#   Huploadify's *browser-side* limit is 10 MB (`fileSizeLimit: 1024*1024*10`).
#   The server itself does NOT appear to enforce that — direct POST has been
#   verified up to the CLI binary size (~72 MB). To be safe this script lets
#   the caller raise the cap via `UPLOAD_MAX_MB` (default 200, which comfortably
#   covers the current CLI artifact).
#
# If the endpoint ever starts requiring SSO (you'll see a 302 to login or a
# non-URL response body), fall back to the browser upload at
# https://upload.zhenguanyu.com/h5/ and paste the returned URL by hand.
#
# Usage:
#   scripts/upload-h5.sh path/to/file                # any file
#   scripts/upload-h5.sh                             # auto-picks newest flowscope-h5-*.zip
#   UPLOAD_MAX_MB=500 scripts/upload-h5.sh huge.bin  # raise size cap

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ENDPOINT="https://upload.zhenguanyu.com/upfile"
MAX_MB="${UPLOAD_MAX_MB:-200}"
MAX_BYTES=$((MAX_MB * 1024 * 1024))

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
    echo "error: '$FILE' is $SIZE bytes, exceeds ${MAX_MB}MB cap" >&2
    echo "       raise with UPLOAD_MAX_MB=<n> if you trust the endpoint" >&2
    exit 2
fi

# Infer MIME by extension; default to octet-stream for raw binaries so the CDN
# serves them with the right Content-Disposition rather than guessing.
EXT="${FILE##*.}"
case "$EXT" in
    zip) MIME="application/zip" ;;
    tgz | gz) MIME="application/gzip" ;;
    tar) MIME="application/x-tar" ;;
    *) MIME="application/octet-stream" ;;
esac

LOCAL_SHA=$(shasum -a 256 "$FILE" | awk '{print $1}')
echo ">>> uploading $FILE ($(du -h "$FILE" | cut -f1), sha256 ${LOCAL_SHA:0:12}…, mime $MIME)"

# `--fail-with-body` makes curl exit non-zero on >=400 *and* still print body.
RESPONSE=$(curl -sS --fail-with-body -X POST \
    -F "file=@${FILE};type=${MIME}" \
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
TMP=$(mktemp -t flowscope-upload-verify.XXXXXX)
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
