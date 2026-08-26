# frozen_string_literal: true

module AgentCat
  # Local file logging, mirroring the TypeScript SDK's opt-in debug log.
  # Never raises: a failed log write is silently dropped.
  module Logging
    class << self
      attr_accessor :path, :enabled

      def log(message)
        return unless enabled

        target = path || File.join(Dir.tmpdir, "agentcat.log")
        File.open(target, "a") { |f| f.puts("[#{Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ")}] pid=#{Process.pid} #{message}") }
      rescue StandardError
        nil
      end
    end
    require "tmpdir"
    self.enabled = true
  end
end
