#!/usr/bin/env bash
# laser-send.sh - push a gcode file to the MKS/ESP3D laser over wifi, verify it, optionally run it.
#
# Usage:
#   ./laser-send.sh <file.gc>            upload + verify only
#   ./laser-send.sh <file.gc> --run      upload, verify, then START the job (laser fires)
#   ./laser-send.sh --list               list files on the SD card
#   ./laser-send.sh --status             show machine status
#   ./laser-send.sh --pause              feed-hold (pause motion, laser off)
#   ./laser-send.sh --resume             resume after a pause
#   ./laser-send.sh --stop               soft-reset / abort the running job
#
# Env overrides: LASER_IP (default 192.168.1.119)
#
# Notes:
#  - Windows Git Bash: pass paths as D:/... (not /d/...). The script forces
#    MSYS_NO_PATHCONV so leading slashes in the upload form are not mangled.
#  - Only --run fires the laser. Be at the machine before using it.

set -euo pipefail
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
IP="${LASER_IP:-192.168.1.119}"
BASE="http://$IP"

cmd() { curl -s -m 15 -G "$BASE/command" --data-urlencode "plain=$1"; }

case "${1:-}" in
  --list)   cmd '[ESP210]list'; echo; curl -s -m 15 "$BASE/upload?path=/" ; echo; exit 0 ;;
  --status) cmd '?'; echo; exit 0 ;;
  --pause)  cmd '!'; echo "feed-hold sent"; exit 0 ;;
  --resume) cmd '~'; echo "resume sent"; exit 0 ;;
  --stop)   printf '\x18' | curl -s -m 15 -G "$BASE/command" --data-urlencode "plain=$(printf '\x18')" >/dev/null || true
            echo "soft-reset (abort) sent"; exit 0 ;;
  ""|-h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

FILE="$1"; RUN="${2:-}"
[ -f "$FILE" ] || { echo "ERROR: file not found: $FILE (use D:/... on Windows)"; exit 1; }

NAME="$(basename "$FILE")"
FULL="/$NAME"
SZ=$(wc -c <"$FILE" | tr -d ' ')

echo "Uploading $NAME ($SZ bytes) to $IP ..."
curl -s -m 300 --http1.1 -H 'Expect:' "$BASE/upload?path=/" \
  -F "path=/" -F "${FULL}=${SZ}" \
  -F "myfile[]=@${FILE};filename=${FULL};type=application/octet-stream" \
  >/dev/null

# Verify via the SD directory listing (authoritative; /SD/<name> can read 0 right after a write)
KB=$(curl -s -m 20 "$BASE/upload?path=/" \
  | tr ',' '\n' | grep -F "\"$NAME\"" -A1 | grep -oE '"size":"[^"]*"' | head -1 | sed 's/"size":"//;s/"//')
if [ -n "$KB" ]; then
  echo "OK - on SD as '$NAME' (size reported: $KB)"
else
  echo "WARNING: could not confirm '$NAME' in SD listing - check manually with --list"
fi

if [ "$RUN" = "--run" ]; then
  echo ">>> STARTING JOB - laser will fire. Ctrl-C here does NOT stop it; use --stop or the machine."
  cmd "[ESP220]${FULL}" >/dev/null
  echo "Job start command sent: [ESP220]${FULL}"
else
  echo "Not started. To run it:  ./laser-send.sh \"$FILE\" --run"
fi
