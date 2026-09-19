# frozen_string_literal: true

require "tempfile"
require "kubeclient"

RSpec.describe KubeTraffic::Kubernetes::Client do
  def write_kubeconfig(current_context: "test", extra_contexts: [])
    file = Tempfile.new(["kubeconfig", ".yml"])
    file.write(<<~YAML)
      apiVersion: v1
      kind: Config
      current-context: #{current_context}
      contexts:
      - name: test
        context:
          cluster: test
          user: test
      #{extra_contexts.join}
      clusters:
      - name: test
        cluster:
          server: https://kube.example.test
      users:
      - name: test
        user:
          token: fake-token
    YAML
    file.flush
    file
  end

  def http_error(code, message)
    Kubeclient::HttpError.new(code, message, nil)
  end

  around do |example|
    original = ENV["KUBECONFIG"]
    example.run
  ensure
    if original.nil?
      ENV.delete("KUBECONFIG")
    else
      ENV["KUBECONFIG"] = original
    end
  end

  it "loads kubeconfig and builds a core v1 client for the current context" do
    kubeconfig = write_kubeconfig
    api = instance_double(Kubeclient::Client)
    expect(Kubeclient::Client).to receive(:new).with(
      "https://kube.example.test",
      "v1",
      hash_including(
        ssl_options: hash_including(:verify_ssl),
        auth_options: hash_including(bearer_token: "fake-token")
      )
    ).and_return(api)

    ENV["KUBECONFIG"] = kubeconfig.path
    described_class.connect

    kubeconfig.close!
  end

  it "uses an explicit kubeconfig path and named context" do
    kubeconfig = write_kubeconfig(
      current_context: "other",
      extra_contexts: [
        <<~YAML
          - name: staging
            context:
              cluster: test
              user: test
        YAML
      ]
    )
    api = instance_double(Kubeclient::Client)
    expect(Kubeclient::Client).to receive(:new).and_return(api)

    described_class.connect(context: "staging", kubeconfig: kubeconfig.path)

    kubeconfig.close!
  end

  it "raises when kubeconfig is missing" do
    ENV.delete("KUBECONFIG")
    path = File.join(Dir.tmpdir, "kubetraffic-missing-kubeconfig")

    expect {
      described_class.connect(kubeconfig: path)
    }.to raise_error(
      KubeTraffic::Kubernetes::ConfigError,
      "kubeconfig not found: #{path}"
    )
  end

  it "raises when the named context is missing" do
    kubeconfig = write_kubeconfig

    expect {
      described_class.connect(context: "missing", kubeconfig: kubeconfig.path)
    }.to raise_error(
      KubeTraffic::Kubernetes::ConfigError,
      'kubernetes context not found: "missing"'
    )

    kubeconfig.close!
  end

  it "verifies connectivity through the wrapped API client" do
    api = instance_double(Kubeclient::Client)
    expect(api).to receive(:api).and_return({ "versions" => ["v1"] })

    expect(described_class.new(api: api).verify_connection!).to eq(true)
  end

  it "maps unauthorized responses" do
    api = instance_double(Kubeclient::Client)
    allow(api).to receive(:api).and_raise(http_error(401, "Unauthorized"))

    expect {
      described_class.new(api: api).verify_connection!
    }.to raise_error(
      KubeTraffic::Kubernetes::AuthorizationError,
      /not authorized to access the Kubernetes API/
    )
  end

  it "maps forbidden responses" do
    api = instance_double(Kubeclient::Client)
    allow(api).to receive(:api).and_raise(http_error(403, "Forbidden"))

    expect {
      described_class.new(api: api).verify_connection!
    }.to raise_error(
      KubeTraffic::Kubernetes::AuthorizationError,
      /not authorized to access the Kubernetes API/
    )
  end

  it "maps other API errors as connection failures" do
    api = instance_double(Kubeclient::Client)
    allow(api).to receive(:api).and_raise(http_error(500, "Internal error"))

    expect {
      described_class.new(api: api).verify_connection!
    }.to raise_error(
      KubeTraffic::Kubernetes::ConnectionError,
      /unable to connect to the Kubernetes API/
    )
  end

  it "maps low-level network errors as connection failures" do
    api = instance_double(Kubeclient::Client)
    allow(api).to receive(:api).and_raise(Errno::ECONNREFUSED)

    expect {
      described_class.new(api: api).verify_connection!
    }.to raise_error(
      KubeTraffic::Kubernetes::ConnectionError,
      /unable to connect to the Kubernetes API/
    )
  end

  it "raises when kubeconfig cannot be parsed" do
    kubeconfig = Tempfile.new(["kubeconfig", ".yml"])
    kubeconfig.write("not: valid: kubeconfig: [")
    kubeconfig.flush

    expect {
      described_class.connect(kubeconfig: kubeconfig.path)
    }.to raise_error(
      KubeTraffic::Kubernetes::ConfigError,
      /unable to load kubeconfig/
    )
  ensure
    kubeconfig.close!
  end
end
