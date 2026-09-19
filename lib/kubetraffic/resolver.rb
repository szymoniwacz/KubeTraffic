# frozen_string_literal: true

require_relative "resolver/ingress"
require_relative "resolver/service"
require_relative "resolver/endpoint_slice"
require_relative "resolver/pod"
require_relative "resolver/target_port"
require_relative "resolver/container"

module KubeTraffic
  module Resolver
  end
end
