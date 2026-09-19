# frozen_string_literal: true

RSpec.describe KubeTraffic::Resolver::Container do
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

  def numeric_target(number, resolved: true)
    KubeTraffic::Resolver::TargetPort::Result.new(name: nil, number: number, resolved: resolved)
  end

  def named_target(*mappings, name: "http", resolved: true)
    KubeTraffic::Resolver::TargetPort::Result.new(
      name: name,
      number: nil,
      resolved: resolved,
      mappings: mappings
    )
  end

  def mapping(mapped, number)
    KubeTraffic::Resolver::TargetPort::Mapping.new(pod: mapped, number: number)
  end

  it "matches a numeric targetPort to a declared containerPort" do
    mapped = pod(container("api", container_port(8080, name: "http")))
    result = described_class.resolve([mapped], numeric_target(8080))

    expect(result.matches.map { |match| [match.container.name, match.port.container_port] })
      .to eq([["api", 8080]])
    expect(result.unmatched_pods).to eq([])
  end

  it "records pods whose declared ports do not match a numeric targetPort" do
    mapped = pod(container("api", container_port(9090, name: "http")))
    result = described_class.resolve([mapped], numeric_target(8080))

    expect(result.matches).to eq([])
    expect(result.unmatched_pods).to eq([mapped])
  end

  it "matches named targetPort mappings using each pod's own number" do
    first = pod(container("api", container_port(8080, name: "http")), name: "api-a")
    second = pod(container("api", container_port(9090, name: "http")), name: "api-b")
    result = described_class.resolve(
      [first, second],
      named_target(mapping(first, 8080), mapping(second, 9090))
    )

    expect(result.matches.map { |match| [match.pod.name, match.port.container_port] })
      .to eq([["api-a", 8080], ["api-b", 9090]])
    expect(result.unmatched_pods).to eq([])
  end

  it "matches a named targetPort only when the container port name matches" do
    mapped = pod(
      container("api", container_port(8080, name: "http"), container_port(8080, name: "alt"))
    )
    result = described_class.resolve([mapped], named_target(mapping(mapped, 8080)))

    expect(result.matches.map { |match| match.port.name }).to eq(["http"])
  end

  it "returns no match when the targetPort was not resolved" do
    mapped = pod(container("api", container_port(8080, name: "http")))
    result = described_class.resolve(
      [mapped],
      named_target(name: "http", resolved: false)
    )

    expect(result.matches).to eq([])
    expect(result.unmatched_pods).to eq([])
  end
end
