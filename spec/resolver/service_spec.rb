# frozen_string_literal: true

RSpec.describe KubeTraffic::Resolver::Service do
  def service_backend(name, port_number: nil, port_name: nil)
    KubeTraffic::Kubernetes::IngressServiceBackend.new(
      name: name,
      port_number: port_number,
      port_name: port_name
    )
  end

  def service_port(port, name: nil)
    KubeTraffic::Kubernetes::ServicePort.new(name: name, port: port)
  end

  def service(*ports, name: "api", namespace: "apps")
    KubeTraffic::Kubernetes::Service.new(name: name, namespace: namespace, ports: ports)
  end

  def resolve(mapped_service, backend)
    described_class.resolve(mapped_service, backend)
  end

  it "resolves a numeric Ingress backend port against Service.port" do
    result = resolve(
      service(service_port(80, name: "http"), service_port(443, name: "https")),
      service_backend("api", port_number: 80)
    )

    expect(result.service.name).to eq("api")
    expect(result.port).to eq(service_port(80, name: "http"))
  end

  it "resolves a named Ingress backend port against Service.port name" do
    result = resolve(
      service(service_port(80, name: "http"), service_port(443, name: "https")),
      service_backend("api", port_name: "https")
    )

    expect(result.port).to eq(service_port(443, name: "https"))
  end

  it "does not treat a numeric backend as a port name" do
    result = resolve(
      service(service_port(80, name: "http")),
      service_backend("api", port_name: "80")
    )

    expect(result.service.name).to eq("api")
    expect(result.port).to be_nil
  end

  it "returns no Service when the Service is missing" do
    result = resolve(nil, service_backend("api", port_number: 80))

    expect(result.service).to be_nil
    expect(result.port).to be_nil
  end

  it "does not match an unmatched numeric Service port" do
    result = resolve(
      service(service_port(80), service_port(443, name: "https")),
      service_backend("api", port_number: 8080)
    )

    expect(result.service.name).to eq("api")
    expect(result.port).to be_nil
  end

  it "does not match an unmatched named Service port" do
    result = resolve(
      service(service_port(80, name: "http"), service_port(443, name: "https")),
      service_backend("api", port_name: "metrics")
    )

    expect(result.port).to be_nil
  end

  it "selects among multiple Service ports by the Ingress backend" do
    mapped = service(
      service_port(80, name: "http"),
      service_port(8080, name: "alt"),
      service_port(443, name: "https")
    )

    numeric = resolve(mapped, service_backend("api", port_number: 8080))
    named = resolve(mapped, service_backend("api", port_name: "https"))

    expect(numeric.port).to eq(service_port(8080, name: "alt"))
    expect(named.port).to eq(service_port(443, name: "https"))
  end

  it "does not invent a port when the Ingress backend port is missing" do
    result = resolve(
      service(service_port(80, name: "http")),
      service_backend("api")
    )

    expect(result.service.name).to eq("api")
    expect(result.port).to be_nil
  end
end
