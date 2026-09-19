# frozen_string_literal: true

module KubeTraffic
  module Resolver
    class TargetPort
      Mapping = Data.define(:pod, :number)
      Result = Data.define(:name, :number, :resolved, :mappings, :unresolved_pods) do
        def initialize(name:, number:, resolved:, mappings: [], unresolved_pods: [])
          super
        end
      end

      def self.resolve(service_port, pods)
        new(service_port, pods).resolve
      end

      def initialize(service_port, pods)
        @service_port = service_port
        @pods = Array(pods)
      end

      def resolve
        return Result.new(name: nil, number: nil, resolved: false) if @service_port.nil?

        if !@service_port.target_port_number.nil?
          Result.new(name: nil, number: @service_port.target_port_number, resolved: true)
        elsif present(@service_port.target_port_name)
          resolve_named(@service_port.target_port_name)
        else
          Result.new(name: nil, number: nil, resolved: false)
        end
      end

      private

      def resolve_named(name)
        mappings = []
        unresolved = []

        @pods.each do |pod|
          numbers = named_ports_for(pod, name).map(&:container_port).uniq
          if numbers.size == 1
            mappings << Mapping.new(pod: pod, number: numbers.first)
          else
            unresolved << pod
          end
        end

        Result.new(
          name: name,
          number: nil,
          resolved: unresolved.empty?,
          mappings: mappings.sort_by { |mapping| mapping.pod.name.to_s },
          unresolved_pods: unresolved.sort_by { |pod| pod.name.to_s }
        )
      end

      def named_ports_for(pod, name)
        Array(pod.containers).flat_map do |container|
          Array(container.ports).select { |port| port.name == name }
        end
      end

      def present(value)
        value unless value.nil? || value.to_s.strip.empty?
      end
    end
  end
end
