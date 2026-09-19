# frozen_string_literal: true

require_relative "errors"
require_relative "ingress"

module KubeTraffic
  module Kubernetes
    class Client
      DEFAULT_KUBECONFIG = File.join(Dir.home, ".kube", "config").freeze
      DEFAULT_NAMESPACE = "default"

      attr_reader :namespace

      def self.connect(context: nil, kubeconfig: nil, namespace: nil)
        new(context: context, kubeconfig: kubeconfig, namespace: namespace)
      end

      def initialize(context: nil, kubeconfig: nil, api: nil, networking_api: nil, namespace: nil)
        kube_context = nil
        @api = api || begin
          kube_context = load_kube_context(context: context, kubeconfig: kubeconfig)
          build_api(kube_context)
        end
        @networking_api = networking_api || (kube_context && build_networking_api(kube_context))
        @namespace = resolve_namespace(namespace, kube_context)
      end

      def verify_connection!
        with_mapped_errors do
          @api.api
          true
        end
      end

      def list_ingresses
        with_mapped_errors do
          resources = networking_api.get_ingresses(namespace: namespace)
          Array(resources).map { |resource| map_ingress(resource) }.sort_by(&:name)
        end
      end

      private

      def load_kube_context(context:, kubeconfig:)
        require "kubeclient"

        path = resolve_kubeconfig(kubeconfig)
        unless File.file?(path)
          raise ConfigError, "kubeconfig not found: #{path}"
        end

        config = load_config(path)
        select_context(config, context)
      end

      def build_api(kube_context)
        require "kubeclient"

        Kubeclient::Client.new(
          kube_context.api_endpoint,
          "v1",
          ssl_options: kube_context.ssl_options,
          auth_options: kube_context.auth_options
        )
      end

      def build_networking_api(kube_context)
        require "kubeclient"

        Kubeclient::Client.new(
          "#{kube_context.api_endpoint}/apis/networking.k8s.io",
          "v1",
          ssl_options: kube_context.ssl_options,
          auth_options: kube_context.auth_options
        )
      end

      def networking_api
        @networking_api or raise ConnectionError, "networking.k8s.io client is not configured"
      end

      def map_ingress(resource)
        metadata = resource.metadata
        Ingress.new(
          name: metadata.name,
          namespace: present(metadata.namespace) || namespace,
          rules: Array(resource.spec&.rules).map { |rule| map_rule(rule) }
        )
      end

      def map_rule(rule)
        IngressRule.new(
          host: present(rule.host),
          paths: Array(rule.http&.paths).map { |http_path| map_path(http_path) }
        )
      end

      def map_path(http_path)
        IngressPath.new(
          path: present(http_path.path) || "/",
          path_type: present(http_path.pathType) || "ImplementationSpecific"
        )
      end

      def with_mapped_errors
        require "kubeclient"

        yield
      rescue Kubeclient::HttpError => e
        raise mapped_http_error(e)
      rescue Kubernetes::Error
        raise
      rescue StandardError => e
        raise ConnectionError, "unable to connect to the Kubernetes API: #{e.message}"
      end

      def resolve_namespace(explicit, kube_context)
        if !explicit.nil?
          name = explicit.to_s.strip
          raise ConfigError, "namespace must not be empty" if name.empty?

          return name
        end

        present(kube_context&.namespace) || DEFAULT_NAMESPACE
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
          ApiError.new(
            "Kubernetes API error: #{error.message}"
          )
        end
      end
    end
  end
end
