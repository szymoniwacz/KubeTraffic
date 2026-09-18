# frozen_string_literal: true

require_relative "lib/kubetraffic/version"

Gem::Specification.new do |spec|
  spec.name = "kubetraffic"
  spec.version = KubeTraffic::VERSION
  spec.authors = ["Szymon Iwacz"]
  spec.email = ["szymon@iwacz.pl"]

  spec.summary = "Read-only CLI that traces HTTP request routing through Kubernetes."
  spec.description = spec.summary
  spec.homepage = "https://github.com/szymoniwacz/KubeTraffic"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |file|
      file.start_with?("spec/", ".git", ".github/")
    end
  end
  spec.bindir = "bin"
  spec.executables = ["kubetraffic"]
  spec.require_paths = ["lib"]
end
