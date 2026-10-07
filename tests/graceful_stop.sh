#!/bin/sh
# Stopping the container lets an HLS segment in flight finish (the image's
# STOPSIGNAL is SIGQUIT, nginx's graceful shutdown) down to its last byte
# (lingering_close: nginx exited with the tail still in the kernel, and the
# container's network went with it), and worker_shutdown_timeout bounds the
# wait. A slow client fetches segments through the vod module from a local
# upstream; small socket buffers keep a segment in nginx, not in the kernel,
# so a cut shows.
#
#   sh tests/graceful_stop.sh            builds the image
#   IMAGE=<tag> sh tests/graceful_stop.sh
# Needs docker (and network access once, for the images and ffmpeg).
set -eu
cd "$(dirname "$0")/.."
NET=nginx-vod-stop-test
DRAIN=10                       # worker_shutdown_timeout for the bound check
SEG=http://nvst-vod/hls/x/test.mp4/s   # s-1: the first 2 s of 8 Mbit/s video, s-7: 10 s
CURL=curlimages/curl:8.10.1
if [ -z "${IMAGE:-}" ]; then
  IMAGE=nginx-vod:stop-test
  docker build -q -t "$IMAGE" . >/dev/null
fi
tmp=$(mktemp -d)
cleanup() {
  docker rm -f nvst-vod nvst-upstream nvst-client >/dev/null 2>&1 || true
  docker network rm $NET >/dev/null 2>&1 || true
}
trap 'cleanup; rm -rf "$tmp"' EXIT
cleanup
docker network create $NET >/dev/null

docker run --rm -v "$tmp":/out alpine:3.20 sh -c 'apk add -q --no-cache ffmpeg >/dev/null &&
  ffmpeg -loglevel error -f lavfi -i testsrc2=size=1280x720:rate=25 -f lavfi -i sine=frequency=440:sample_rate=48000 \
    -t 40 -c:v libx264 -preset ultrafast -b:v 8M -maxrate 8M -bufsize 8M -g 50 -c:a aac -movflags +faststart /out/test.mp4'
docker run -d --name nvst-upstream --network $NET --network-alias torrent-http-proxy \
  -v "$tmp":/usr/share/nginx/html:ro nginx:1.28-alpine >/dev/null

vod() {  # extra args go to nginx
  docker rm -f nvst-vod >/dev/null 2>&1 || true
  docker run -d --name nvst-vod --network $NET --sysctl net.ipv4.tcp_wmem="4096 16384 65536" "$IMAGE" "$@" >/dev/null
  i=0
  until docker run --rm --network $NET $CURL -sf -o /dev/null http://nvst-vod/health 2>/dev/null; do
    i=$((i+1)); [ $i -lt 20 ] || { echo "FAIL: nginx-vod did not come up"; docker logs nvst-vod; exit 1; }
    sleep 1
  done
}
# fetch <segment> <rate> <max s>: a segment through a slow client, in the
# background. A reader left without a FIN hangs until <max s>: curl exit 28.
fetch() {
  docker rm -f nvst-client >/dev/null 2>&1 || true
  docker run -d --name nvst-client --network $NET --sysctl net.ipv4.tcp_rmem="4096 16384 65536" $CURL \
    -s -o /dev/null --limit-rate "$2" --max-time "$3" -H 'X-Full-Path: /test.mp4' \
    -w '%{http_code} %{size_download} %{exitcode}' "$SEG-$1-v1-a1.ts" >/dev/null
}
# stop: docker stop (the image's STOPSIGNAL, SIGKILL after 100 s); sets $took
stop() { t0=$(date +%s); docker stop -t 100 nvst-vod >/dev/null; took=$(($(date +%s) - t0)); }
got() { docker wait nvst-client >/dev/null; docker logs nvst-client; }

size() { docker run --rm --network $NET $CURL -s -o /dev/null -H 'X-Full-Path: /test.mp4' -w '%{size_download}' "$SEG-$1-v1-a1.ts"; }
vod
s1=$(size 1); s7=$(size 7)
[ "$s1" -gt 1000000 ] && [ "$s7" -gt 5000000 ] || { echo "FAIL: segments are $s1 and $s7 bytes, want > 1 MB and > 5 MB"; exit 1; }
fail=0

# 1. A segment in flight at the stop is delivered whole and closed (~20 s at
#    100 KB/s; at that pace the kernel's last ~100 KB take ~1 s to drain).
fetch 1 100k 90; sleep 3
stop; set -- $(got)
if [ "$*" = "200 $s1 0" ] && [ "$took" -ge 5 ]; then
  echo "PASS stop drains: $2 of $s1 bytes delivered and closed, the stop waited ${took} s for it"
else
  echo "FAIL stop drains: client got '$*' (code, bytes, curl exit) of $s1 bytes, the stop took ${took} s"; fail=1
fi

# 2. worker_shutdown_timeout bounds the drain: a client too slow to finish
#    (~200 s at 50 KB/s) is cut at it, and nginx exits.
vod -g "daemon off; worker_shutdown_timeout ${DRAIN}s;"
fetch 7 50k 40; sleep 3
stop; set -- $(got)
if [ "$took" -le $((DRAIN + 5)) ] && [ "${2:-0}" -lt "$s7" ]; then
  echo "PASS drain bounded: nginx exited ${took} s after the stop (worker_shutdown_timeout ${DRAIN}s), the client was cut at $2 of $s7 bytes"
else
  echo "FAIL drain bounded: the stop took ${took} s (want <= $((DRAIN + 5))), client got '$*' of $s7 bytes"; fail=1
fi
exit $fail
