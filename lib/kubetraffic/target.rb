# frozen_string_literal: true

module KubeTraffic
  Target = Data.define(:host, :path) do
    def to_s
      "#{host}#{path}"
    end
  end
end
