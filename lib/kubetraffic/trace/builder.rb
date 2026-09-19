# frozen_string_literal: true

require_relative "../resolver"
require_relative "../diagnostic"

module KubeTraffic
  module Trace
    Result = Data.define(
      :target,
      :namespace,
      :ingresses,
      :match,
      :service,
      :endpoints,
      :pods,
      :target_port,
      :containers,
      :findings
    )

    class Builder
      def self.build(client, target)
        new(client).build(target)
      end

      def initialize(client)
        @client = client
      end

      def build(target)
        ingresses = @client.list_ingresses
        match = Resolver::Ingress.match(ingresses, target)
        service = resolve_service(match)
        endpoints = resolve_endpoints(service)
        pods = resolve_pods(endpoints)
        target_port = resolve_target_port(service, pods)
        containers = Resolver::Container.resolve(pods&.pods, target_port)
        findings = Diagnostic::Analyzer.new(
          target: target,
          namespace: @client.namespace,
          ingresses: ingresses,
          match: match,
          service: service,
          endpoints: endpoints,
          pods: pods,
          target_port: target_port
        ).findings

        Result.new(
          target: target,
          namespace: @client.namespace,
          ingresses: ingresses,
          match: match,
          service: service,
          endpoints: endpoints,
          pods: pods,
          target_port: target_port,
          containers: containers,
          findings: findings
        )
      end

      private

      def resolve_service(match)
        backend = match&.backend
        name = present(backend&.name)
        return nil if name.nil?

        Resolver::Service.resolve(@client.get_service(name), backend)
      end

      def resolve_endpoints(service_result)
        service = service_result&.service
        return nil if service.nil?

        Resolver::EndpointSlice.resolve(@client.list_endpoint_slices(service.name), service)
      end

      def resolve_pods(endpoint_result)
        return nil if endpoint_result.nil?

        Resolver::Pod.resolve(endpoint_result.usable_endpoints, @client)
      end

      def resolve_target_port(service_result, pod_result)
        port = service_result&.port
        return nil if port.nil?

        Resolver::TargetPort.resolve(port, pod_result&.pods)
      end

      def present(value)
        value unless value.nil? || value.to_s.strip.empty?
      end
    end
  end
end
