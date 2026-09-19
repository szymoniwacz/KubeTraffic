# frozen_string_literal: true

require "optparse"
require_relative "target_parser"
require_relative "kubernetes"
require_relative "resolver"
require_relative "trace"

module KubeTraffic
  class CLI
    def self.run(argv, stdout: $stdout, stderr: $stderr)
      new(argv, stdout: stdout, stderr: stderr).run
    end

    def initialize(argv, stdout:, stderr:)
      @argv = argv
      @stdout = stdout
      @stderr = stderr
      @options = {}
    end

    def run
      args = parser.parse!(@argv.dup)

      if @options[:version]
        @stdout.puts "KubeTraffic #{VERSION}"
        return 0
      end

      command = args.shift
      case command
      when "trace"
        trace(args)
      when nil
        usage(1)
      else
        @stderr.puts "unknown command: #{command}"
        usage(1)
      end
    rescue OptionParser::ParseError => e
      @stderr.puts e.message
      usage(1)
    end

    private

    def trace(args)
      raw = args.shift
      if raw.nil? || raw.empty?
        @stderr.puts "missing target"
        return usage(1)
      end

      if args.any?
        @stderr.puts "unexpected arguments: #{args.join(" ")}"
        return usage(1)
      end

      target = TargetParser.parse(raw)
      client = connect_to_cluster
      result = Trace::Builder.build(client, target)
      @stdout.puts "Tracing #{result.target} in namespace #{result.namespace}"
      print_ingress_match(result)
      print_service_match(result)
      print_endpoint_slices(result)
      print_pods(result)
      print_target_port(result)
      print_containers(result)
      0
    rescue TargetParser::Error, Kubernetes::Error => e
      @stderr.puts e.message
      1
    end

    def print_ingress_match(result)
      finding = finding_for(result, "ingress_not_found")
      if finding
        @stdout.puts finding.summary
        return
      end

      match = result.match
      @stdout.puts "Matched Ingress #{match.ingress.name}"
      @stdout.puts "  host #{format_host(match.rule.host)}"
      @stdout.puts "  path #{match.path.path}"
      @stdout.puts "  pathType #{format_path_type(match.path.path_type)}"
      @stdout.puts "  #{format_backend(match.backend)}"
    end

    def print_service_match(result)
      backend = result.match&.backend
      name = present(backend&.name)
      service_result = result.service
      return if name.nil? || service_result.nil?

      not_found = finding_for(result, "service_not_found")
      if not_found
        @stdout.puts not_found.summary
        return
      end

      @stdout.puts "Service #{service_result.service.name}"
      port_finding = finding_for(result, "service_port_not_found")
      if service_result.port
        @stdout.puts "  port #{format_service_port(service_result.port)}"
      else
        @stdout.puts "  #{port_finding ? port_finding.summary : unmatched_service_port(backend)}"
      end
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

    def print_endpoint_slices(result)
      service = result.service&.service
      endpoints = result.endpoints
      return if service.nil? || endpoints.nil?

      if endpoints.slices.empty?
        @stdout.puts "No EndpointSlices for Service #{service.name}"
        @stdout.puts finding_for(result, "service_no_endpoints").summary
        return
      end

      endpoints.slices.each do |slice|
        @stdout.puts "EndpointSlice #{slice.name}"
        if slice.endpoints.empty?
          @stdout.puts "  no endpoints"
          next
        end

        slice.endpoints.each do |endpoint|
          @stdout.puts "  #{format_endpoint(endpoint)}"
        end
      end

      print_endpoint_readiness(result)
    end

    def print_endpoint_readiness(result)
      service = result.service.service
      endpoints = result.endpoints
      no_endpoints = finding_for(result, "service_no_endpoints")
      not_ready = finding_for(result, "endpoint_not_ready")

      if endpoints.endpoints.empty?
        @stdout.puts "No endpoints for Service #{service.name}"
        @stdout.puts no_endpoints.summary
        return
      end

      @stdout.puts "  ready #{endpoints.ready_endpoints.size}"
      @stdout.puts "  not-ready #{endpoints.not_ready_endpoints.size}"
      @stdout.puts "  unknown readiness #{endpoints.unknown_readiness_endpoints.size}"
      @stdout.puts not_ready.summary if not_ready
    end

    def print_pods(result)
      endpoints = result.endpoints
      pods = result.pods
      return if endpoints.nil? || pods.nil?

      if endpoints.endpoints.any? && pods.pods.empty? && pods.missing.empty?
        @stdout.puts "No Pod target references"
        return
      end

      pods.pods.each do |pod|
        @stdout.puts "Pod #{pod.name}"
        @stdout.puts "  IP #{pod.ip || "(unknown)"}"
        @stdout.puts "  phase #{pod.phase || "(unknown)"}"
        @stdout.puts "  ready=#{format_ready(pod.ready)}"
      end

      findings_for(result, "pod_not_found").each do |finding|
        @stdout.puts finding.summary
      end
    end

    def print_target_port(result)
      port = result.service&.port
      return if port.nil?

      target = result.target_port
      if !port.target_port_number.nil?
        @stdout.puts "Target port #{port.target_port_number}"
        return
      end

      name = present(port.target_port_name)
      return if name.nil?

      unresolved = finding_for(result, "target_port_unresolved")
      if target&.resolved
        @stdout.puts "Target port named #{name}"
        Array(target.mappings).each do |mapping|
          @stdout.puts "  #{mapping.pod.name} #{mapping.number}"
        end
      else
        @stdout.puts unresolved ? unresolved.summary : "Named targetPort #{name} unresolved"
        Array(target&.mappings).each do |mapping|
          @stdout.puts "  #{mapping.pod.name} #{mapping.number}"
        end
        Array(target&.unresolved_pods).each do |pod|
          @stdout.puts "  #{pod.name} (not declared)"
        end
      end
    end

    def print_containers(result)
      return if result.service&.port.nil?

      target = result.target_port
      return unless target&.resolved

      containers = result.containers
      if containers.matches.empty?
        return if target.number.nil?

        @stdout.puts "No declared containerPort matches #{target.number}"
      else
        containers.matches.each do |match|
          @stdout.puts "Container #{match.container.name} on Pod #{match.pod.name}"
          @stdout.puts "  port #{format_container_port(match.port)}"
        end
      end
      @stdout.puts Resolver::Container::LISTENING_LIMITATION
    end

    def format_container_port(port)
      name = present(port.name)
      name ? "#{port.container_port} name #{name}" : port.container_port.to_s
    end

    def finding_for(result, code)
      findings_for(result, code).first
    end

    def findings_for(result, code)
      result.findings.select { |finding| finding.code == code }
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

    def connect_to_cluster
      client = Kubernetes::Client.connect(
        context: @options[:context],
        namespace: @options[:namespace]
      )
      client.verify_connection!
      client
    end

    def usage(status)
      @stderr.puts parser
      status
    end

    def parser
      @parser ||= OptionParser.new do |opts|
        opts.banner = "Usage: kubetraffic [options] [COMMAND]"
        opts.on("-v", "--version", "Print version") do
          @options[:version] = true
        end
        opts.on("-n", "--namespace NAME", "Kubernetes namespace") do |namespace|
          @options[:namespace] = namespace
        end
        opts.on("--context CONTEXT", "Kubernetes context") do |context|
          @options[:context] = context
        end
      end
    end
  end
end
