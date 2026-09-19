# frozen_string_literal: true

RSpec.describe KubeTraffic::Resolver::EndpointSlice do
  def endpoint(*addresses, ready: true)
    KubeTraffic::Kubernetes::Endpoint.new(addresses: addresses, ready: ready)
  end

  def slice(name, service_name:, namespace: "apps", endpoints: [])
    KubeTraffic::Kubernetes::EndpointSlice.new(
      name: name,
      namespace: namespace,
      service_name: service_name,
      endpoints: endpoints
    )
  end

  def service(name: "api", namespace: "apps")
    KubeTraffic::Kubernetes::Service.new(name: name, namespace: namespace, ports: [])
  end

  def resolve(slices, mapped_service)
    described_class.resolve(slices, mapped_service)
  end

  it "associates EndpointSlices labeled for the Service" do
    matching = slice("api-abc", service_name: "api", endpoints: [endpoint("10.1.2.3")])
    other = slice("web-xyz", service_name: "web", endpoints: [endpoint("10.9.9.9")])

    result = resolve([other, matching], service)

    expect(result.slices.map(&:name)).to eq(["api-abc"])
    expect(result.endpoints).to eq([endpoint("10.1.2.3")])
  end

  it "does not associate slices from another namespace" do
    result = resolve(
      [slice("api-abc", service_name: "api", namespace: "other")],
      service
    )

    expect(result.slices).to eq([])
    expect(result.endpoints).to eq([])
  end

  it "returns no slices when the Service is missing" do
    result = resolve(
      [slice("api-abc", service_name: "api", endpoints: [endpoint("10.1.2.3")])],
      nil
    )

    expect(result.slices).to eq([])
    expect(result.endpoints).to eq([])
  end

  it "preserves slices that have no endpoints" do
    empty = slice("api-empty", service_name: "api")

    result = resolve([empty], service)

    expect(result.slices).to eq([empty])
    expect(result.endpoints).to eq([])
  end

  it "sorts associated slices by name" do
    result = resolve(
      [
        slice("api-b", service_name: "api", endpoints: [endpoint("10.0.0.2")]),
        slice("api-a", service_name: "api", endpoints: [endpoint("10.0.0.1")])
      ],
      service
    )

    expect(result.slices.map(&:name)).to eq(%w[api-a api-b])
  end
end
