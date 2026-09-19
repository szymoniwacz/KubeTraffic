# frozen_string_literal: true

module KubeTraffic
  module Kubernetes
    Pod = Data.define(:name, :namespace, :ip, :phase, :ready)
  end
end
