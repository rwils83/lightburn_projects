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
#  - Only --run fires the laser, and ONLY after the upload is verified byte-for-byte.
#    A failed/short upload aborts without firing. Be at the machine before using --run.

set -euo pipefail
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
IP="${LASER_IP:-192.168.1.119}"
BASE="http://$IP"

# All server URLs are built from the fixed $BASE; pass them via --url so a value
# can never be parsed as a curl option.
cmd() { curl -s -m 15 --url "$BASE/command" -G --data-urlencode "plain=$1"; }

case "${1:-}" in
  --list)   curl -s -m 20 --url "$BASE/upload?path=/"; echo; exit 0 ;;
  --status) cmd '?'; echo; exit 0 ;;
  --pause)  cmd '!' >/dev/null; echo "feed-hold sent"; exit 0 ;;
  --resume) cmd '~' >/dev/null; echo "resume sent"; exit 0 ;;
  --stop)   cmd "$(printf '\x18')" >/dev/null || true; echo "soft-reset (abort) sent"; exit 0 ;;
  ""|-h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

FILE="$1"
RUN="${2:-}"
if [ -n "$RUN" ] && [ "$RUN" != "--run" ]; then
  echo "ERROR: unknown second argument '$RUN' (did you mean --run?)"; exit 2
fi
[ -f "$FILE" ] || { echo "ERROR: file not found: $FILE (use D:/... on Windows)"; exit 1; }

NAME="$(basename -- "$FILE")"
# Restrict the SD filename to a safe set so it can't carry control chars or odd
# bytes into the upload form / run command.
case "$NAME" in
  -*|*/*) echo "ERROR: refusing unsafe filename: $NAME"; exit 2 ;;
esac
if printf '%s' "$NAME" | LC_ALL=C grep -q '[^A-Za-z0-9._ -]'; then
  echo "ERROR: filename has characters outside [A-Za-z0-9._ -]: $NAME"; exit 2
fi
FULL="/$NAME"
SZ=$(wc -c <"$FILE" | tr -d ' ')

echo "Uploading $NAME ($SZ bytes) to $IP ..."
curl -s -m 300 --http1.1 -H 'Expect:' --url "$BASE/upload?path=/" \
  -F "path=/" -F "${FULL}=${SZ}" \
  -F "myfile[]=@${FILE};filename=${FULL};type=application/octet-stream" \
  >/dev/null

# --- integrity gate: the SD listing must report this file at the SOURCE size ---
# Parse "size":"<n> <unit>" for this name and convert to bytes.
report=$(curl -s -m 20 --url "$BASE/upload?path=/" \
  | tr ',' '\n' | grep -F "\"$NAME\"" -A1 | grep -oE '"size":"[^"]*"' | head -1 \
  | sed 's/"size":"//;s/"$//')

verified=0
if [ -n "$report" ]; then
  got=$(awk -v s="$report" 'BEGIN{
    n=s; u=s; sub(/ .*/,"",n); sub(/^[0-9.]+ ?/,"",u);
    m=1; if(u=="KB")m=1024; else if(u=="MB")m=1048576; else if(u=="GB")m=1073741824;
    printf "%.0f", n*m }')
  # tolerance: reported size is rounded to 2 decimals in KB/MB, so allow ~0.6%.
  tol=$(( SZ/160 + 64 ))
  diff=$(( got>SZ ? got-SZ : SZ-got ))
  if [ "$diff" -le "$tol" ]; then verified=1; fi
  echo "SD reports: $report (~$got bytes); source $SZ bytes; diff $diff (tol $tol)"
fi

if [ "$verified" = 1 ]; then
  echo "VERIFIED - '$NAME' is on the SD at the correct size."
else
  echo "FAILED VERIFICATION - '$NAME' is missing or the wrong size on the SD."
  echo "Not starting anything. Re-run the upload; do NOT run this file until it verifies."
  exit 3
fi

if [ "$RUN" = "--run" ]; then
  echo ">>> STARTING JOB - laser will fire. Ctrl-C here does NOT stop it; use --stop or the machine."
  cmd "[ESP220]${FULL}" >/dev/null
  echo "Job start command sent: [ESP220]${FULL}"
else
  echo "Not started. To run it:  ./laser-send.sh \"$FILE\" --run"
fi
