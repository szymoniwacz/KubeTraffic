# frozen_string_literal: true

require_relative "../resolver"
require_relative "../diagnostic"

module KubeTraffic
  module Renderer
    class Human
      OK = "[ok]"
      FAIL = "[x]"

      def render(result)
        lines = []
        lines << "Tracing #{result.target} in namespace #{result.namespace}"
        lines << nil
        render_ingress(result, lines)
        render_service(result, lines)
        render_endpoints(result, lines)
        render_pods(result, lines)
        render_target_port(result, lines)
        render_containers(result, lines)
        render_warnings(result, lines)
        lines << result_line(result)
        "#{compact_blank_lines(lines).join("\n")}\n"
      end

      private

      def render_ingress(result, lines)
        finding = finding_for(result, "ingress_not_found")
        if finding
          step(lines, false, "Ingress", finding.summary)
          return
        end

        match = result.match
        step(
          lines,
          true,
          "Ingress #{match.ingress.name}",
          "host #{format_host(match.rule.host)}",
          "path #{match.path.path}",
          "pathType #{format_path_type(match.path.path_type)}",
          format_backend(match.backend)
        )
      end

      def render_service(result, lines)
        backend = result.match&.backend
        name = present(backend&.name)
        service_result = result.service
        return if name.nil? || service_result.nil?

        not_found = finding_for(result, "service_not_found")
        if not_found
          step(lines, false, "Service #{name}", not_found.summary)
          return
        end

        evidence = []
        if service_result.port
          evidence << "port #{format_service_port(service_result.port)}"
        else
          port_finding = finding_for(result, "service_port_not_found")
          evidence << (port_finding ? port_finding.summary : unmatched_service_port(backend))
        end

        step(lines, service_result.port, "Service #{service_result.service.name}", *evidence)
      end

      def render_endpoints(result, lines)
        service = result.service&.service
        endpoints = result.endpoints
        return if service.nil? || endpoints.nil?

        no_endpoints = finding_for(result, "service_no_endpoints")
        not_ready = finding_for(result, "endpoint_not_ready")

        if endpoints.slices.empty?
          step(lines, false, "EndpointSlice", "No EndpointSlices for Service #{service.name}", no_endpoints.summary)
          return
        end

        evidence = []
        endpoints.slices.each do |slice|
          evidence << slice.name
          if slice.endpoints.empty?
            evidence << "  no endpoints"
          else
            slice.endpoints.each do |endpoint|
              evidence << "  #{format_endpoint(endpoint)}"
            end
          end
        end

        if endpoints.endpoints.empty?
          evidence << "No endpoints for Service #{service.name}"
          evidence << no_endpoints.summary
          step(lines, false, "EndpointSlice", *evidence)
          return
        end

        evidence << "ready #{endpoints.ready_endpoints.size}"
        evidence << "not-ready #{endpoints.not_ready_endpoints.size}"
        evidence << "unknown readiness #{endpoints.unknown_readiness_endpoints.size}"
        evidence << not_ready.summary if not_ready
        step(lines, not_ready.nil?, "EndpointSlice", *evidence)
      end

      def render_pods(result, lines)
        endpoints = result.endpoints
        pods = result.pods
        return if endpoints.nil? || pods.nil?

        missing = findings_for(result, "pod_not_found")

        pods.pods.each do |pod|
          step(
            lines,
            true,
            "Pod #{pod.name}",
            "IP #{pod.ip || "(unknown)"}",
            "phase #{pod.phase || "(unknown)"}",
            "ready=#{format_ready(pod.ready)}"
          )
        end

        missing.each do |finding|
          step(lines, false, "Pod", finding.summary)
        end
      end

      def render_target_port(result, lines)
        port = result.service&.port
        return if port.nil?

        target = result.target_port
        if !port.target_port_number.nil?
          step(lines, true, "Target port", port.target_port_number.to_s)
          return
        end

        name = present(port.target_port_name)
        return if name.nil?

        unresolved = finding_for(result, "target_port_unresolved")
        evidence = []
        if target&.resolved
          evidence << "named #{name}"
          Array(target.mappings).each do |mapping|
            evidence << "#{mapping.pod.name} #{mapping.number}"
          end
          step(lines, true, "Target port", *evidence)
        else
          evidence << (unresolved ? unresolved.summary : "Named targetPort #{name} unresolved")
          Array(target&.mappings).each do |mapping|
            evidence << "#{mapping.pod.name} #{mapping.number}"
          end
          Array(target&.unresolved_pods).each do |pod|
            evidence << "#{pod.name} (not declared)"
          end
          step(lines, false, "Target port", *evidence)
        end
      end

      def render_containers(result, lines)
        return if result.service&.port.nil?

        target = result.target_port
        return unless target&.resolved
        return if result.containers.nil? || result.containers.matches.empty?

        result.containers.matches.each do |match|
          step(
            lines,
            true,
            "Container #{match.container.name} on Pod #{match.pod.name}",
            "port #{format_container_port(match.port)}",
            Resolver::Container::LISTENING_LIMITATION
          )
        end
      end

      def render_warnings(result, lines)
        warnings = result.findings.select { |finding| finding.severity == :warning }
        return if warnings.empty?

        lines << "Warnings:"
        warnings.each do |warning|
          lines << "     #{warning.summary}"
        end
        if warnings.any? { |warning| warning.code == "container_port_unmatched" }
          lines << "     #{Resolver::Container::LISTENING_LIMITATION}"
        end
        lines << nil
      end

      def compact_blank_lines(lines)
        compacted = []
        lines.each do |line|
          next if line.nil? && compacted.last.nil?

          compacted << line
        end
        compacted.pop while compacted.any? && compacted.last.nil?
        compacted
      end

      def result_line(result)
        error = result.findings.find { |finding| finding.severity == :error }
        if error
          "Result: failed (#{error.code})"
        else
          "Result: configuration chain complete"
        end
      end

      def step(lines, ok, title, *evidence)
        lines << "#{ok ? OK : FAIL} #{title}"
        evidence.compact.each do |line|
          lines << "     #{line}"
        end
        lines << nil
      end

      def finding_for(result, code)
        findings_for(result, code).first
      end

      def findings_for(result, code)
        result.findings.select { |finding| finding.code == code }
      end

      def format_service_port(port)
        name = present(port.name)
        name ? "#{port.port} name #{name}" : port.port.to_s
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

      def format_container_port(port)
        name = present(port.name)
        name ? "#{port.container_port} name #{name}" : port.container_port.to_s
      end

      def format_endpoint(endpoint)
        addresses = endpoint.addresses
        address_text = addresses.empty? ? "(no addresses)" : addresses.join(", ")
        "#{address_text} ready=#{format_ready(endpoint.ready)}"
      end

      def format_ready(ready)
        ready.nil? ? "unknown" : ready.to_s
      end

      def format_host(host)
        host.nil? || host.empty? ? "(any)" : host
      end

      def format_path_type(path_type)
        path_type.nil? || path_type.empty? ? "(unset)" : path_type
      end

      def format_backend(backend)
        name = present(backend&.name)
        return "backend cannot be interpreted" if name.nil?

        port = backend_port(backend)
        if port
          "service #{name}:#{port}"
        else
          "service #{name} (backend port cannot be interpreted)"
        end
      end

      def backend_port(backend)
        return backend.port_number unless backend.port_number.nil?

        present(backend.port_name)
      end

      def present(value)
        value unless value.nil? || value.to_s.strip.empty?
      end
    end
  end
end
