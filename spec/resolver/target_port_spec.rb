# frozen_string_literal: true

RSpec.describe KubeTraffic::Resolver::TargetPort do
  def service_port(port, name: "http", target_port_number: nil, target_port_name: nil)
    KubeTraffic::Kubernetes::ServicePort.new(
      name: name,
      port: port,
      target_port_number: target_port_number,
      target_port_name: target_port_name
    )
  end

  def container_port(number, name: nil)
    KubeTraffic::Kubernetes::ContainerPort.new(name: name, container_port: number)
  end

  def container(name, *ports)
    KubeTraffic::Kubernetes::Container.new(name: name, ports: ports)
  end

  def pod(*containers, name: "api-abc")
    KubeTraffic::Kubernetes::Pod.new(
      name: name,
      namespace: "apps",
      ip: "10.1.2.3",
      phase: "Running",
      ready: true,
      containers: containers
    )
  end

  it "resolves a numeric targetPort without inspecting Pods" do
    result = described_class.resolve(service_port(80, target_port_number: 8080), [])

    expect(result.resolved).to eq(true)
    expect(result.number).to eq(8080)
    expect(result.name).to be_nil
    expect(result.mappings).to eq([])
  end

  it "resolves a named targetPort from a Pod container port" do
    mapped = pod(container("api", container_port(8080, name: "http")))

    result = described_class.resolve(service_port(80, target_port_name: "http"), [mapped])

    expect(result.resolved).to eq(true)
    expect(result.number).to be_nil
    expect(result.name).to eq("http")
    expect(result.mappings.map { |mapping| [mapping.pod.name, mapping.number] }).to eq([["api-abc", 8080]])
    expect(result.unresolved_pods).to eq([])
  end

  it "does not resolve a named targetPort missing from Pod containers" do
    mapped = pod(container("api", container_port(8080, name: "metrics")))

    result = described_class.resolve(service_port(80, target_port_name: "http"), [mapped])

    expect(result.resolved).to eq(false)
    expect(result.number).to be_nil
    expect(result.name).to eq("http")
    expect(result.mappings).to eq([])
    expect(result.unresolved_pods).to eq([mapped])
  end

  it "does not treat an empty pod list as an unresolved named targetPort" do
    result = described_class.resolve(service_port(80, target_port_name: "http"), [])

    expect(result.resolved).to eq(true)
    expect(result.name).to eq("http")
    expect(result.number).to be_nil
    expect(result.mappings).to eq([])
    expect(result.unresolved_pods).to eq([])
  end

  it "does not resolve a pod whose named port maps to multiple numbers" do
    mapped = pod(
      container("api", container_port(8080, name: "http")),
      container("sidecar", container_port(9090, name: "http"))
    )

    result = described_class.resolve(service_port(80, target_port_name: "http"), [mapped])

    expect(result.resolved).to eq(false)
    expect(result.unresolved_pods).to eq([mapped])
  end

  it "resolves a named targetPort to different numbers on different pods" do
    first = pod(container("api", container_port(8080, name: "http")), name: "api-a")
    second = pod(container("api", container_port(9090, name: "http")), name: "api-b")

    result = described_class.resolve(service_port(80, target_port_name: "http"), [first, second])

    expect(result.resolved).to eq(true)
    expect(result.number).to be_nil
    expect(result.mappings.map { |mapping| [mapping.pod.name, mapping.number] })
      .to eq([["api-a", 8080], ["api-b", 9090]])
  end

  it "leaves a named targetPort unresolved when one inspected pod is missing the name" do
    first = pod(container("api", container_port(8080, name: "http")), name: "api-a")
    second = pod(container("api", container_port(9090, name: "metrics")), name: "api-b")

    result = described_class.resolve(service_port(80, target_port_name: "http"), [first, second])

    expect(result.resolved).to eq(false)
    expect(result.mappings.map { |mapping| [mapping.pod.name, mapping.number] }).to eq([["api-a", 8080]])
    expect(result.unresolved_pods.map(&:name)).to eq(["api-b"])
  end
end
