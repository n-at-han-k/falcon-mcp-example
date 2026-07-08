# frozen_string_literal: true

# MCP Streamable HTTP transport served by Falcon.
#
# The transport is a plain Rack app (`call(env)`), and for SSE it returns
# Rack 3 streaming bodies (a proc taking a stream). Falcon's Rack adapter
# (protocol-rack) wraps such bodies in Protocol::Rack::Body::Streaming and
# runs them on a fiber under the Async reactor, so every open SSE stream is
# just a parked fiber — no thread pool to exhaust.
#
# Run with a single process (sessions are held in memory):
#   bundle exec falcon serve --bind http://localhost:9292 --count 1

require "mcp"
require "mcp/server/transports/streamable_http_transport"

class SlowCounterTool < MCP::Tool
  description "Counts to N, sending a progress notification each second over the SSE stream"
  input_schema(
    properties: { count: { type: "integer" } },
    required: ["count"],
  )

  class << self
    def call(count:, server_context: nil)
      count.times do |i|
        # In Falcon this sleep parks only this request's fiber; other
        # requests and SSE streams keep flowing.
        sleep(1)
        server_context&.[](:session)&.notify_progress(progress: i + 1, total: count)
      end

      MCP::Tool::Response.new([{ type: "text", text: "counted to #{count}" }])
    end
  end
end

class TimeTool < MCP::Tool
  description "Returns the current server time"
  input_schema(properties: {}, required: [])

  class << self
    def call(server_context: nil)
      MCP::Tool::Response.new([{ type: "text", text: Time.now.iso8601 }])
    end
  end
end

server = MCP::Server.new(
  name: "falcon_mcp_demo",
  version: "0.1.0",
  tools: [SlowCounterTool, TimeTool],
)

transport = MCP::Server::Transports::StreamableHTTPTransport.new(
  server,
  # Falcon serves on all interfaces by default; keep the default loopback
  # allow-list for local testing.
)

run transport
