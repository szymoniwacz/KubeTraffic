# frozen_string_literal: true

require "optparse"
require_relative "target_parser"
require_relative "kubernetes"

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
      @stdout.puts "Tracing #{target} in namespace #{client.namespace}"
      print_ingress_candidates(ingresses, client.namespace)
      0
    rescue TargetParser::Error, Kubernetes::Error => e
      @stderr.puts e.message
      1
    end

    def print_ingress_candidates(ingresses, namespace)
      if ingresses.empty?
        @stdout.puts "No Ingress resources in namespace #{namespace}"
        return
      end

      @stdout.puts "Ingress candidates:"
      ingresses.each do |ingress|
        @stdout.puts "  #{ingress.name}"
      end
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
