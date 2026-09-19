# frozen_string_literal: true

require_relative "errors"
require_relative "ingress"
require_relative "service"
require_relative "endpoint_slice"
require_relative "pod"

module KubeTraffic
  module Kubernetes
    class Client
      DEFAULT_KUBECONFIG = File.join(Dir.home, ".kube", "config").freeze
      DEFAULT_NAMESPACE = "default"
      SERVICE_NAME_LABEL = "kubernetes.io/service-name"

      attr_reader :namespace

      def self.connect(context: nil, kubeconfig: nil, namespace: nil)
        new(context: context, kubeconfig: kubeconfig, namespace: namespace)
      end

      def initialize(context: nil, kubeconfig: nil, api: nil, networking_api: nil, discovery_api: nil, namespace: nil)
        kube_context = nil
        @api = api || begin
          kube_context = load_kube_context(context: context, kubeconfig: kubeconfig)
          build_api(kube_context)
        end
        @networking_api = networking_api || (kube_context && build_networking_api(kube_context))
        @discovery_api = discovery_api || (kube_context && build_discovery_api(kube_context))
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

      def get_service(name)
        service_name = present(name)
        return nil if service_name.nil?

        with_mapped_errors do
          map_service(@api.get_service(service_name, namespace))
        rescue Kubeclient::HttpError => e
          return nil if not_found?(e)

          raise
        end
      end

      def list_endpoint_slices(service_name)
        name = present(service_name)
        return [] if name.nil?

        with_mapped_errors do
          resources = discovery_api.get_endpoint_slices(
            namespace: namespace,
            label_selector: "#{SERVICE_NAME_LABEL}=#{name}"
          )
          Array(resources).map { |resource| map_endpoint_slice(resource) }.sort_by(&:name)
        end
      end

      def get_pod(name, namespace: nil)
        pod_name = present(name)
        return nil if pod_name.nil?

        pod_namespace = present(namespace) || self.namespace

        with_mapped_errors do
          map_pod(@api.get_pod(pod_name, pod_namespace))
        rescue Kubeclient::HttpError => e
          return nil if not_found?(e)

          raise
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

      def build_discovery_api(kube_context)
        require "kubeclient"

        Kubeclient::Client.new(
          "#{kube_context.api_endpoint}/apis/discovery.k8s.io",
          "v1",
          ssl_options: kube_context.ssl_options,
          auth_options: kube_context.auth_options
        )
      end

      def networking_api
        @networking_api or raise ConnectionError, "networking.k8s.io client is not configured"
      end

      def discovery_api
        @discovery_api or raise ConnectionError, "discovery.k8s.io client is not configured"
      end

      def not_found?(error)
        error.error_code.to_i == 404
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
          path_type: present(http_path.pathType),
          backend: map_service_backend(http_path.backend)
        )
      end

      # networking.k8s.io/v1 HTTPIngressPath backends may reference a
      # Service or a typed resource. KubeTraffic only preserves a Service
      # name plus named or numeric port. Missing or non-Service backends
      # stay nil rather than inventing a default name or port 80.
      def map_service_backend(backend)
        service = backend&.service
        name = present(service&.name)
        return nil if name.nil?

        port = service.port
        IngressServiceBackend.new(
          name: name,
          port_number: integer_port(port&.number),
          port_name: present(port&.name)
        )
      end

      # Core v1 Service mapping keeps identity and spec.ports needed to
      # match an Ingress backend. targetPort is left unmapped until that
      # resolution exists.
      def map_service(resource)
        metadata = resource.metadata
        Service.new(
          name: metadata.name,
          namespace: present(metadata.namespace) || namespace,
          ports: Array(resource.spec&.ports).filter_map { |port| map_service_port(port) }
        )
      end

      def map_service_port(port)
        number = integer_port(port.port)
        return nil if number.nil?

        ServicePort.new(
          name: present(port.name),
          port: number
        )
      end

      def map_endpoint_slice(resource)
        metadata = resource.metadata
        EndpointSlice.new(
          name: metadata.name,
          namespace: present(metadata.namespace) || namespace,
          service_name: label_value(metadata.labels, SERVICE_NAME_LABEL),
          endpoints: Array(resource.endpoints).map { |endpoint| map_endpoint(endpoint) }
        )
      end

      def map_endpoint(endpoint)
        Endpoint.new(
          addresses: Array(endpoint.addresses).filter_map { |address| present(address) }.sort,
          ready: boolean_or_nil(endpoint.conditions&.ready),
          target_ref: map_target_ref(endpoint.targetRef)
        )
      end

      def map_target_ref(ref)
        return nil if ref.nil?

        name = present(ref.name)
        kind = present(ref.kind)
        return nil if name.nil? || kind.nil?

        TargetRef.new(
          kind: kind,
          namespace: present(ref.namespace),
          name: name
        )
      end

      def map_pod(resource)
        metadata = resource.metadata
        status = resource.status
        Pod.new(
          name: metadata.name,
          namespace: present(metadata.namespace) || namespace,
          ip: present(status&.podIP),
          phase: present(status&.phase),
          ready: pod_ready?(status)
        )
      end

      def pod_ready?(status)
        conditions = Array(status&.conditions)
        ready = conditions.find { |condition| present(condition.type) == "Ready" }
        return nil if ready.nil?

        boolean_or_nil(ready.status)
      end

      def label_value(labels, key)
        return nil if labels.nil?

        value = labels[key] || labels[key.to_sym]
        present(value)
      end

      def boolean_or_nil(value)
        return nil if value.nil?

        value == true || value.to_s.downcase == "true"
      end

      def integer_port(value)
        return nil if value.nil? || value.to_s.strip.empty?

        Integer(value)
      rescue ArgumentError, TypeError
        nil
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
