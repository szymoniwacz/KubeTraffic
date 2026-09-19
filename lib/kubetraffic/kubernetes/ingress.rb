# frozen_string_literal: true

module KubeTraffic
  module Kubernetes
    IngressServiceBackend = Data.define(:name, :port_number, :port_name)
    IngressPath = Data.define(:path, :path_type, :backend) do
      def initialize(path:, path_type:, backend: nil)
        super(path: path, path_type: path_type, backend: backend)
      end
    end
    IngressRule = Data.define(:host, :paths)
    Ingress = Data.define(:name, :namespace, :rules)
  end
end
