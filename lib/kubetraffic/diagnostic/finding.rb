# frozen_string_literal: true

module KubeTraffic
  module Diagnostic
    Finding = Data.define(:severity, :code, :summary, :evidence) do
      def initialize(severity:, code:, summary:, evidence: {})
        super
      end
    end
  end
end
