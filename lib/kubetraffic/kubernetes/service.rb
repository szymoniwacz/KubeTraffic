# frozen_string_literal: true

module KubeTraffic
  module Kubernetes
    ServicePort = Data.define(:name, :port, :target_port_number, :target_port_name) do
      def initialize(name:, port:, target_port_number: nil, target_port_name: nil)
        super
      end
    end
    Service = Data.define(:name, :namespace, :ports)
  end
end
