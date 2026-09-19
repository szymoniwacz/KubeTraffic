# frozen_string_literal: true

module KubeTraffic
  module Resolver
    class Container
      LISTENING_LIMITATION =
        "declared containerPort is configuration, not proof a process is listening"

      Match = Data.define(:pod, :container, :port)
      Result = Data.define(:matches)

      def self.resolve(pods, target_port)
        new(pods, target_port).resolve
      end

      def initialize(pods, target_port)
        @pods = Array(pods)
        @target_port = target_port
      end

      def resolve
        return Result.new(matches: []) if @target_port.nil? || !@target_port.resolved || @target_port.number.nil?

        matches = @pods.flat_map { |pod| matches_for(pod) }
        Result.new(
          matches: matches.sort_by { |match| [match.pod.name.to_s, match.container.name.to_s] }
        )
      end

      private

      def matches_for(pod)
        Array(pod.containers).flat_map do |container|
          Array(container.ports).filter_map do |port|
            next unless port.container_port == @target_port.number
            next if present(@target_port.name) && port.name != @target_port.name

            Match.new(pod: pod, container: container, port: port)
          end
        end
      end

      def present(value)
        value unless value.nil? || value.to_s.strip.empty?
      end
    end
  end
end
