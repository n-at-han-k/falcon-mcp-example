#!/usr/bin/env bash
# Proves the demo is truly streaming and non-blocking, from the outside:
#
#   1. streaming:    timestamp each SSE line of a slow_counter call as it
#                    arrives — spaced ~1s apart means streamed, one burst at
#                    the end means buffered.
#   2. non-blocking: time 1 beers call (real upstream HTTPS) vs 10 fired
#                    concurrently — ~equal wall time means the upstream wait
#                    parks a fiber; ~10x means it blocked.
#   3. no threads:   kernel thread count while 10 requests are in flight.
#
# Usage: ./test_nonblocking.sh

set -euo pipefail
cd "$(dirname "$0")"

SERVER_PID=""
cleanup() { [[ -n "$SERVER_PID" ]] && kill -INT "$SERVER_PID" 2>/dev/null; wait 2>/dev/null || true; }
trap cleanup EXIT

PORT=9292 bundle exec ruby demo.rb >/dev/null 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 40); do
  curl -sf -o /dev/null -m 1 http://127.0.0.1:9292/ 2>/dev/null && break
  sleep 0.25
done

mcp() { # $1=session id (or "") $2=json body
  curl -sN --max-time 60 http://127.0.0.1:9292/mcp \
    -H 'content-type: application/json' \
    -H 'accept: application/json, text/event-stream' \
    ${1:+-H "mcp-session-id: $1"} \
    -d "$2"
}

SID=$(curl -si http://127.0.0.1:9292/mcp \
  -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"0"}}}' \
  | grep -i '^mcp-session-id:' | tr -d '\r' | awk '{print $2}')
mcp "$SID" '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null

now_ms() { date +%s%3N; }

echo "== 1. SSE response streams incrementally (slow_counter, 1s per step) =="
mcp "$SID" '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"slow_counter","arguments":{"count":3},"_meta":{"progressToken":"t"}}}' \
  | while IFS= read -r line; do
      if [[ -n "$line" ]]; then echo "  $(date +%T.%3N)  ${line:0:100}"; fi
    done

echo
echo "== 2. upstream waits park fibers (beers -> api.sampleapis.com) =="
t0=$(now_ms)
mcp "$SID" '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"beers","arguments":{}}}' >/dev/null
t1=$(now_ms)
single=$((t1 - t0))
echo "  1 call:            ${single}ms"

t0=$(now_ms)
PIDS=()
for i in $(seq 1 10); do
  mcp "$SID" "{\"jsonrpc\":\"2.0\",\"id\":$((100 + i)),\"method\":\"tools/call\",\"params\":{\"name\":\"beers\",\"arguments\":{}}}" >/dev/null &
  PIDS+=($!)
done
wait "${PIDS[@]}"
t1=$(now_ms)
concurrent=$((t1 - t0))
echo "  10 concurrent:     ${concurrent}ms   (blocking would be ~$((single * 10))ms)"

echo
echo "== 3. kernel threads while 10 slow requests are in flight =="
PIDS=()
for i in $(seq 1 10); do
  mcp "$SID" "{\"jsonrpc\":\"2.0\",\"id\":$((200 + i)),\"method\":\"tools/call\",\"params\":{\"name\":\"slow_counter\",\"arguments\":{\"count\":3}}}" >/dev/null &
  PIDS+=($!)
done
sleep 1
mcp "$SID" '{"jsonrpc":"2.0","id":300,"method":"tools/call","params":{"name":"thread_count","arguments":{}}}' \
  | grep -o 'kernel threads: [0-9]*' | sed 's/^/  (during 10 in-flight requests) /'
wait "${PIDS[@]}"
