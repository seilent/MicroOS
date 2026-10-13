#!/usr/bin/env bash
set -euo pipefail

home=${1:?usage: bootstrap.sh <home> <feed> <installed> <logdir>}
feed=${2:?}
installed=${3:?}
log=${4:?}
src=$(cd "$(dirname "$0")" && pwd)
steam=$home/.local/share/Steam
url=http://127.0.0.1:8000
budget=900
mkdir -p "$log"

if curl -fsS -m 5 -o /dev/null https://client-update.steamstatic.com/ 2>/dev/null; then
  echo "bootstrap.sh: network reachable outside 127.0.0.1" >&2
  exit 1
fi

pids=()
trap 'kill "${pids[@]}" 2>/dev/null || true' EXIT
python3 -m http.server 8000 --bind 127.0.0.1 --directory "$feed" > "$log/feed.log" 2>&1 &
pids+=($!)
Xvfb :99 -screen 0 1280x800x24 -nolisten tcp > "$log/xvfb.log" 2>&1 &
pids+=($!)
for _ in $(seq 50); do
  curl -fsS -o /dev/null "$url/" 2>/dev/null && [[ -S /tmp/.X11-unix/X99 ]] && break
  sleep 0.2
done

deadline=$((SECONDS + budget))
for try in 1 2 3; do
  left=$((deadline - SECONDS))
  (( left > 0 )) || break
  rc=0
  (
    cd "$steam/steamrtarm64"
    HOME=$home DISPLAY=:99 LD_LIBRARY_PATH=$steam/steamrtarm64:$steam/lib/aarch64-linux-gnu \
      timeout "$left" ./steam -overridepackageurl "$url" -steamdeck -exitsteam
  ) > "$log/steam.$try.log" 2>&1 || rc=$?
  if [[ -f $installed ]] && python3 "$src/manifest.py" installed "$installed" "$steam"; then
    echo "bootstrap.sh: try $try installed the client (rc $rc)"
    exit 0
  fi
  echo "bootstrap.sh: try $try incomplete (rc $rc)" >&2
  tail -n 30 "$log/steam.$try.log" >&2
  (( rc != 124 )) || break
done
echo "bootstrap.sh: no complete client within ${budget} s" >&2
tail -n 20 "$log/feed.log" >&2
exit 1
