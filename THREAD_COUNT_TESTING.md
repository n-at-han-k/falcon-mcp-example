# Testing OS thread count: stock vs fiber-native MCP transport

This project serves the MCP Streamable HTTP transport on Falcon. Falcon runs
one fiber per request, so open SSE connections are cheap — but the stock SDK
transport spawns real OS threads for housekeeping:

- one keepalive thread **per open SSE connection**
  (`ruby-sdk/lib/mcp/server/transports/streamable_http_transport.rb:1144`)
- one session reaper thread per transport (same file, line 397)

`async_streamable_http_transport.rb` replaces both with fibers/reactor tasks.
This document explains how to verify the difference empirically.

## What is measured, and why it's trustworthy

`/proc/<pid>/task/` is the Linux kernel's own directory of a process's
threads — one entry per thread the kernel schedules. It cannot be confused by
anything Ruby-level: fibers, `Thread.list`, green threads, or the fiber
scheduler don't appear in it. If the directory grows, the kernel created a
thread; if it doesn't, no amount of Ruby machinery did.

The test reads it from two independent places and cross-checks them:

1. **In-band** — the demo server exposes a `thread_count` MCP tool that runs
   `Dir.children("/proc/self/task").size` inside the server process, and
   returns it as a tool result over the MCP protocol itself.
2. **Out-of-band** — the test script reads `/proc/<server pid>/task` directly,
   from outside the process.

Both numbers must agree.

## Quick start

```bash
./test_thread_count.sh        # 10 SSE sessions per variant
./test_thread_count.sh 50     # or any other count
```

The script needs no arguments or setup beyond `bundle install`. For each
transport variant it:

1. starts each variant on its own port (`demo.rb` for the fiber-native
   transport; a generated `/tmp/ratalada_stock_demo.rb` for the stock one);
2. opens one control session and takes a **baseline** thread count;
3. opens N full MCP sessions (`initialize` → `notifications/initialized` →
   long-lived `GET` SSE stream held open by a background `curl -N`);
4. takes the thread count again, in-band and out-of-band;
5. kills the streams and the server, then repeats for the other variant.

## Expected output

```
variant   baseline    with 10 streams     (external check)
async            2                  2                    2
stock            3                 13                   13
```

Reading the numbers:

| number | composition |
|---|---|
| async baseline **2** | main thread + Ruby's internal timer thread |
| async with N streams **2** | unchanged — keepalive runs on each SSE body's own fiber, the reaper is a reactor task |
| stock baseline **3** | the same two + the SDK's session reaper thread (spawned in the transport's constructor) |
| stock with N streams **3 + N** | one keepalive `Thread.new` per open SSE connection |

The async variant stays flat no matter how many sessions you open; the stock
variant grows linearly. Try `./test_thread_count.sh 100` — async still reads
2, stock reads 103.

## Doing it by hand

Start a server (`demo.rb` for the fiber-native transport, or run the script
once and use the stock variant it generates at `/tmp/ratalada_stock_demo.rb`):

```bash
bundle exec ruby demo.rb
```

In another terminal, create a session and capture its ID:

```bash
SID=$(curl -si http://127.0.0.1:9292/mcp \
  -H 'content-type: application/json' \
  -H 'accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"0"}}}' \
  | grep -i '^mcp-session-id:' | tr -d '\r' | awk '{print $2}')

curl -s http://127.0.0.1:9292/mcp \
  -H 'content-type: application/json' \
  -H 'accept: application/json, text/event-stream' \
  -H "mcp-session-id: $SID" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
```

Check the count before opening any streams — via the tool:

```bash
curl -sN http://127.0.0.1:9292/mcp \
  -H 'content-type: application/json' \
  -H 'accept: application/json, text/event-stream' \
  -H "mcp-session-id: $SID" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"thread_count","arguments":{}}}'
```

or straight from the kernel:

```bash
ls /proc/$(pgrep -f 'ruby demo.rb')/task | wc -l
```

Now hold an SSE stream open (repeat with fresh sessions to open more —
each session allows only one concurrent GET stream):

```bash
curl -N http://127.0.0.1:9292/mcp \
  -H 'accept: text/event-stream' \
  -H "mcp-session-id: $SID" &
```

Re-run either count. Under `STOCK=1` it goes up by one per stream; without it,
it doesn't move.

## Caveats

- **Linux only** — the measurement relies on `/proc`. On macOS, substitute
  `ps -M <pid> | wc -l` for the out-of-band check and replace the
  `thread_count` tool's body accordingly.
- **Ports** — the script uses 9292 (async) and 9293 (stock); make sure they're
  free.
- **Teardown lag** — after a stream closes, the stock keepalive thread lives
  up to 30 more seconds (it notices the dead stream on its next ping), so
  counts taken immediately after closing streams may still include exiting
  threads. The fiber-native variant has the same 30-second lag, just for a
  parked fiber instead of a thread.
- **One process** — the transport keeps sessions in memory, so the demo runs
  Falcon single-process. Thread counts from a multi-worker deployment would
  be per-worker.
