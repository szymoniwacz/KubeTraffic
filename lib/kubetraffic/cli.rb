# frozen_string_literal: true

require "optparse"
require_relative "target_parser"
require_relative "kubernetes"
require_relative "resolver"

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
      ingresses = client.list_ingresses
      match = Resolver::Ingress.match(ingresses, target)
      service_result = resolve_service(match, client)
      @stdout.puts "Tracing #{target} in namespace #{client.namespace}"
      print_ingress_match(match, ingresses, target, client.namespace)
      print_service_match(match, service_result, client.namespace)
      0
    rescue TargetParser::Error, Kubernetes::Error => e
      @stderr.puts e.message
      1
    end

    def print_ingress_match(match, ingresses, target, namespace)
      if ingresses.empty?
        @stdout.puts "No Ingress resources in namespace #{namespace}"
        return
      end

      if match.nil?
        @stdout.puts "No Ingress rule matches #{target} in namespace #{namespace}"
        return
      end

      @stdout.puts "Matched Ingress #{match.ingress.name}"
      @stdout.puts "  host #{format_host(match.rule.host)}"
      @stdout.puts "  path #{match.path.path}"
      @stdout.puts "  pathType #{format_path_type(match.path.path_type)}"
      @stdout.puts "  #{format_backend(match.backend)}"
    end

    def resolve_service(match, client)
      backend = match&.backend
      name = present(backend&.name)
      return nil if name.nil?

      Resolver::Service.resolve(client.get_service(name), backend)
    end

    def print_service_match(match, result, namespace)
      backend = match&.backend
      name = present(backend&.name)
      return if name.nil? || result.nil?

      if result.service.nil?
        @stdout.puts "Service #{name} not found in namespace #{namespace}"
        return
      end

      @stdout.puts "Service #{result.service.name}"
      if result.port
        @stdout.puts "  port #{format_service_port(result.port)}"
      else
        @stdout.puts "  #{unmatched_service_port(backend)}"
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
