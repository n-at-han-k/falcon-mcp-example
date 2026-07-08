# falcon-mcp-example

An MCP server over [Streamable HTTP](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports#streamable-http),
served by [Falcon](https://github.com/socketry/falcon) — asynchronous,
fiber-based MCP with no thread pool to exhaust.

The [MCP Ruby SDK](https://github.com/modelcontextprotocol/ruby-sdk)'s
`StreamableHTTPTransport` is a plain Rack app whose SSE responses are Rack 3
streaming bodies. Falcon runs each request on a fiber, so an open SSE stream
is a parked fiber costing kilobytes — where a threaded server pins a pool
thread per connection. Measured here, with receipts.

## Run it

```bash
bundle install
bundle exec ruby demo.rb
```

Then, following the curl commands in the header of `demo.rb`: initialize a
session, open its SSE stream, and call tools — including a `slow_counter`
that streams progress notifications and a `beers` tool that proxies
`https://api.sampleapis.com/beers/ale` through a pooled `Async::HTTP::Client`.

## Files

| file | what |
|---|---|
| `demo.rb` | The whole server: tools at the top, everything else inside one `Server.run` block ([ratalada](https://github.com/n-at-han-k/ratalada) + falcon). |
| `async_streamable_http_transport.rb` | The SDK transport with its two `Thread.new` housekeeping loops moved onto the reactor — SSE keepalive runs on the stream's own fiber, session reaping as a reactor task. |
| `config.ru` | Minimal alternative: the stock SDK transport mounted directly, for `falcon serve`. |
| `test_thread_count.sh` | Measures OS threads (via `/proc/<pid>/task`, in-band and out-of-band) as SSE sessions accumulate — stock vs fiber-native transport. |
| `test_nonblocking.sh` | Proves streaming and non-blocking behavior from the outside, with timing. |
| `THREAD_COUNT_TESTING.md` | How the thread measurements work and how to read them. |

## Measured results

`./test_thread_count.sh 10` — kernel threads by transport:

```
variant   baseline    with 10 streams
async            2                  2     (fiber-native: flat forever)
stock            3                 13     (one OS thread per SSE connection)
```

`./test_nonblocking.sh` — streaming and concurrency:

```
== SSE response streams incrementally ==
  07:45:12.312  notifications/progress 1     <- 1s apart at the client:
  07:45:13.313  notifications/progress 2        streamed, not buffered
  07:45:14.314  notifications/progress 3

== upstream waits park fibers (real HTTPS to sampleapis.com) ==
  1 call:            468ms
  10 concurrent:     813ms      (blocking would be ~4680ms)

== kernel threads while 10 slow requests are in flight ==
  kernel threads: 2
```

## Caveats

- Sessions live in process memory, so run one process. Scaling out means
  sticky routing on `Mcp-Session-Id` or an external session store.
- The thread measurements read `/proc`, so Linux only.
