# frozen_string_literal: true

require "securerandom"

module AgentCat
  # Minimal KSUID implementation (K-Sortable Unique IDentifier).
  #
  # Wire format matches segmentio/ksuid: 4-byte big-endian timestamp with a
  # custom epoch (2014-05-13, 14e8 seconds) followed by 16 random bytes,
  # base62-encoded to a fixed 27 characters. Prefixed IDs ("ses_", "evt_")
  # follow the TypeScript SDK's KSUID.withPrefix behavior.
  #
  # Ruby 2.7 compatible: no endless methods, no rightward assignment, no
  # Hash#except, explicit keyword arguments only.
  module KSUID
    EPOCH = 1_400_000_000
    ALPHABET = ("0".."9").to_a + ("A".."Z").to_a + ("a".."z").to_a
    ENCODED_LENGTH = 27
    BODY_BYTES = 20

    class << self
      def random(now = Time.now)
        ts = [now.to_i - EPOCH].pack("N")
        encode(ts + SecureRandom.random_bytes(16))
      end

      def with_prefix(prefix, now = Time.now)
        "#{prefix}_#{random(now)}"
      end

      def valid?(value, prefix: nil)
        return false unless value.is_a?(String)

        body = value
        if prefix
          return false unless value.start_with?("#{prefix}_")

          body = value[(prefix.length + 1)..-1].to_s
        end
        return false unless body.length == ENCODED_LENGTH

        body.each_char.all? { |c| ALPHABET.include?(c) }
      end

      private

      def encode(bytes)
        number = bytes.unpack1("H*").to_i(16)
        out = +""
        while number > 0
          number, remainder = number.divmod(62)
          out.prepend(ALPHABET[remainder])
        end
        out.rjust(ENCODED_LENGTH, "0")
      end
    end
  end
end
