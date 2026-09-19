# frozen_string_literal: true

module KubeTraffic
  module Resolver
    class Container
      LISTENING_LIMITATION =
        "declared containerPort is configuration, not proof a process is listening"

      Match = Data.define(:pod, :container, :port)
      Result = Data.define(:matches, :unmatched_pods) do
        def initialize(matches:, unmatched_pods: [])
          super
        end
      end

      def self.resolve(pods, target_port)
        new(pods, target_port).resolve
      end

      def initialize(pods, target_port)
        @pods = Array(pods)
        @target_port = target_port
      end

      def resolve
        return Result.new(matches: [], unmatched_pods: []) if @target_port.nil? || !@target_port.resolved

        if present(@target_port.name)
          resolve_named
        elsif !@target_port.number.nil?
          resolve_numeric
        else
          Result.new(matches: [], unmatched_pods: [])
        end
      end

      private

      def resolve_numeric
        matches = @pods.flat_map { |pod| matches_for(pod, @target_port.number, name: nil) }
        unmatched = @pods.reject { |pod| matched_pod?(matches, pod) }
        Result.new(matches: sorted(matches), unmatched_pods: unmatched)
      end

      def resolve_named
        matches = Array(@target_port.mappings).flat_map do |mapping|
          matches_for(mapping.pod, mapping.number, name: @target_port.name)
        end
        Result.new(matches: sorted(matches), unmatched_pods: [])
      end

      def matches_for(pod, number, name:)
        Array(pod.containers).flat_map do |container|
          Array(container.ports).filter_map do |port|
            next unless port.container_port == number
            next if present(name) && port.name != name

            Match.new(pod: pod, container: container, port: port)
          end
        end
      end

      def matched_pod?(matches, pod)
        matches.any? do |match|
          match.pod.namespace == pod.namespace && match.pod.name == pod.name
        end
      end

      def sorted(matches)
        matches.sort_by { |match| [match.pod.name.to_s, match.container.name.to_s] }
      end

      def present(value)
        value unless value.nil? || value.to_s.strip.empty?
      end
    end
  end
end
