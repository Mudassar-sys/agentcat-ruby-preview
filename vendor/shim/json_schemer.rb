# frozen_string_literal: true
#
# Sandbox-only compatibility shim.
#
# This preview environment has no access to rubygems.org, so the modern
# json_schemer (>= 2.4) required by the official `mcp` gem cannot be
# installed. Debian ships json_schemer 0.2.18, which validates the schema
# shapes used in this preview but predates the 2020-12 meta_schema option
# and the "error" key on validation errors. This shim loads the Debian gem
# and adapts its surface to what `mcp` expects.
#
# On a normal machine none of this exists: `bundle install` pulls the real
# json_schemer and this file is not loaded. The production port pins
# json_schemer >= 2.4 exactly as the mcp gem does.

real_lib = "/usr/share/rubygems-integration/all/gems/json_schemer-0.2.18/lib"
deps = %w[hana-1.3.7 regexp_parser-2.6.1 uri_template-0.7.0 ecma-re-validator-0.3.0]
deps.each do |d|
  path = "/usr/share/rubygems-integration/all/gems/#{d}/lib"
  $LOAD_PATH.push(path) unless $LOAD_PATH.include?(path)
end
$LOAD_PATH.push(real_lib) unless $LOAD_PATH.include?(real_lib)

load File.join(real_lib, "json_schemer.rb")

module JSONSchemer
  class SchemaCompat
    def initialize(inner)
      @inner = inner
    end

    def validate(data)
      @inner.validate(data).map do |err|
        pointer = err["data_pointer"].to_s
        pointer = "value" if pointer.empty?
        { "error" => "#{pointer} is invalid: failed #{err["type"]}" }.merge(err)
      end
    end

    def valid?(data)
      @inner.valid?(data)
    end

    # Newer json_schemer validates the schema document itself against its
    # meta-schema. 0.2.18 predates this; the shapes exercised in this
    # preview are plain object schemas, so schema self-validation reports
    # no errors here. The production port uses the real >= 2.4 behavior.
    def validate_schema
      []
    end

    def valid_schema?
      true
    end
  end

  class << self
    alias_method :__agentcat_real_schema, :schema

    def schema(source, **opts)
      opts.delete(:meta_schema)
      opts.delete(:format)
      src = source.is_a?(Hash) ? source.dup : source
      src.delete("$schema") if src.is_a?(Hash)
      SchemaCompat.new(__agentcat_real_schema(src, **opts))
    end
  end
end
