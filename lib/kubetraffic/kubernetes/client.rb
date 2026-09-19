# frozen_string_literal: true

require_relative "errors"

module KubeTraffic
  module Kubernetes
    class Client
      DEFAULT_KUBECONFIG = File.join(Dir.home, ".kube", "config").freeze

      def self.connect(context: nil, kubeconfig: nil)
        new(context: context, kubeconfig: kubeconfig)
      end

      def initialize(context: nil, kubeconfig: nil, api: nil)
        @api = api || build_api(context: context, kubeconfig: kubeconfig)
      end

      def verify_connection!
        require "kubeclient"

        @api.api
        true
      rescue Kubeclient::HttpError => e
        raise mapped_http_error(e)
      rescue Kubernetes::Error
        raise
      rescue StandardError => e
        raise ConnectionError, "unable to connect to the Kubernetes API: #{e.message}"
      end

      private

      def build_api(context:, kubeconfig:)
        require "kubeclient"

        path = resolve_kubeconfig(kubeconfig)
        unless File.file?(path)
          raise ConfigError, "kubeconfig not found: #{path}"
        end

        config = load_config(path)
        kube_context = select_context(config, context)

        Kubeclient::Client.new(
          kube_context.api_endpoint,
          "v1",
          ssl_options: kube_context.ssl_options,
          auth_options: kube_context.auth_options
        )
      end

      def resolve_kubeconfig(explicit)
        raw = present(explicit) || present(ENV["KUBECONFIG"]) || DEFAULT_KUBECONFIG
        raw.split(File::PATH_SEPARATOR).find { |entry| !entry.empty? } || DEFAULT_KUBECONFIG
      end

      def present(value)
        value unless value.nil? || value.to_s.strip.empty?
      end

      def load_config(path)
        Kubeclient::Config.read(path)
      rescue StandardError => e
        raise ConfigError, "unable to load kubeconfig #{path}: #{e.message}"
      end

      def select_context(config, context)
        if context
          config.context(context)
        else
          config.context
        end
      rescue KeyError
        name = context || "current-context"
        raise ConfigError, "kubernetes context not found: #{name.inspect}"
      end

      def mapped_http_error(error)
        if [401, 403].include?(error.error_code.to_i)
          AuthorizationError.new(
            "not authorized to access the Kubernetes API: #{error.message}"
          )
        else
          ConnectionError.new(
            "unable to connect to the Kubernetes API: #{error.message}"
          )
        end
      end
    end
  end
end
