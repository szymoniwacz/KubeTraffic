# frozen_string_literal: true

require_relative "finding"

module KubeTraffic
  module Diagnostic
    class Analyzer
      def initialize(target:, namespace:, ingresses:, match:, service:, endpoints:, pods:, target_port:, containers: nil)
        @target = target
        @namespace = namespace
        @ingresses = Array(ingresses)
        @match = match
        @service = service
        @endpoints = endpoints
        @pods = pods
        @target_port = target_port
        @containers = containers
      end

      def findings
        [
          *ingress_findings,
          *service_findings,
          *endpoint_findings,
          *pod_findings,
          *target_port_findings,
          *pod_target_ref_findings,
          *container_findings
        ]
      end

      private

      def ingress_findings
        if @ingresses.empty?
          return [finding(
            :error,
            "ingress_not_found",
            "No Ingress resources in namespace #{@namespace}",
            namespace: @namespace
          )]
        end

        return [] unless @match.nil?

        [finding(
          :error,
          "ingress_not_found",
          "No Ingress rule matches #{@target} in namespace #{@namespace}",
          host: @target.host,
          path: @target.path,
          namespace: @namespace
        )]
      end

      def service_findings
        backend = @match&.backend
        name = present(backend&.name)
        return [] if name.nil? || @service.nil?

        if @service.service.nil?
          return [finding(
            :error,
            "service_not_found",
            "Service #{name} not found in namespace #{@namespace}",
            service: name,
            namespace: @namespace
          )]
        end

        return [] unless @service.port.nil?

        [finding(
          :error,
          "service_port_not_found",
          unmatched_service_port(backend),
          service: name,
          namespace: @namespace,
          port_number: backend.port_number,
          port_name: present(backend.port_name)
        )]
      end

      def endpoint_findings
        service = @service&.service
        return [] if service.nil? || @endpoints.nil?

        if @endpoints.slices.empty? || @endpoints.endpoints.empty?
          return [finding(
            :error,
            "service_no_endpoints",
            "No usable endpoints for Service #{service.name}",
            service: service.name,
            namespace: service.namespace,
            slices: @endpoints.slices.size,
            endpoints: @endpoints.endpoints.size
          )]
        end

        return [] if @endpoints.usable_endpoints.any?

        [finding(
          :error,
          "endpoint_not_ready",
          "No usable endpoints for Service #{service.name}",
          service: service.name,
          namespace: service.namespace,
          ready: @endpoints.ready_endpoints.size,
          not_ready: @endpoints.not_ready_endpoints.size,
          unknown: @endpoints.unknown_readiness_endpoints.size
        )]
      end

      def pod_findings
        return [] if @pods.nil?

        Array(@pods.missing).map do |ref|
          namespace = present(ref.namespace)
          suffix = namespace ? " in namespace #{namespace}" : ""
          finding(
            :error,
            "pod_not_found",
            "Pod #{ref.name} not found#{suffix}",
            pod: ref.name,
            namespace: namespace
          )
        end
      end

      def target_port_findings
        name = present(@target_port&.name)
        return [] if name.nil? || @target_port.resolved
        return [] if Array(@target_port.unresolved_pods).empty?

        [finding(
          :error,
          "target_port_unresolved",
          "Named targetPort #{name} unresolved",
          target_port: name,
          pods: Array(@target_port.unresolved_pods).map(&:name)
        )]
      end

      def pod_target_ref_findings
        return [] if @endpoints.nil?

        usable = @endpoints.usable_endpoints
        return [] unless usable.any?
        return [] if usable.any? { |endpoint| endpoint.target_ref&.kind == "Pod" }

        [finding(
          :warning,
          "pod_target_ref_missing",
          "Usable endpoints have no Pod targetRef",
          endpoints: usable.size
        )]
      end

      def container_findings
        return [] if @containers.nil? || @target_port.nil? || !@target_port.resolved
        return [] unless present(@target_port.name).nil?

        unmatched = Array(@containers.unmatched_pods)
        return [] if unmatched.empty? || @target_port.number.nil?

        [finding(
          :warning,
          "container_port_unmatched",
          "No declared containerPort matches #{@target_port.number}",
          target_port: @target_port.number,
          pods: unmatched.map(&:name)
        )]
      end

      def unmatched_service_port(backend)
        if !backend.port_number.nil?
          "no port matches #{backend.port_number}"
        elsif present(backend.port_name)
          "no port matches name #{backend.port_name}"
        else
          "backend port cannot be interpreted"
        end
      end

      def finding(severity, code, summary, **evidence)
        Finding.new(severity: severity, code: code, summary: summary, evidence: evidence)
      end

      def present(value)
        value unless value.nil? || value.to_s.strip.empty?
      end
    end
  end
end
