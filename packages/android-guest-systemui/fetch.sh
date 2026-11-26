#!/usr/bin/env bash
set -euo pipefail

work=${1:?usage: fetch.sh <workdir>}
src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"

fail() { echo "fetch.sh: $*" >&2; exit 1; }
check() {
  local got
  got=$(sha256sum < "$1")
  got=${got%% *}
  [[ $got == "$2" ]] || fail "$1 has sha256 $got, SOURCE.env pins $2"
}
dump() {
  local err
  err=$(debugfs -R "dump $1 $2" "$img" 2>&1 > /dev/null) || fail "debugfs cannot dump $1 from $img: $err"
  err=$(grep -v '^debugfs [0-9][0-9.]* (.*)$' <<< "$err" || true)
  [[ -z $err ]] || fail "debugfs cannot dump $1 from $img: $err"
}

zip=$work/system.zip
img=$work/system.img
notices=$work/NOTICE.xml.gz
trap 'rm -f -- "${zip:?}" "${img:?}" "${notices:?}"' EXIT
curl -fsSL --retry 3 -o "$zip" "$SYSTEM_URL"
size=$(stat -c %s "$zip")
[[ $size == "$SYSTEM_SIZE" ]] || fail "$zip is $size bytes, SOURCE.env pins $SYSTEM_SIZE"
check "$zip" "$SYSTEM_SHA256"
unzip -q "$zip" system.img -d "$work"
rm -f -- "$zip"
dump "$SYSTEMUI_PATH" "$work/SystemUI.apk"
dump "$FRAMEWORK_RES_PATH" "$work/framework-res.apk"
dump "$NOTICE_PATH" "$notices"
rm -f -- "$img"
[[ -f $work/SystemUI.apk ]] || fail "the system image has no $SYSTEMUI_PATH"
check "$work/SystemUI.apk" "$SYSTEMUI_SHA256"
[[ -f $work/framework-res.apk ]] || fail "the system image has no $FRAMEWORK_RES_PATH"
check "$work/framework-res.apk" "$FRAMEWORK_RES_SHA256"
[[ -f $notices ]] || fail "the system image has no $NOTICE_PATH"
python3 - "$notices" "$SYSTEMUI_PATH" "$work/NOTICE.SystemUI" << 'PY'
import gzip
import html
import sys
import xml.etree.ElementTree as ET

root = ET.parse(gzip.open(sys.argv[1])).getroot()
ids = {e.get("contentId") for e in root.iter("file-name") if e.text == "/" + sys.argv[2]}
texts = [html.unescape(e.text) for e in root.iter("file-content") if e.get("contentId") in ids]
if not ids or len(texts) != len(ids):
    sys.exit(f"fetch.sh: {sys.argv[1]} has no notice for {sys.argv[2]}")
with open(sys.argv[3], "w", encoding="utf-8") as f:
    f.write("\n".join(texts))
PY
check "$work/NOTICE.SystemUI" "$SYSTEMUI_NOTICE_SHA256"
