# frozen_string_literal: true

module KubeTraffic
  module Resolver
    class Service
      Result = Data.define(:service, :port)

      def self.resolve(service, backend)
        new(service).resolve(backend)
      end

      def initialize(service)
        @service = service
      end

      def resolve(backend)
        return Result.new(service: nil, port: nil) if @service.nil?

        Result.new(service: @service, port: match_port(backend))
      end

      private

      def match_port(backend)
        return nil if backend.nil?

        if !backend.port_number.nil?
          @service.ports.find { |port| port.port == backend.port_number }
        elsif present(backend.port_name)
          @service.ports.find { |port| port.name == backend.port_name }
        end
      end

      def present(value)
        value unless value.nil? || value.to_s.strip.empty?
      end
    end
  end
end
