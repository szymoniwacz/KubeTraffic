# frozen_string_literal: true

module KubeTraffic
  module Resolver
    class EndpointSlice
      Result = Data.define(:slices, :endpoints) do
        def ready_endpoints
          endpoints.select { |endpoint| endpoint.ready == true }
        end

        def not_ready_endpoints
          endpoints.select { |endpoint| endpoint.ready == false }
        end

        def unknown_readiness_endpoints
          endpoints.select { |endpoint| endpoint.ready.nil? }
        end

        def usable_endpoints
          ready_endpoints
        end
      end

      def self.resolve(slices, service)
        new(slices).resolve(service)
      end

      def initialize(slices)
        @slices = Array(slices)
      end

      def resolve(service)
        return Result.new(slices: [], endpoints: []) if service.nil?

        slices = associated_slices(service).sort_by(&:name)
        Result.new(slices: slices, endpoints: slices.flat_map(&:endpoints))
      end

      private

      def associated_slices(service)
        @slices.select do |slice|
          slice.service_name == service.name &&
            (slice.namespace.nil? || slice.namespace == service.namespace)
        end
      end
    end
  end
end
