# frozen_string_literal: true

require "async"
require "mcp"
require "mcp/server/transports/streamable_http_transport"

# StreamableHTTPTransport with its two `Thread.new` housekeeping loops moved
# onto the reactor, for fully fiber-native serving under Falcon.
#
# The stock transport already works under Falcon: the request path (`Queue#pop`,
# `Mutex`, stream writes) is fiber-scheduler-aware, and the SSE stream objects
# are queue-backed (`Protocol::HTTP::Body::Streamable::Output` writes into a
# `Writable` body), so any fiber can write notifications to a stored stream.
# What remains are two OS threads the SDK spawns itself:
#
#   - one keepalive thread PER open SSE connection (base class, line 1143)
#   - one session reaper thread per transport (base class, line 396)
#
# This subclass replaces both:
#
#   - The keepalive loop runs on the SSE body's own fiber: the body proc simply
#     doesn't return while the session is live. `sleep` parks the fiber via the
#     scheduler, and response chunks written by other fibers flow through the
#     queue-backed body regardless of what this fiber is doing.
#   - The reaper runs as a reactor task, started lazily on the first request
#     (at construction time no reactor exists yet).
class AsyncStreamableHTTPTransport < MCP::Server::Transports::StreamableHTTPTransport
  KEEPALIVE_INTERVAL = 30

  def call(env)
    # Guarded: with threaded workers two reactors can race the lazy start.
    if @session_idle_timeout && !@reaper_task
      @mutex.synchronize { start_reaper_task unless @reaper_task }
    end
    super
  end

  def close
    if (task = @reaper_task)
      @reaper_task = nil
      task.stop
    end
    super
  end

  private

  # The base class calls this from #initialize, before any reactor is running.
  # Reaping is deferred to a reactor task instead — see #call.
  def start_reaper_thread
  end

  def start_reaper_task
    # Parent the task on the scheduler itself rather than the current request
    # task, so an infinite loop doesn't pin this request's connection node.
    @reaper_task = Async::Task.new(Fiber.scheduler) do
      loop do
        sleep(SESSION_REAP_INTERVAL)
        reap_expired_sessions
      rescue StandardError => e
        MCP.configuration.exception_reporter.call(e, error: "Session reaper error")
      end
    end
    @reaper_task.run
  end

  # Same lifecycle as the base implementation (store stream, ping every 30s,
  # clean up when the session dies or the stream breaks), but on this fiber
  # instead of a new OS thread. A closed stream makes send_keepalive_ping
  # raise, which exits the loop, mirroring the base class's thread exit.
  def create_sse_body(session_id)
    proc do |stream|
      next unless store_stream_for_session(session_id, stream)

      begin
        while session_active_with_stream?(session_id)
          sleep(KEEPALIVE_INTERVAL)
          send_keepalive_ping(session_id)
        end
      rescue StandardError => e
        MCP.configuration.exception_reporter.call(e, { session_id: session_id })
      ensure
        cleanup_session(session_id)
      end
    end
  end
end
