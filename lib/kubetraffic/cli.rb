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
      connect_to_cluster
      @stdout.puts "Tracing #{target}"
      0
    rescue TargetParser::Error, Kubernetes::Error => e
      @stderr.puts e.message
      1
    end

    def connect_to_cluster
      Kubernetes::Client.connect(context: @options[:context]).verify_connection!
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
        opts.on("--context CONTEXT", "Kubernetes context") do |context|
          @options[:context] = context
        end
      end
    end
  end
end
