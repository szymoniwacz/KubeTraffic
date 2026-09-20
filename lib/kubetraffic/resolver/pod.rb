# frozen_string_literal: true

module KubeTraffic
  module Resolver
    class Pod
      Result = Data.define(:pods, :missing)

      def self.resolve(endpoints, client)
        new(endpoints).resolve(client)
      end

      def self.for_usable_endpoints(pod_result, endpoint_result)
        return [] if pod_result.nil? || endpoint_result.nil?

        keys = {}
        Array(endpoint_result.usable_endpoints).each do |endpoint|
          ref = endpoint.target_ref
          next if ref.nil? || ref.kind != "Pod"

          keys[[ref.namespace, ref.name]] = true
        end

        pod_result.pods.select { |pod| keys[[pod.namespace, pod.name]] }
      end

      def initialize(endpoints)
        @endpoints = Array(endpoints)
      end

      def resolve(client)
        refs = pod_refs
        seen = {}
        pods = []
        missing = []

        refs.each do |ref|
          key = [ref.namespace, ref.name]
          next if seen[key]

          seen[key] = true
          pod = client.get_pod(ref.name, namespace: ref.namespace)
          if pod
            pods << pod
          else
            missing << ref
          end
        end

        Result.new(
          pods: pods.sort_by { |pod| [pod.namespace.to_s, pod.name.to_s] },
          missing: missing.sort_by { |ref| [ref.namespace.to_s, ref.name.to_s] }
        )
      end

      private

      def pod_refs
        @endpoints.filter_map do |endpoint|
          next if endpoint.ready == false

          ref = endpoint.target_ref
          next if ref.nil?
          next unless ref.kind == "Pod"
          next if present(ref.name).nil?

          ref
        end
      end

      def present(value)
        value unless value.nil? || value.to_s.strip.empty?
      end
    end
  end
end
