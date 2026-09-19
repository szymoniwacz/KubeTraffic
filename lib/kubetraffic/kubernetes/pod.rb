# frozen_string_literal: true

module KubeTraffic
  module Kubernetes
    ContainerPort = Data.define(:name, :container_port)
    Container = Data.define(:name, :ports)
    Pod = Data.define(:name, :namespace, :ip, :phase, :ready, :containers) do
      def initialize(name:, namespace:, ip:, phase:, ready:, containers: [])
        super
      end
    end
  end
end
