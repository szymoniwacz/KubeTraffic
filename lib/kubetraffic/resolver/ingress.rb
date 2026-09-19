# frozen_string_literal: true

require_relative "../kubernetes/ingress"

module KubeTraffic
  module Resolver
    class Ingress
      Match = Data.define(:ingress, :rule, :path) do
        def backend
          path.backend
        end
      end

      PATH_TYPE_RANK = {
        "Exact" => 2,
        "Prefix" => 1,
        "ImplementationSpecific" => 0
      }.freeze

      def self.match(ingresses, target)
        new(ingresses).match(target)
      end

      def initialize(ingresses)
        @ingresses = Array(ingresses)
      end

      def match(target)
        candidates = matching_candidates(target)
        return nil if candidates.empty?

        candidates.min_by { |candidate| ranking(candidate) }
      end

      private

      def matching_candidates(target)
        @ingresses.flat_map do |ingress|
          Array(ingress.rules).flat_map do |rule|
            next [] unless host_matches?(rule.host, target.host)

            Array(rule.paths).filter_map do |path|
              next unless path_matches?(path, target.path)

              Match.new(ingress: ingress, rule: rule, path: path)
            end
          end
        end
      end

      def host_matches?(rule_host, target_host)
        return true if rule_host.nil? || rule_host.empty?

        rule = rule_host.downcase
        request = target_host.to_s.downcase
        return true if rule == request
        return false unless wildcard_host?(rule)

        suffix = rule[1..]
        return false unless request.end_with?(suffix)

        prefix = request.delete_suffix(suffix)
        !prefix.empty? && !prefix.include?(".")
      end

      def wildcard_host?(host)
        host.start_with?("*.") && !host[2..].include?("*")
      end

      def path_matches?(ingress_path, request_path)
        case ingress_path.path_type
        when "Prefix"
          prefix_matches?(ingress_path.path, request_path)
        when "Exact", "ImplementationSpecific", nil
          ingress_path.path == request_path
        else
          false
        end
      end

      def prefix_matches?(rule_path, request_path)
        rule_elements = path_elements(rule_path)
        return true if rule_elements.empty?

        request_elements = path_elements(request_path)
        return false if rule_elements.length > request_elements.length

        rule_elements == request_elements.take(rule_elements.length)
      end

      def path_elements(path)
        path.to_s.split("/").reject(&:empty?)
      end

      # Kubernetes uses the longest matching path among rules whose hosts
      # match. Remaining ties are unspecified; KubeTraffic then prefers
      # Exact over Prefix and finally Ingress name, host, and path. That
      # last step is a deterministic fallback, not Kubernetes routing
      # semantics, and does not rank exact hosts over wildcards or
      # catch-alls.
      def ranking(candidate)
        [
          -candidate.path.path.length,
          -path_type_rank(candidate.path.path_type),
          candidate.ingress.name.to_s,
          candidate.rule.host.to_s,
          candidate.path.path.to_s
        ]
      end

      def path_type_rank(path_type)
        PATH_TYPE_RANK.fetch(path_type, 0)
      end
    end
  end
end
