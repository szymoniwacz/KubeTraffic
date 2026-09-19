# frozen_string_literal: true

module KubeTraffic
  module Kubernetes
    Endpoint = Data.define(:addresses, :ready)
    EndpointSlice = Data.define(:name, :namespace, :service_name, :endpoints)
  end
end
