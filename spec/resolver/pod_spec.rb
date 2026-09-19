# frozen_string_literal: true

RSpec.describe KubeTraffic::Resolver::Pod do
  def target_ref(name, kind: "Pod", namespace: "apps")
    KubeTraffic::Kubernetes::TargetRef.new(kind: kind, namespace: namespace, name: name)
  end

  def endpoint(*addresses, ready: true, target_ref: nil)
    KubeTraffic::Kubernetes::Endpoint.new(addresses: addresses, ready: ready, target_ref: target_ref)
  end

  def mapped_pod(name, namespace: "apps", ip: "10.1.2.3", phase: "Running", ready: true)
    KubeTraffic::Kubernetes::Pod.new(
      name: name,
      namespace: namespace,
      ip: ip,
      phase: phase,
      ready: ready
    )
  end

  def client_with(pods)
    client = instance_double(KubeTraffic::Kubernetes::Client)
    allow(client).to receive(:get_pod) do |name, namespace: nil|
      pods[[namespace, name]]
    end
    client
  end

  it "resolves Pod target references" do
    pod = mapped_pod("api-abc")
    client = client_with({ ["apps", "api-abc"] => pod })

    result = described_class.resolve(
      [endpoint("10.1.2.3", target_ref: target_ref("api-abc"))],
      client
    )

    expect(result.pods).to eq([pod])
    expect(result.missing).to eq([])
  end

  it "does not invent a Pod when targetRef is missing" do
    client = instance_double(KubeTraffic::Kubernetes::Client)
    expect(client).not_to receive(:get_pod)

    result = described_class.resolve([endpoint("10.1.2.3")], client)

    expect(result.pods).to eq([])
    expect(result.missing).to eq([])
  end

  it "ignores non-Pod target references" do
    client = instance_double(KubeTraffic::Kubernetes::Client)
    expect(client).not_to receive(:get_pod)

    result = described_class.resolve(
      [endpoint("10.1.2.3", target_ref: target_ref("node-1", kind: "Node"))],
      client
    )

    expect(result.pods).to eq([])
  end

  it "records missing Pods named by targetRef" do
    client = client_with({})
    ref = target_ref("api-abc")

    result = described_class.resolve([endpoint("10.1.2.3", target_ref: ref)], client)

    expect(result.pods).to eq([])
    expect(result.missing).to eq([ref])
  end

  it "fetches a Pod once when several endpoints share the same targetRef" do
    pod = mapped_pod("api-abc")
    client = instance_double(KubeTraffic::Kubernetes::Client)
    expect(client).to receive(:get_pod).with("api-abc", namespace: "apps").once.and_return(pod)

    result = described_class.resolve(
      [
        endpoint("10.1.2.3", target_ref: target_ref("api-abc")),
        endpoint("10.1.2.3", ready: false, target_ref: target_ref("api-abc"))
      ],
      client
    )

    expect(result.pods).to eq([pod])
  end
end
