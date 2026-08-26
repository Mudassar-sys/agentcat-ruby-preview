# frozen_string_literal: true

require "json"

module AgentCat
  # Sanitization and truncation, matching the reference SDK's documented
  # limits exactly: depth 10, breadth 100, 32KB strings, 100KB events —
  # shrinking progressively rather than dropping.
  module Truncation
    MAX_DEPTH = 10
    MAX_BREADTH = 100
    MAX_STRING_LENGTH = 32_768
    MAX_EVENT_BYTES = 102_400
    SUFFIX = "…[truncated]"

    class << self
      def truncate_value(value, depth = MAX_DEPTH, breadth = MAX_BREADTH, max_string = MAX_STRING_LENGTH)
        case value
        when String
          value.length > max_string ? value[0, max_string] + SUFFIX : value
        when Hash
          return "[max depth reached]" if depth <= 0

          out = {}
          value.each_with_index do |(k, v), i|
            if i >= breadth
              out[:__truncated__] = "#{value.size - breadth} more keys"
              break
            end
            out[k] = truncate_value(v, depth - 1, breadth, max_string)
          end
          out
        when Array
          return "[max depth reached]" if depth <= 0

          head = value.first(breadth).map { |v| truncate_value(v, depth - 1, breadth, max_string) }
          head.push("…#{value.size - breadth} more items") if value.size > breadth
          head
        else
          value
        end
      end

      # Progressive shrinking: halve string budget until the serialized
      # event fits MAX_EVENT_BYTES, rather than dropping the event.
      def fit_event(event)
        budget = MAX_STRING_LENGTH
        candidate = truncate_value(event)
        while JSON.generate(candidate).bytesize > MAX_EVENT_BYTES && budget > 64
          budget /= 2
          candidate = truncate_value(event, MAX_DEPTH, MAX_BREADTH, budget)
        end
        candidate
      end
    end
  end
end
