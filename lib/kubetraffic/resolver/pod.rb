# frozen_string_literal: true

module KubeTraffic
  module Resolver
    class Pod
      Result = Data.define(:pods, :missing)

      def self.resolve(endpoints, client)
        new(endpoints).resolve(client)
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
