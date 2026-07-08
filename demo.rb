# frozen_string_literal: true

# MCP over Streamable HTTP, served by Falcon through ratalada.
#
# Run:   bundle exec ruby demo.rb
#
# Try:
#   # 1. initialize — grab the mcp-session-id response header:
#   curl -si http://127.0.0.1:9292/mcp \
#     -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' \
#     -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"0"}}}'
#
#   # 2. open the session's long-lived SSE stream (server -> client notifications):
#   curl -N http://127.0.0.1:9292/mcp -H 'accept: text/event-stream' -H "mcp-session-id: $SID"
#
#   # 3. call the slow tool — progress notifications stream back before the result:
#   curl -sN http://127.0.0.1:9292/mcp \
#     -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' \
#     -H "mcp-session-id: $SID" \
#     -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"slow_counter","arguments":{"count":5},"_meta":{"progressToken":"tok-1"}}}'

require "ratalada/falcon"
require "async/http/client"
require_relative "async_streamable_http_transport"

class SlowCounterTool < MCP::Tool
  tool_name "slow_counter"
  description "Counts to N, one second per step, reporting progress over SSE"
  input_schema(properties: { count: { type: "integer" } }, required: ["count"])

  class << self
    def call(count:, server_context:)
      count.times do |i|
        sleep(1) # parks this request's fiber; other requests and streams keep flowing
        server_context.report_progress(i + 1, total: count, message: "step #{i + 1}")
      end
      MCP::Tool::Response.new([{ type: "text", text: "counted to #{count}" }])
    end
  end
end

# An API proxy in the style of falcon's examples/proxy: one shared
# Async::HTTP::Client (it pools connections and is safe to use from many
# fibers at once). The upstream request parks this request's fiber while
# waiting on the network — no thread is tied up.
class BeersTool < MCP::Tool
  tool_name "beers"
  description "Proxies the ale list from api.sampleapis.com"
  input_schema(properties: {}, required: [])

  ENDPOINT = Async::HTTP::Endpoint.parse("https://api.sampleapis.com")

  class << self
    def client
      @client ||= Async::HTTP::Client.new(ENDPOINT)
    end

    def call(server_context:)
      response = client.get("/beers/ale")
      body = response.read.to_s

      if response.success?
        MCP::Tool::Response.new([{ type: "text", text: body }])
      else
        MCP::Tool::Response.new([{ type: "text", text: "upstream returned #{response.status}: #{body}" }])
      end
    ensure
      response&.finish
    end
  end
end

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
  @transport ||= AsyncStreamableHTTPTransport.new(MCP::Server.new(
    name: "falcon_mcp_demo",
    version: "0.1.0",
    tools: [SlowCounterTool, BeersTool, ThreadCountTool],
  ))

  case request
  in [_, "/mcp"]  then @transport.call(request.env)
  in ["GET", "/"] then "MCP demo: POST/GET/DELETE /mcp\n"
  end
end
