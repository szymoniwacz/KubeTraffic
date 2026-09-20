# frozen_string_literal: true

RSpec.describe KubeTraffic::Diagnostic::Analyzer do
  def target(host = "api.example.com", path = "/users")
    KubeTraffic::Target.new(host: host, path: path)
  end

  def backend(name: "api", port_number: 80, port_name: nil)
    KubeTraffic::Kubernetes::IngressServiceBackend.new(
      name: name,
      port_number: port_number,
      port_name: port_name
    )
  end

  def match(backend: self.backend)
    path = KubeTraffic::Kubernetes::IngressPath.new(
      path: "/users",
      path_type: "Prefix",
      backend: backend
    )
    rule = KubeTraffic::Kubernetes::IngressRule.new(host: "api.example.com", paths: [path])
    ingress = KubeTraffic::Kubernetes::Ingress.new(name: "api", namespace: "apps", rules: [rule])
    KubeTraffic::Resolver::Ingress::Match.new(ingress: ingress, rule: rule, path: path)
  end

  def service_port(port = 80, name: "http", target_port_number: 8080, target_port_name: nil)
    KubeTraffic::Kubernetes::ServicePort.new(
      name: name,
      port: port,
      target_port_number: target_port_number,
      target_port_name: target_port_name
    )
  end

  def service_result(service: mapped_service, port: service_port)
    KubeTraffic::Resolver::Service::Result.new(service: service, port: port)
  end

  def mapped_service
    KubeTraffic::Kubernetes::Service.new(name: "api", namespace: "apps", ports: [service_port])
  end

  def endpoint(*addresses, ready: true, target_ref: nil)
    KubeTraffic::Kubernetes::Endpoint.new(addresses: addresses, ready: ready, target_ref: target_ref)
  end

  def pod_ref(name = "api-abc")
    KubeTraffic::Kubernetes::TargetRef.new(kind: "Pod", namespace: "apps", name: name)
  end

  def mapped_pod(name = "api-abc")
    KubeTraffic::Kubernetes::Pod.new(
      name: name,
      namespace: "apps",
      ip: "10.1.2.3",
      phase: "Running",
      ready: true,
      containers: []
    )
  end

  def slice(endpoints)
    KubeTraffic::Kubernetes::EndpointSlice.new(
      name: "api-abc",
      namespace: "apps",
      service_name: "api",
      endpoints: endpoints
    )
  end

  def endpoints(items: [endpoint("10.1.2.3")], slices: nil)
    mapped_slices = slices || [slice(items)]
    KubeTraffic::Resolver::EndpointSlice::Result.new(
      slices: mapped_slices,
      endpoints: mapped_slices.flat_map(&:endpoints)
    )
  end

  def pods(found: [], missing: [])
    KubeTraffic::Resolver::Pod::Result.new(pods: found, missing: missing)
  end

  def target_port(number: 8080, name: nil, resolved: true, mappings: [], unresolved_pods: [])
    KubeTraffic::Resolver::TargetPort::Result.new(
      name: name,
      number: number,
      resolved: resolved,
      mappings: mappings,
      unresolved_pods: unresolved_pods
    )
  end

  def containers(matches: [], unmatched_pods: [])
    KubeTraffic::Resolver::Container::Result.new(matches: matches, unmatched_pods: unmatched_pods)
  end

  def analyze(**overrides)
    described_class.new(
      **{
        target: target,
        namespace: "apps",
        ingresses: [match.ingress],
        match: match,
        service: service_result,
        endpoints: endpoints,
        pods: pods,
        target_port: target_port,
        containers: containers
      }.merge(overrides)
    ).findings
  end

  def codes(findings)
    findings.map(&:code)
  end

  it "reports ingress_not_found when no Ingress resources exist" do
    findings = analyze(ingresses: [], match: nil, service: nil, endpoints: nil, pods: nil, target_port: nil)

    expect(findings.size).to eq(1)
    expect(findings.first.code).to eq("ingress_not_found")
    expect(findings.first.severity).to eq(:error)
    expect(findings.first.summary).to eq("No Ingress resources in namespace apps")
    expect(findings.first.evidence).to eq(namespace: "apps")
  end

  it "reports ingress_not_found when no rule matches" do
    findings = analyze(
      match: nil,
      service: nil,
      endpoints: nil,
      pods: nil,
      target_port: nil
    )

    expect(codes(findings)).to eq(["ingress_not_found"])
    expect(findings.first.summary).to include("No Ingress rule matches")
  end

  it "reports service_not_found when the Service is missing" do
    findings = analyze(
      service: service_result(service: nil, port: nil),
      endpoints: nil,
      pods: nil,
      target_port: nil
    )

    expect(codes(findings)).to eq(["service_not_found"])
    expect(findings.first.evidence[:service]).to eq("api")
  end

  it "reports service_port_not_found when the Service port does not match" do
    findings = analyze(
      service: service_result(port: nil),
      endpoints: endpoints,
      pods: pods,
      target_port: nil
    )

    expect(codes(findings)).to include("service_port_not_found")
    expect(findings.find { |finding| finding.code == "service_port_not_found" }.summary)
      .to eq("no port matches 80")
  end

  it "reports service_no_endpoints when the Service has no EndpointSlices" do
    findings = analyze(
      endpoints: endpoints(slices: []),
      pods: pods,
      target_port: target_port
    )

    expect(codes(findings)).to eq(["service_no_endpoints"])
    expect(findings.first.evidence[:slices]).to eq(0)
  end

  it "reports endpoint_not_ready when endpoints exist but none are usable" do
    findings = analyze(
      endpoints: endpoints(items: [endpoint("10.1.2.4", ready: false)]),
      pods: pods,
      target_port: target_port
    )

    expect(codes(findings)).to eq(["endpoint_not_ready"])
    expect(findings.first.evidence[:not_ready]).to eq(1)
    expect(findings.first.evidence[:ready]).to eq(0)
  end

  it "reports pod_not_found for a missing targetRef Pod" do
    ref = pod_ref
    findings = analyze(
      endpoints: endpoints(items: [endpoint("10.1.2.3", target_ref: ref)]),
      pods: pods(missing: [ref])
    )

    expect(codes(findings)).to eq(["pod_not_found"])
    expect(findings.first.summary).to eq("Pod api-abc not found in namespace apps")
  end

  it "reports target_port_unresolved when a usable pod does not declare the named port" do
    unresolved = mapped_pod("api-b")
    findings = analyze(
      endpoints: endpoints(items: [endpoint("10.1.2.3", target_ref: pod_ref("api-b"))]),
      pods: pods(found: [unresolved]),
      target_port: target_port(number: nil, name: "http", resolved: false, unresolved_pods: [unresolved])
    )

    expect(codes(findings)).to eq(["target_port_unresolved"])
    expect(findings.first.summary).to eq("Named targetPort http unresolved")
  end

  it "does not report target_port_unresolved when no usable pods were inspected" do
    findings = analyze(
      endpoints: endpoints(items: [endpoint("10.1.2.3")]),
      target_port: target_port(number: nil, name: "http", resolved: true)
    )

    expect(codes(findings)).not_to include("target_port_unresolved")
  end

  it "warns when usable endpoints have no Pod targetRef" do
    findings = analyze(endpoints: endpoints(items: [endpoint("10.1.2.3")]))

    warning = findings.find { |finding| finding.code == "pod_target_ref_missing" }
    expect(warning.severity).to eq(:warning)
    expect(warning.summary).to eq("Usable endpoints have no Pod targetRef")
    expect(codes(findings)).not_to include("target_port_unresolved")
  end

  it "warns when a numeric targetPort has no matching containerPort" do
    unmatched = mapped_pod
    findings = analyze(
      endpoints: endpoints(items: [endpoint("10.1.2.3", target_ref: pod_ref)]),
      pods: pods(found: [unmatched]),
      containers: containers(unmatched_pods: [unmatched])
    )

    warning = findings.find { |finding| finding.code == "container_port_unmatched" }
    expect(warning.severity).to eq(:warning)
    expect(warning.summary).to eq("No declared containerPort matches 8080")
    expect(findings.select { |finding| finding.severity == :error }).to eq([])
  end

  it "emits no findings for a complete ready chain" do
    expect(
      analyze(
        endpoints: endpoints(items: [endpoint("10.1.2.3", target_ref: pod_ref)]),
        pods: pods(found: [mapped_pod])
      )
    ).to eq([])
  end
end
