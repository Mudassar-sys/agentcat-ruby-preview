# frozen_string_literal: true

require "socket"
require "json"

# A tiny in-process HTTP collector used by the test suite. It records every
# event it receives (with the sender's PID) and can misbehave on demand:
#
#   mode = :ok                 -> 200
#   mode = :ambiguous_once     -> first request: record the event, then stall
#                                 past the client's read timeout (the classic
#                                 "request arrived, response lost" failure);
#                                 subsequent requests: 200
#   mode = :client_error       -> 400 (must NOT be retried)
#   mode = :flaky_then_ok      -> 500, 500, then 200
#
# Deduplication is by event id, which is exactly the property the queue's
# stable KSUID identity is supposed to make possible.
class Sink
  attr_reader :port, :received, :requests

  def initialize(mode: :ok, stall: 1.2)
    @mode = mode
    @stall = stall
    @received = []
    @requests = []
    @lock = Mutex.new
    @hits = 0
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @thread = Thread.new { serve }
  end

  def url
    "http://127.0.0.1:#{@port}/events"
  end

  def unique_event_ids
    @lock.synchronize { @received.map { |e| e["event"]["id"] }.uniq }
  end

  def events_by_pid
    @lock.synchronize { @received.group_by { |e| e["event"]["publisher_pid"] } }
  end

  def request_count
    @lock.synchronize { @requests.size }
  end

  def stop
    @thread.kill
    @server.close
  rescue StandardError
    nil
  end

  private

  def serve
    loop do
      client = @server.accept
      Thread.new(client) { |c| handle(c) }
    end
  rescue IOError, Errno::EBADF
    nil
  end

  def handle(client)
    request_line = client.gets
    headers = {}
    while (line = client.gets) && line != "\r\n"
      k, v = line.split(": ", 2)
      headers[k.downcase] = v.to_s.strip
    end
    body = client.read(headers["content-length"].to_i)
    event = JSON.parse(body) rescue {}

    hit = @lock.synchronize do
      @hits += 1
      @requests << { line: request_line.to_s.strip, id: event["id"] }
      @hits
    end

    record = lambda do
      @lock.synchronize do
        unless @received.any? { |r| r["event"]["id"] == event["id"] && event["id"] }
          @received << { "event" => event }
        end
      end
    end

    case @mode
    when :ok
      record.call
      respond(client, 200)
    when :ambiguous_once
      record.call # the event DID arrive
      if hit == 1
        sleep(@stall) # ...but the response is lost past the client timeout
        respond(client, 200)
      else
        respond(client, 200)
      end
    when :client_error
      respond(client, 400)
    when :flaky_then_ok
      if hit <= 2
        respond(client, 500)
      else
        record.call
        respond(client, 200)
      end
    end
  rescue StandardError
    nil
  ensure
    client.close rescue nil
  end

  def respond(client, status)
    body = JSON.generate(ok: status < 300)
    client.write("HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
  end
end
