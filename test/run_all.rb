# frozen_string_literal: true

# AgentCat Ruby preview — acceptance test runner.
#
# Runs against the OFFICIAL mcp gem (modelcontextprotocol/ruby-sdk, loaded
# from source in this sandbox) with real MCP::Server instances, real JSON-RPC
# dispatch, real HTTP delivery to a local collector, and a real Process.fork.
#
# Usage: ruby test/run_all.rb

shim = File.expand_path("../vendor/shim", __dir__)
$LOAD_PATH.unshift(shim)
$LOAD_PATH.unshift(File.expand_path("/root/ruby-sdk/lib"))
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "json"
require "mcp"
require "agentcat"
require_relative "support/sink"

AgentCat::Logging.enabled = false

$results = []
def check(name)
  ok, detail = yield
  $results << [ok, name, detail]
  puts format("  %s %s%s", ok ? "PASS" : "FAIL", name, detail ? "  — #{detail}" : "")
rescue StandardError => e
  $results << [false, name, "#{e.class}: #{e.message}"]
  puts "  FAIL #{name}  — #{e.class}: #{e.message}"
end

def build_server(sink, seen_args, backoff: 0.05, open_timeout: 0.4, read_timeout: 0.4, redact: nil)
  server = MCP::Server.new(name: "demo-weather-server")
  server.define_tool(
    name: "get_forecast",
    description: "Returns the forecast for a city.",
    input_schema: { properties: { city: { type: "string" } }, required: ["city"] },
  ) do |city:, **rest|
    seen_args << { city: city }.merge(rest)
    MCP::Tool::Response.new([{ type: "text", text: "Sunny in #{city}, 22C" }], structured_content: { city: city, temp_c: 22 })
  end
  AgentCat.track(
    server,
    project_id: "proj_preview",
    endpoint: sink.url,
    backoff_base: backoff,
    open_timeout: open_timeout,
    read_timeout: read_timeout,
    identify: ->(_ev) { { user_id: "usr_demo" } },
    redact_sensitive_information: redact,
  )
end

def rpc(server, method, params, id: 1)
  JSON.parse(server.handle_json(JSON.generate(jsonrpc: "2.0", id: id, method: method, params: params)), symbolize_names: true)
end

def call_tool(server, name, args, id: 1)
  rpc(server, "tools/call", { name: name, arguments: args }, id: id)
end

puts "\n== 1. Schema injection & strip (acceptance criteria 1 & 2) =="
sink = Sink.new(mode: :ok)
seen = []
server = build_server(sink, seen)

check("track() attaches to an official mcp gem server and returns the tracked instance") do
  [server.is_a?(MCP::Server) && server.respond_to?(:agentcat), server.class.to_s]
end

listing = rpc(server, "tools/list", {})
forecast = listing[:result][:tools].find { |t| t[:name] == "get_forecast" }
props = forecast[:inputSchema][:properties].keys

check("injected session_id and context appear in tools/list") do
  [props.include?(:session_id) && props.include?(:context), "properties: #{props.join(", ")}"]
end

check("get_more_tools is registered and listed") do
  [listing[:result][:tools].any? { |t| t[:name] == "get_more_tools" }, nil]
end

res = call_tool(server, "get_forecast", { city: "Berkeley", session_id: nil, context: "Checking current weather conditions in Berkeley to plan the afternoon schedule for the user request" }.compact)
res2 = call_tool(server, "get_forecast", { city: "Berkeley", context: "Checking current weather conditions in Berkeley to plan the afternoon schedule for the user request" })

check("customer handler runs and returns the correct result") do
  text = res2.dig(:result, :content, 0, :text)
  [text == "Sunny in Berkeley, 22C", text]
end

check("customer handler NEVER sees injected parameters (a handler seeing session_id is a failing test)") do
  leaked = seen.any? { |a| a.key?(:session_id) || a.key?(:context) }
  [!leaked, "handler saw keys: #{seen.map(&:keys).inspect}"]
end

puts "\n== 2. Session lifecycle end to end (acceptance criterion 3) =="
minted_text = res2.dig(:result, :content).map { |c| c[:text] }.join("\n")
minted_id = minted_text[/session_id=(\S+) /, 1]

check("first call mints a session id via [MCP INSTRUCTIONS] trailing block") do
  [minted_text.include?("[MCP INSTRUCTIONS]: session_id issued.") && !minted_id.nil?, "minted #{minted_id}"]
end

check("mint-back also lands in structuredContent._mcp_instructions") do
  sc = res2.dig(:result, :structuredContent)
  [sc && sc[:_mcp_instructions].to_s.include?("session_id issued"), nil]
end

echo = call_tool(server, "get_forecast", { city: "Oakland", session_id: minted_id, context: "Comparing nearby city weather to complete the same planning task for the user request today" })
check("echoed session id is accepted silently (no re-mint block)") do
  text = echo.dig(:result, :content).map { |c| c[:text] }.join("\n")
  [!text.include?("[MCP INSTRUCTIONS]"), nil]
end

forged = call_tool(server, "get_forecast", { city: "Fresno", session_id: "ses_2zXaBcDeFgHiJkLmNoPqRsTuVwX.deadbeef00", context: "Continuing prior weather planning task using a previously stored session identifier from another server" })
forged_text = forged.dig(:result, :content).map { |c| c[:text] }.join("\n")
check("an id we never issued is rejected with a re-issue instruction, never adopted") do
  [forged_text.include?("[MCP INSTRUCTIONS]: session_id not recognized.") && forged_text.include?("Never invent a value"), nil]
end
check("rejection still returns the customer's correct tool result") do
  [forged.dig(:result, :content, 0, :text) == "Sunny in Fresno, 22C", nil]
end

sleep 0.3
sink_ids = sink.unique_event_ids
check("events for these calls were delivered to the collector") do
  [sink_ids.size >= 4, "#{sink_ids.size} unique events delivered"]
end
sink.stop

puts "\n== 3. Fault containment & latency (acceptance criterion 4) =="

# 3a. collector completely unreachable (connection refused)
dead_port_sink = Sink.new(mode: :ok)
dead_url = dead_port_sink.url
dead_port_sink.stop # port now refuses connections
seen_b = []
server_b = MCP::Server.new(name: "demo-weather-server")
server_b.define_tool(name: "get_forecast", description: "d", input_schema: { properties: { city: { type: "string" } }, required: ["city"] }) do |city:|
  seen_b << city
  MCP::Tool::Response.new([{ type: "text", text: "Sunny in #{city}, 22C" }])
end
AgentCat.track(server_b, project_id: "proj_preview", endpoint: dead_url, backoff_base: 0.02, open_timeout: 0.2, read_timeout: 0.2)
r = call_tool(server_b, "get_forecast", { city: "Berkeley", context: "Verifying that analytics outages can never affect the customer's tool call result or its latency" })
check("collector unreachable: tool call still returns the correct result") do
  [r.dig(:result, :content, 0, :text) == "Sunny in Berkeley, 22C", nil]
end
# 3b. hooks raising
sink_c = Sink.new(mode: :ok)
seen_c = []
server_c = MCP::Server.new(name: "demo-weather-server")
server_c.define_tool(name: "get_forecast", description: "d", input_schema: { properties: { city: { type: "string" } }, required: ["city"] }) do |city:|
  seen_c << city
  MCP::Tool::Response.new([{ type: "text", text: "Sunny in #{city}, 22C" }])
end
AgentCat.track(server_c, project_id: "proj_preview", endpoint: sink_c.url,
  backoff_base: 0.02,
  identify: ->(_ev) { raise "identify hook exploded" },
  redact_sensitive_information: ->(_s) { raise "redaction hook exploded" })
r = call_tool(server_c, "get_forecast", { city: "Berkeley", context: "Confirming that a raising customer hook is contained by the SDK and never reaches the tool call" })
check("both hooks raising: tool call still returns the correct result") do
  [r.dig(:result, :content, 0, :text) == "Sunny in Berkeley, 22C", nil]
end
sink_c.stop

# 3c. queue saturation
sink_d = Sink.new(mode: :ok)
queue_d = AgentCat::EventQueue.new(endpoint: sink_d.url, max_queue_size: 50, backoff_base: 0.02)
600.times { |i| queue_d.publish(event_type: "flood", n: i) }
check("queue saturated at 600 events vs capacity 50: publish never raises, oldest dropped, newest kept") do
  [queue_d.dropped_oldest_count > 0, "#{queue_d.dropped_oldest_count} oldest dropped silently"]
end
sink_d.stop

# 3d. latency: handler-observed p95 with a healthy SDK vs a blackholed collector
sink_e = Sink.new(mode: :ok)
lat = lambda do |endpoint|
  s = MCP::Server.new(name: "lat")
  s.define_tool(name: "t", description: "d", input_schema: { properties: {}, required: [] }) do
    MCP::Tool::Response.new([{ type: "text", text: "ok" }])
  end
  AgentCat.track(s, project_id: "p", endpoint: endpoint, backoff_base: 0.02, open_timeout: 0.2, read_timeout: 0.2)
  times = []
  120.times do |i|
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    s.handle_json(JSON.generate(jsonrpc: "2.0", id: i, method: "tools/call", params: { name: "t", arguments: { context: "Measuring request path latency for the fault containment proof in this acceptance run now" } }))
    times << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000
  end
  times.sort[(times.size * 0.95).floor]
end
p95_ok = lat.call(sink_e.url)
p95_dead = lat.call("http://10.255.255.1:9/events") # blackhole: connects time out
check("blackholed collector adds no request-path latency (p95 healthy vs p95 blackholed)") do
  [(p95_dead - p95_ok).abs < 5.0, format("p95 healthy=%.2fms, p95 blackholed=%.2fms", p95_ok, p95_dead)]
end
sink_e.stop

puts "\n== 4. Fork safety — real Process.fork, Puma-cluster shaped (acceptance criterion 5) =="
sink_f = Sink.new(mode: :ok)
queue_f = AgentCat::EventQueue.new(endpoint: sink_f.url, backoff_base: 0.02)
queue_f.publish(event_type: "pre-fork", publisher_pid: Process.pid, note: "queue thread started in master")
sleep 0.2
master_pid = Process.pid

worker_pids = 2.times.map do
  Process.fork do
    # Puma cluster worker: inherited threads are dead here.
    3.times { |i| queue_f.publish(event_type: "post-fork", publisher_pid: Process.pid, n: i) }
    queue_f.drain(timeout: 3)
    exit!(0)
  end
end
worker_pids.each { |pid| Process.waitpid(pid) }
queue_f.publish(event_type: "post-fork-master", publisher_pid: Process.pid)
queue_f.drain(timeout: 3)
sleep 0.2

by_pid = sink_f.events_by_pid
check("events published from forked workers still arrive (both children delivered)") do
  child_pids = by_pid.keys.compact - [master_pid]
  [child_pids.sort == worker_pids.sort, "publisher pids seen: #{by_pid.keys.inspect}"]
end
check("master keeps delivering after the fork") do
  [by_pid[master_pid] && by_pid[master_pid].size >= 2, "master events: #{by_pid[master_pid] ? by_pid[master_pid].size : 0}"]
end
check("child delivered all 3 of its events (no silent stop)") do
  counts = worker_pids.map { |pid| (by_pid[pid] || []).size }
  [counts.all? { |c| c == 3 }, "per-child counts: #{counts.inspect}"]
end
sink_f.stop

puts "\n== 5. Stable event identity & retry classification (fixes TS SDK issue #65) =="
sink_g = Sink.new(mode: :ambiguous_once, stall: 1.0)
queue_g = AgentCat::EventQueue.new(endpoint: sink_g.url, backoff_base: 0.05, open_timeout: 0.3, read_timeout: 0.3)
queue_g.publish(event_type: "important", publisher_pid: Process.pid)
queue_g.drain(timeout: 6)
sleep 1.2
check("ambiguous timeout (request arrived, response lost): retry carries the SAME event id") do
  ids = sink_g.requests.map { |r| r[:id] }.compact.uniq
  [sink_g.request_count >= 2 && ids.size == 1, "#{sink_g.request_count} requests, #{ids.size} unique id"]
end
check("collector dedupes by id: exactly one stored event, zero duplicates") do
  [sink_g.unique_event_ids.size == 1 && sink_g.received.size == 1, "stored=#{sink_g.received.size}"]
end
sink_g.stop

sink_h = Sink.new(mode: :client_error)
queue_h = AgentCat::EventQueue.new(endpoint: sink_h.url, backoff_base: 0.05)
queue_h.publish(event_type: "bad-request", publisher_pid: Process.pid)
queue_h.drain(timeout: 3)
sleep 0.3
check("HTTP 400 is a permanent failure: exactly one attempt, never retried") do
  [sink_h.request_count == 1, "#{sink_h.request_count} request(s)"]
end
sink_h.stop

sink_i = Sink.new(mode: :flaky_then_ok)
queue_i = AgentCat::EventQueue.new(endpoint: sink_i.url, backoff_base: 0.05)
queue_i.publish(event_type: "flaky", publisher_pid: Process.pid)
queue_i.drain(timeout: 6)
sleep 0.3
check("HTTP 500,500,200: retried with exponential backoff until delivered") do
  [sink_i.request_count == 3 && sink_i.received.size == 1, "#{sink_i.request_count} attempts, delivered=#{sink_i.received.size}"]
end
sink_i.stop

puts "\n== 6. Truncation & redaction limits (acceptance criterion 6) =="
deep = { a: { b: { c: { d: { e: { f: { g: { h: { i: { j: { k: { l: "too deep" } } } } } } } } } } } }
wide = (1..250).to_h { |i| ["k#{i}".to_sym, i] }
long = "x" * 90_000
t = AgentCat::Truncation.truncate_value(city: long, deep: deep, wide: wide)
check("strings truncate at 32KB") do
  [t[:city].length <= 32_768 + AgentCat::Truncation::SUFFIX.length, "#{t[:city].length} chars"]
end
check("depth capped at 10") do
  probe = t[:deep]
  10.times { probe = probe.values.first if probe.is_a?(Hash) }
  [probe.to_s.include?("max depth"), nil]
end
check("breadth capped at 100 keys") do
  [t[:wide].size <= 101, "#{t[:wide].size} keys kept"]
end
big_event = { payload: (1..40).to_h { |i| ["blob#{i}".to_sym, "y" * 20_000] } }
fitted = AgentCat::Truncation.fit_event(big_event)
check("100KB event cap enforced by progressive shrinking, event kept, not dropped") do
  bytes = JSON.generate(fitted).bytesize
  [bytes <= 102_400 && !fitted.empty?, "#{bytes} bytes"]
end

redactions = []
sink_j = Sink.new(mode: :ok)
server_j = MCP::Server.new(name: "demo")
server_j.define_tool(name: "t", description: "d", input_schema: { properties: { note: { type: "string" } }, required: [] }) do |note: nil|
  MCP::Tool::Response.new([{ type: "text", text: "ok" }])
end
AgentCat.track(server_j, project_id: "p", endpoint: sink_j.url, backoff_base: 0.02,
  redact_sensitive_information: ->(s) { redactions << s; s.gsub(/sk-[a-z0-9]+/, "[REDACTED]") })
call_tool(server_j, "t", { note: "api key sk-abc123 attached", context: "Passing a synthetic secret through the pipeline to verify text level redaction hook execution" })
sleep 0.3
check("redact_sensitive_information hook runs over event text and scrubs secrets") do
  ev = sink_j.received.first
  flat = JSON.generate(ev)
  [!flat.include?("sk-abc123") && flat.include?("[REDACTED]"), nil]
end
sink_j.stop

puts "\n== Summary =="
pass = $results.count { |r| r[0] }
puts "#{pass}/#{$results.size} checks passed"
exit($results.all? { |r| r[0] } ? 0 : 1)
