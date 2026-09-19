# frozen_string_literal: true

module KubeTraffic
  module Kubernetes
    ServicePort = Data.define(:name, :port)
    Service = Data.define(:name, :namespace, :ports)
  end
end
