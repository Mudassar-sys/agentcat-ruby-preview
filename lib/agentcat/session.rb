# frozen_string_literal: true

require "openssl"
require_relative "ksuid"

module AgentCat
  # Explicit session handles per MCP SEP-2567 (the 2026-07-28 stateless world).
  #
  # There is no protocol-level session anymore: servers are per-request
  # factories behind load balancers with no shared storage. So issued IDs
  # must be verifiable WITHOUT server-side state. We mint
  #
  #   ses_<KSUID>.<10-char HMAC tag>
  #
  # where the tag is derived deterministically from the KSUID with a
  # project-scoped secret. Any instance holding the secret can verify that
  # an incoming session_id was issued by this deployment; an ID we never
  # issued fails the tag check and is rejected with a re-issue instruction,
  # never adopted. This mirrors the cross-SDK v2 brief: explicit, stateless,
  # per-request mechanisms only.
  #
  # Agent-facing copy is byte-for-byte from the reference implementation's
  # constants — the brief is explicit that this wording drives agent
  # behavior and must not be reworded.
  class SessionHandles
    MINT_BACK_HEADER_SESSION = "[MCP INSTRUCTIONS]: session_id issued."
    MINT_BACK_HEADER_INVALID = "[MCP INSTRUCTIONS]: session_id not recognized."
    MINT_BACK_CLOSER = "Without session_id, this server does not function as intended."
    MINT_BACK_INVALID_LINE =
      "  The session_id you sent was not issued by this server. Re-send the exact session_id " \
      "this server issued to you earlier in this conversation. Never invent a value. If this " \
      "server has not issued you a session_id yet, omit the parameter and one will be issued."

    TAG_LENGTH = 10

    def initialize(secret: nil)
      @secret = secret || SecureRandom.hex(32)
    end

    def mint
      ksuid = KSUID.with_prefix("ses")
      "#{ksuid}.#{tag_for(ksuid)}"
    end

    # => [:minted, id] | [:echoed, id] | [:rejected, fresh_id]
    def resolve(presented)
      return [:minted, mint] if presented.nil? || presented.to_s.empty?
      return [:echoed, presented] if issued?(presented)

      [:rejected, mint]
    end

    def issued?(candidate)
      return false unless candidate.is_a?(String)

      base, tag = candidate.split(".", 2)
      return false unless base && tag
      return false unless KSUID.valid?(base, prefix: "ses")

      expected = tag_for(base)
      return false unless tag.bytesize == expected.bytesize

      OpenSSL.secure_compare(tag, expected)
    end

    def mint_back_line(session_id)
      "  session_id=#{session_id} — required on every subsequent tool call"
    end

    def mint_back_text(disposition, session_id)
      case disposition
      when :minted
        [MINT_BACK_HEADER_SESSION, mint_back_line(session_id), MINT_BACK_CLOSER].join("\n")
      when :rejected
        [MINT_BACK_HEADER_INVALID, MINT_BACK_INVALID_LINE, mint_back_line(session_id), MINT_BACK_CLOSER].join("\n")
      end
    end

    private

    def tag_for(ksuid)
      OpenSSL::HMAC.hexdigest("SHA256", @secret, ksuid)[0, TAG_LENGTH]
    end
  end
end
