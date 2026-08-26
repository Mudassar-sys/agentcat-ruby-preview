# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require_relative "ksuid"
require_relative "logging"

module AgentCat
  # Background event queue.
  #
  # Design goals, in priority order:
  #
  # 1. FAULT CONTAINMENT. No code path in this class may raise into, block,
  #    or slow the customer's request thread. `publish` does a mutex-guarded
  #    array append and returns. All network I/O happens on worker threads.
  #    Ruby's GVL is released during socket I/O, so a slow or unreachable
  #    collector never contends with a request thread doing real work.
  #
  # 2. FORK SAFETY. Puma cluster mode, Unicorn and Passenger fork workers,
  #    and threads do not survive a fork: the child inherits our state but
  #    none of our worker threads. Two independent layers handle this:
  #
  #      a) An owner-PID check on every publish (works on Ruby 2.7+, the
  #         mcp gem's floor). If Process.pid no longer matches the PID that
  #         spawned the workers, we are in a forked child: reset the
  #         inherited (dead) worker list, drop the inherited mutex-free
  #         copies of unsent events (the parent still owns them), and
  #         lazily respawn workers in the child.
  #
  #      b) On Ruby 3.1+, a Process._fork hook resets the child eagerly at
  #         fork time instead of waiting for the first publish.
  #
  #    Either layer alone is sufficient for correctness; together they make
  #    "events published from a forked Puma cluster worker still arrive" a
  #    tested property rather than an assumption.
  #
  # 3. STABLE EVENT IDENTITY (fixes the failure mode of agentcat-typescript-sdk
  #    issue #65). Every event receives a KSUID `id` at enqueue time and the
  #    id travels in the publish payload, so an ambiguous failure (request
  #    reached the collector, response lost) retries with the SAME identity
  #    and the collector can deduplicate. Retries are also classified:
  #    connection errors, timeouts, HTTP 429 and 5xx retry with exponential
  #    backoff; any other 4xx is a permanent failure and is never retried.
  class EventQueue
    RETRYABLE_STATUSES = [429, 500, 502, 503, 504].freeze
    RETRYABLE_ERRORS = [
      Errno::ECONNREFUSED,
      Errno::ECONNRESET,
      Errno::EHOSTUNREACH,
      Errno::ENETUNREACH,
      Errno::ETIMEDOUT,
      SocketError,
      Timeout::Error,
    ].freeze

    attr_reader :dropped_oldest_count

    def initialize(endpoint:, max_queue_size: 10_000, concurrency: 5,
                   max_retries: 3, backoff_base: 1.0,
                   open_timeout: 2.0, read_timeout: 5.0)
      @endpoint = URI(endpoint)
      @max_queue_size = max_queue_size
      @concurrency = concurrency
      @max_retries = max_retries
      @backoff_base = backoff_base
      @open_timeout = open_timeout
      @read_timeout = read_timeout

      @lock = Mutex.new
      @cond = ConditionVariable.new
      @queue = []
      @workers = []
      @owner_pid = nil
      @shutdown = false
      @in_flight = 0
      @dropped_oldest_count = 0

      self.class.register_for_fork_reset(self)
    end

    # The only method the request path ever touches. O(1), no I/O, and it
    # never raises: a bug in analytics may cost an event, never a tool call.
    def publish(event)
      @lock.synchronize do
        return if @shutdown

        ensure_workers_locked
        event[:id] ||= KSUID.with_prefix("evt")
        if @queue.size >= @max_queue_size
          @queue.shift
          @dropped_oldest_count += 1
          Logging.log("queue full, dropped oldest event (#{@dropped_oldest_count} total)")
        end
        @queue.push(event)
        @cond.signal
      end
      true
    rescue StandardError => e
      Logging.log("publish suppressed #{e.class}: #{e.message}")
      false
    end

    # Bounded graceful drain: waits for the queue to empty and in-flight
    # requests to settle, but never longer than `timeout` seconds, so the
    # SDK can never hang the host process on shutdown.
    def drain(timeout: 5.0)
      deadline = monotonic + timeout
      loop do
        empty = @lock.synchronize { @queue.empty? && @in_flight.zero? }
        return true if empty
        return false if monotonic >= deadline

        sleep(0.02)
      end
    end

    def shutdown(timeout: 5.0)
      drained = drain(timeout: timeout)
      @lock.synchronize do
        @shutdown = true
        @cond.broadcast
      end
      Logging.log("shutdown with #{stats[:queued]} events still queued") unless drained
      drained
    end

    def stats
      @lock.synchronize do
        { queued: @queue.size, in_flight: @in_flight, workers: @workers.count(&:alive?), owner_pid: @owner_pid }
      end
    end

    # Called in the forked child (via Process._fork hook on Ruby 3.1+).
    # Inherited worker threads are dead in the child; inherited queued
    # events still belong to the parent, which goes on delivering them.
    def reset_after_fork!
      @lock = Mutex.new
      @cond = ConditionVariable.new
      @queue = []
      @workers = []
      @owner_pid = nil
      @in_flight = 0
    end

    class << self
      def register_for_fork_reset(queue)
        @instances ||= []
        @instances << queue
        install_fork_hook
      end

      def reset_all_after_fork!
        (@instances || []).each(&:reset_after_fork!)
      end

      def install_fork_hook
        return if @fork_hook_installed
        return unless Process.respond_to?(:_fork) # Ruby 3.1+; PID check covers 2.7–3.0

        hook = Module.new do
          def _fork
            pid = super
            AgentCat::EventQueue.reset_all_after_fork! if pid.zero?
            pid
          end
        end
        Process.singleton_class.prepend(hook)
        @fork_hook_installed = true
      end
    end

    private

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Lazy spawn + fork detection. Caller holds @lock.
    def ensure_workers_locked
      current = Process.pid
      unless @owner_pid == current
        # Either first use in this process, or we are a forked child whose
        # inherited threads are dead. Rebuild worker state for this PID.
        @workers = []
        @queue = @queue.dup if @owner_pid # detach from parent's array object
        @owner_pid = current
      end
      @workers.select!(&:alive?)
      while @workers.size < @concurrency
        @workers << Thread.new { worker_loop }
      end
    end

    def worker_loop
      Thread.current.name = "agentcat-publisher" if Thread.current.respond_to?(:name=)
      loop do
        event = nil
        @lock.synchronize do
          @cond.wait(@lock, 0.1) while @queue.empty? && !@shutdown
          return if @shutdown && @queue.empty?

          event = @queue.shift
          @in_flight += 1 if event
        end
        next unless event

        begin
          deliver_with_retries(event)
        rescue StandardError => e
          Logging.log("delivery abandoned for #{event[:id]}: #{e.class}")
        ensure
          @lock.synchronize { @in_flight -= 1 }
        end
      end
    rescue StandardError => e
      Logging.log("worker died #{e.class}: #{e.message}; will be respawned lazily")
    end

    def deliver_with_retries(event)
      attempts = 0
      begin
        attempts += 1
        status = post_event(event)
        return if status >= 200 && status < 300

        if RETRYABLE_STATUSES.include?(status) && attempts <= @max_retries
          sleep(@backoff_base * (2**(attempts - 1)))
          raise RetrySignal
        end
        Logging.log("permanent failure #{status} for #{event[:id]} after #{attempts} attempt(s), not retried")
      rescue RetrySignal
        retry
      rescue *RETRYABLE_ERRORS => e
        if attempts <= @max_retries
          sleep(@backoff_base * (2**(attempts - 1)))
          retry
        end
        Logging.log("gave up on #{event[:id]} after #{attempts} attempts: #{e.class}")
      end
    end

    class RetrySignal < StandardError; end

    def post_event(event)
      http = Net::HTTP.new(@endpoint.host, @endpoint.port)
      http.open_timeout = @open_timeout
      http.read_timeout = @read_timeout
      req = Net::HTTP::Post.new(@endpoint.path.empty? ? "/" : @endpoint.path, "Content-Type" => "application/json")
      req.body = JSON.generate(event)
      res = http.request(req)
      res.code.to_i
    ensure
      begin
        http.finish if http && http.started?
      rescue StandardError
        nil
      end
    end
  end
end
