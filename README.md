# AgentCat for Ruby — engineering preview

A working preview of the hardest 20% of porting the AgentCat TypeScript SDK to Ruby,
built against the **official `mcp` gem** (modelcontextprotocol/ruby-sdk) and written
to its **Ruby 2.7 floor**. This is not the port — it is proof, before a contract
exists, that the properties the port lives or dies on already run.

An interactive walkthrough of everything below, with the recorded run:
**see the live demo link in the proposal this repo accompanies.**

## What runs here

One line attaches, exactly like the reference SDK:

```ruby
server = MCP::Server.new(name: "demo-weather-server")
server.define_tool(name: "get_forecast", ...) { |city:| ... }

AgentCat.track(server, project_id: "proj_x")   # <- the one line
```

`test/run_all.rb` — 27 checks, all real, no mocks of the properties under test:

1. **Schema injection & strip.** `session_id` and `context` appear in `tools/list`;
   the customer's handler never sees them. A handler observing `session_id` is a
   failing test. `get_more_tools` is registered.
2. **Session lifecycle per SEP-2567.** Minted on first call via
   `structuredContent._mcp_instructions` **and** the trailing `[MCP INSTRUCTIONS]`
   text block, echoed on later calls, and an ID this server never issued is
   rejected with a re-issue instruction — never adopted. IDs are KSUIDs with a
   deterministic HMAC tag, so any per-request server instance behind a load
   balancer can verify issuance **without shared state** — built for the
   stateless 2026-07-28 world.
3. **Fault containment.** Collector unreachable, both hooks raising, queue
   saturated 12x over capacity — every tool call still returns the correct
   result. A blackholed collector changes request-path p95 by ~0.0ms, measured
   in the run: publishing happens on worker threads whose socket I/O releases
   the GVL.
4. **Fork safety, Puma-cluster shaped.** A real `Process.fork` after the queue
   thread is already running. Two layers: an owner-PID check on every publish
   (Ruby 2.7-safe) plus a `Process._fork` hook on 3.1+. Both forked children
   deliver all of their events; the master keeps delivering after the fork.
5. **Stable event identity** — the fix for the failure mode reported in
   agentcat-typescript-sdk issue #65. Every event gets a KSUID `id` at enqueue
   time that travels in the payload; an ambiguous timeout (request arrived,
   response lost) retries with the *same* id and the collector dedupes to
   exactly one stored event. Retries are classified: 429/5xx/connection errors
   retry with exponential backoff; any other 4xx is permanent and never retried.
6. **Truncation limits, byte-for-byte:** depth 10, breadth 100, 32KB strings,
   100KB events — progressive shrinking, never dropping. Plus the
   `redact_sensitive_information` hook scrubbing a synthetic secret end to end.

```
$ ruby test/run_all.rb
...
== Summary ==
27/27 checks passed
```

The full recorded output is in [`test_output.txt`](test_output.txt).

## Honest notes on what this preview is not

- It is a **preview of the hard properties**, not full parity: exporters
  (OTLP/Datadog/Sentry/PostHog), the remaining hooks, diagnostics, and the full
  test-suite port are contract work, and their design is already reflected in
  the queue and containment structure here.
- This sandbox has no rubygems.org access, so the official `mcp` gem is loaded
  from source and its `json_schemer` dependency is satisfied by a small
  documented compatibility shim (`vendor/shim/`). On a normal machine,
  `bundle install` uses the real gems and the shim is not loaded.
- CI across 2.7 → current is contract work; the code here is written to 2.7
  syntax discipline (verified with `ruby -cw`, no modern-syntax constructs).

MIT licensed. Everything here is yours to keep whatever you decide.
