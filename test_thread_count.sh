#!/usr/bin/env bash
# Measures OS thread count of the MCP demo server as SSE sessions accumulate,
# for both transports:
#
#   async  - AsyncStreamableHTTPTransport (fiber-native keepalive + reaper)
#   stock  - MCP::Server::Transports::StreamableHTTPTransport (Thread.new per
#            SSE connection + reaper thread)
#
# Usage: ./test_thread_count.sh [SESSIONS]   (default 10)
#
# Thread counts are taken two ways and cross-checked:
#   in-band:      the demo's `thread_count` tool reads /proc/self/task inside
#                 the server process
#   out-of-band:  this script reads /proc/<server pid>/task from outside
#
# /proc/<pid>/task is the kernel's own list of a process's threads, so it
# can't be confused by anything Ruby-level (fibers, Thread.list, etc).

set -euo pipefail
cd "$(dirname "$0")"

SESSIONS=${1:-10}
CURL_PIDS=()
SERVER_PID=""

# The stock-transport variant of the demo, generated here so the demo itself
# stays clean of test switches.
STOCK_DEMO=/tmp/ratalada_stock_demo.rb
cat > "$STOCK_DEMO" <<'RUBY'
require "ratalada/falcon"
require "mcp"
require "mcp/server/transports/streamable_http_transport"

class ThreadCountTool < MCP::Tool
  tool_name "thread_count"
  description "Reports the kernel's OS thread count for this process"
  input_schema(properties: {}, required: [])

  class << self
    def call(server_context:)
      count = Dir.children("/proc/self/task").size
      MCP::Tool::Response.new([{ type: "text", text: "kernel threads: #{count}" }])
    end
  end
end

Server.run do |request|
  @transport ||= MCP::Server::Transports::StreamableHTTPTransport.new(
    MCP::Server.new(name: "stock_demo", version: "0.1.0", tools: [ThreadCountTool]),
  )

  case request
  in [_, "/mcp"]  then @transport.call(request.env)
  in ["GET", "/"] then "ok\n"
  end
end
RUBY

cleanup() {
  ((${#CURL_PIDS[@]})) && kill "${CURL_PIDS[@]}" 2>/dev/null || true
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup EXIT

start_server() { # $1=port $2=script path
  PORT="$1" bundle exec ruby "$2" >/dev/null 2>&1 &
  SERVER_PID=$!
  for _ in $(seq 1 40); do
    curl -sf -o /dev/null -m 1 "http://127.0.0.1:$1/" 2>/dev/null && return 0
    sleep 0.25
  done
  echo "server on port $1 failed to start" >&2
  exit 1
}

stop_server() {
  ((${#CURL_PIDS[@]})) && kill "${CURL_PIDS[@]}" 2>/dev/null || true
  CURL_PIDS=()
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=""
}

new_session() { # $1=port -> prints session id
  local sid
  sid=$(curl -si "http://127.0.0.1:$1/mcp" \
    -H 'content-type: application/json' \
    -H 'accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"thread-test","version":"0"}}}' \
    | grep -i '^mcp-session-id:' | tr -d '\r' | awk '{print $2}')
  [[ -n "$sid" ]] || { echo "initialize failed" >&2; exit 1; }
  curl -s -o /dev/null "http://127.0.0.1:$1/mcp" \
    -H 'content-type: application/json' \
    -H 'accept: application/json, text/event-stream' \
    -H "mcp-session-id: $sid" \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  echo "$sid"
}

open_sse_stream() { # $1=port $2=session id
  curl -sN "http://127.0.0.1:$1/mcp" \
    -H 'accept: text/event-stream' \
    -H "mcp-session-id: $2" >/dev/null 2>&1 &
  CURL_PIDS+=($!)
}

threads_in_band() { # $1=port $2=session id
  curl -sN "http://127.0.0.1:$1/mcp" \
    -H 'content-type: application/json' \
    -H 'accept: application/json, text/event-stream' \
    -H "mcp-session-id: $2" \
    -d '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"thread_count","arguments":{}}}' \
    | grep -o 'kernel threads: [0-9]*' | grep -o '[0-9]*'
}

threads_out_of_band() {
  # ratalada runs the server under a supervising controller; requests are
  # served by its worker child, so measure that (fall back to the parent).
  local worker
  worker=$(pgrep -P "$SERVER_PID" | head -1)
  ls "/proc/${worker:-$SERVER_PID}/task" | wc -l
}

run_variant() { # $1=name $2=port $3=script path
  local name=$1 port=$2 script=$3 sid baseline with_streams external

  start_server "$port" "$script"

  sid=$(new_session "$port")
  baseline=$(threads_in_band "$port" "$sid")

  for _ in $(seq 1 "$SESSIONS"); do
    open_sse_stream "$port" "$(new_session "$port")"
  done
  sleep 1 # let keepalive threads (if any) spawn

  with_streams=$(threads_in_band "$port" "$sid")
  external=$(threads_out_of_band)

  printf '%-7s %10s %18s %20s\n' "$name" "$baseline" "$with_streams" "$external"

  stop_server
}

echo "Opening $SESSIONS SSE sessions against each transport..."
echo
printf '%-7s %10s %18s %20s\n' "variant" "baseline" "with $SESSIONS streams" "(external check)"
run_variant async 9292 demo.rb
run_variant stock 9293 "$STOCK_DEMO"
echo
echo "baseline           = main thread + Ruby's internal timer thread (+ reaper thread for stock)"
echo "with N streams     = async should stay flat; stock grows by one keepalive thread per stream"
echo "(external check)   = same number read from /proc/<pid>/task by this script"
