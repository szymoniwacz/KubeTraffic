# frozen_string_literal: true

RSpec.describe KubeTraffic::Renderer::Human do
  def target
    KubeTraffic::Target.new(host: "api.example.com", path: "/users")
  end

  def backend
    KubeTraffic::Kubernetes::IngressServiceBackend.new(
      name: "api",
      port_number: 80,
      port_name: nil
    )
  end

  def ingress_match
    path = KubeTraffic::Kubernetes::IngressPath.new(
      path: "/users",
      path_type: "Prefix",
      backend: backend
    )
    rule = KubeTraffic::Kubernetes::IngressRule.new(host: "api.example.com", paths: [path])
    ingress = KubeTraffic::Kubernetes::Ingress.new(name: "api", namespace: "apps", rules: [rule])
    KubeTraffic::Resolver::Ingress::Match.new(ingress: ingress, rule: rule, path: path)
  end

  def service_port
    KubeTraffic::Kubernetes::ServicePort.new(
      name: "http",
      port: 80,
      target_port_number: 8080
    )
  end

  def mapped_service
    KubeTraffic::Kubernetes::Service.new(name: "api", namespace: "apps", ports: [service_port])
  end

  def service_result
    KubeTraffic::Resolver::Service::Result.new(service: mapped_service, port: service_port)
  end

  def endpoint
    KubeTraffic::Kubernetes::Endpoint.new(
      addresses: ["10.1.2.3"],
      ready: true,
      target_ref: KubeTraffic::Kubernetes::TargetRef.new(kind: "Pod", namespace: "apps", name: "api-abc")
    )
  end

  def endpoints
    slice = KubeTraffic::Kubernetes::EndpointSlice.new(
      name: "api-abc",
      namespace: "apps",
      service_name: "api",
      endpoints: [endpoint]
    )
    KubeTraffic::Resolver::EndpointSlice::Result.new(slices: [slice], endpoints: [endpoint])
  end

  def mapped_pod
    KubeTraffic::Kubernetes::Pod.new(
      name: "api-abc",
      namespace: "apps",
      ip: "10.1.2.3",
      phase: "Running",
      ready: true,
      containers: [
        KubeTraffic::Kubernetes::Container.new(
          name: "api",
          ports: [KubeTraffic::Kubernetes::ContainerPort.new(name: "http", container_port: 8080)]
        )
      ]
    )
  end

  def pods
    KubeTraffic::Resolver::Pod::Result.new(pods: [mapped_pod], missing: [])
  end

  def target_port
    KubeTraffic::Resolver::TargetPort::Result.new(number: 8080, name: nil, resolved: true)
  end

  def containers
    KubeTraffic::Resolver::Container.resolve([mapped_pod], target_port)
  end

  def trace(**overrides)
    KubeTraffic::Trace::Result.new(
      **{
        target: target,
        namespace: "apps",
        ingresses: [ingress_match.ingress],
        match: ingress_match,
        service: service_result,
        endpoints: endpoints,
        pods: pods,
        target_port: target_port,
        containers: containers,
        findings: []
      }.merge(overrides)
    )
  end

  it "renders an ordered successful trace with markers and a final result" do
    output = described_class.new.render(trace)

    expect(output).to include("Tracing api.example.com/users in namespace apps\n")
    expect(output).to include("[ok] Ingress api\n")
    expect(output).to include("[ok] Service api\n")
    expect(output).to include("[ok] EndpointSlice\n")
    expect(output).to include("[ok] Pod api-abc\n")
    expect(output).to include("[ok] Container api on Pod api-abc\n")
    expect(output).to include("declared containerPort is configuration, not proof a process is listening")
    expect(output).to include("Result: configuration chain complete\n")
    expect(output).not_to match(/\e\[/)
  end

  it "renders a failed Ingress step and a finding code in the result" do
    finding = KubeTraffic::Diagnostic::Finding.new(
      severity: :error,
      code: "ingress_not_found",
      summary: "No Ingress rule matches api.example.com/users in namespace apps",
      evidence: { namespace: "apps" }
    )
    output = described_class.new.render(
      trace(
        match: nil,
        service: nil,
        endpoints: nil,
        pods: nil,
        target_port: nil,
        containers: KubeTraffic::Resolver::Container::Result.new(matches: []),
        findings: [finding]
      )
    )

    expect(output).to include("[x] Ingress\n")
    expect(output).to include("     No Ingress rule matches api.example.com/users in namespace apps\n")
    expect(output).to include("Result: failed (ingress_not_found)\n")
    expect(output).not_to include("[ok]")
  end

  it "does not mark unmatched containerPort as a failed hop" do
    warning = KubeTraffic::Diagnostic::Finding.new(
      severity: :warning,
      code: "container_port_unmatched",
      summary: "No declared containerPort matches 8080",
      evidence: { target_port: 8080, pods: ["api-abc"] }
    )
    output = described_class.new.render(
      trace(
        containers: KubeTraffic::Resolver::Container::Result.new(matches: [], unmatched_pods: [mapped_pod]),
        findings: [warning]
      )
    )

    expect(output).to include("Warnings:\n     No declared containerPort matches 8080\n")
    expect(output).to include("Result: configuration chain complete\n")
    expect(output).not_to include("[x]")
  end

  it "does not mark missing Pod targetRef as a failed hop" do
    warning = KubeTraffic::Diagnostic::Finding.new(
      severity: :warning,
      code: "pod_target_ref_missing",
      summary: "Usable endpoints have no Pod targetRef",
      evidence: { endpoints: 1 }
    )
    output = described_class.new.render(
      trace(
        pods: KubeTraffic::Resolver::Pod::Result.new(pods: [], missing: []),
        findings: [warning]
      )
    )

    expect(output).not_to include("[x] Pod")
    expect(output).to include("Warnings:\n     Usable endpoints have no Pod targetRef\n")
    expect(output).to include("Result: configuration chain complete\n")
  end

  it "renders per-pod named targetPort mappings without collapsing them" do
    first = mapped_pod
    second = KubeTraffic::Kubernetes::Pod.new(
      name: "api-b",
      namespace: "apps",
      ip: "10.1.2.4",
      phase: "Running",
      ready: true,
      containers: [
        KubeTraffic::Kubernetes::Container.new(
          name: "api",
          ports: [KubeTraffic::Kubernetes::ContainerPort.new(name: "http", container_port: 9090)]
        )
      ]
    )
    named = KubeTraffic::Resolver::TargetPort::Result.new(
      name: "http",
      number: nil,
      resolved: true,
      mappings: [
        KubeTraffic::Resolver::TargetPort::Mapping.new(pod: first, number: 8080),
        KubeTraffic::Resolver::TargetPort::Mapping.new(pod: second, number: 9090)
      ]
    )
    named_port = KubeTraffic::Kubernetes::ServicePort.new(
      name: "http",
      port: 80,
      target_port_name: "http"
    )
    output = described_class.new.render(
      trace(
        service: KubeTraffic::Resolver::Service::Result.new(service: mapped_service, port: named_port),
        target_port: named,
        containers: KubeTraffic::Resolver::Container.resolve([first, second], named)
      )
    )

    expect(output).to include("[ok] Target port\n     named http\n     api-abc 8080\n     api-b 9090\n")
    expect(output).to include("Result: configuration chain complete\n")
    expect(output).not_to include("[x]")
  end

  it "fails the target port hop when a named port is unresolved" do
    finding = KubeTraffic::Diagnostic::Finding.new(
      severity: :error,
      code: "target_port_unresolved",
      summary: "Named targetPort http unresolved",
      evidence: { target_port: "http" }
    )
    named_port = KubeTraffic::Kubernetes::ServicePort.new(
      name: "http",
      port: 80,
      target_port_name: "http"
    )
    output = described_class.new.render(
      trace(
        service: KubeTraffic::Resolver::Service::Result.new(service: mapped_service, port: named_port),
        target_port: KubeTraffic::Resolver::TargetPort::Result.new(
          name: "http",
          number: nil,
          resolved: false,
          unresolved_pods: [mapped_pod]
        ),
        containers: KubeTraffic::Resolver::Container::Result.new(matches: []),
        findings: [finding]
      )
    )

    expect(output).to include("[x] Target port\n     Named targetPort http unresolved\n     api-abc (not declared)\n")
    expect(output).to include("Result: failed (target_port_unresolved)\n")
  end
end
