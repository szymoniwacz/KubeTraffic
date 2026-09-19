# frozen_string_literal: true

require "uri"
require_relative "target"

module KubeTraffic
  class TargetParser
    Error = Class.new(StandardError)

    HTTP_SCHEMES = %w[http https].freeze

    def self.parse(input)
      new.parse(input)
    end

    def parse(input)
      raw = input.to_s.strip
      raise Error, "target is required" if raw.empty?

      uri = parse_uri(raw)
      host = uri.host.to_s
      raise Error, "invalid target: #{raw.inspect}" if host.empty?

      Target.new(host: host.downcase, path: normalize_path(uri.path))
    rescue URI::InvalidURIError
      raise Error, "invalid target: #{raw.inspect}"
    end

    private

    def parse_uri(raw)
      uri = if scheme?(raw)
              URI.parse(raw)
            else
              URI.parse("https://#{raw}")
            end

      unless HTTP_SCHEMES.include?(uri.scheme)
        raise Error, "invalid target: #{raw.inspect}"
      end

      uri
    end

    def scheme?(raw)
      raw.match?(%r{\A[a-zA-Z][a-zA-Z0-9+.-]*://})
    end

    def normalize_path(path)
      return "/" if path.nil? || path.empty?

      path.start_with?("/") ? path : "/#{path}"
    end
  end
end
