# frozen_string_literal: true

module KubeTraffic
  module Kubernetes
    Error = Class.new(StandardError)
    ConfigError = Class.new(Error)
    ConnectionError = Class.new(Error)
    AuthorizationError = Class.new(Error)
    ApiError = Class.new(Error)
  end
end
