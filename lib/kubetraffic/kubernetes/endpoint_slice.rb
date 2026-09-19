# frozen_string_literal: true

module KubeTraffic
  module Kubernetes
    TargetRef = Data.define(:kind, :namespace, :name)
    Endpoint = Data.define(:addresses, :ready, :target_ref) do
      def initialize(addresses:, ready:, target_ref: nil)
        super
      end
    end
    EndpointSlice = Data.define(:name, :namespace, :service_name, :endpoints)
  end
end
