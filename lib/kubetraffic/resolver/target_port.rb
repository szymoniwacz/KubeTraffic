# frozen_string_literal: true

module KubeTraffic
  module Resolver
    class TargetPort
      Result = Data.define(:number, :name, :resolved)

      def self.resolve(service_port, pods)
        new(service_port, pods).resolve
      end

      def initialize(service_port, pods)
        @service_port = service_port
        @pods = Array(pods)
      end

      def resolve
        return Result.new(number: nil, name: nil, resolved: false) if @service_port.nil?

        if !@service_port.target_port_number.nil?
          Result.new(number: @service_port.target_port_number, name: nil, resolved: true)
        elsif present(@service_port.target_port_name)
          resolve_named(@service_port.target_port_name)
        else
          Result.new(number: nil, name: nil, resolved: false)
        end
      end

      private

      def resolve_named(name)
        numbers = matching_container_ports(name).map(&:container_port).uniq
        if numbers.size == 1
          Result.new(number: numbers.first, name: name, resolved: true)
        else
          Result.new(number: nil, name: name, resolved: false)
        end
      end

      def matching_container_ports(name)
        @pods.flat_map do |pod|
          Array(pod.containers).flat_map do |container|
            Array(container.ports).select { |port| port.name == name }
          end
        end
      end

      def present(value)
        value unless value.nil? || value.to_s.strip.empty?
      end
    end
  end
end
