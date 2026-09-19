# frozen_string_literal: true

module KubeTraffic
  module Kubernetes
    IngressPath = Data.define(:path, :path_type)
    IngressRule = Data.define(:host, :paths)
    Ingress = Data.define(:name, :namespace, :rules)
  end
end
