# frozen_string_literal: true

RSpec.describe KubeTraffic::Resolver::Ingress do
  def path(value, type, backend: nil)
    KubeTraffic::Kubernetes::IngressPath.new(path: value, path_type: type, backend: backend)
  end

  def service_backend(name, port_number: nil, port_name: nil)
    KubeTraffic::Kubernetes::IngressServiceBackend.new(
      name: name,
      port_number: port_number,
      port_name: port_name
    )
  end

  def rule(host, *paths)
    KubeTraffic::Kubernetes::IngressRule.new(host: host, paths: paths)
  end

  def ingress(name, *rules, namespace: "default")
    KubeTraffic::Kubernetes::Ingress.new(name: name, namespace: namespace, rules: rules)
  end

  def target(host, request_path)
    KubeTraffic::Target.new(host: host, path: request_path)
  end

  def match(ingresses, host, request_path)
    described_class.match(ingresses, target(host, request_path))
  end

  describe "host matching" do
    it "matches an exact host" do
      selected = match(
        [ingress("api", rule("api.example.com", path("/users", "Prefix")))],
        "api.example.com",
        "/users"
      )

      expect(selected.ingress.name).to eq("api")
      expect(selected.rule.host).to eq("api.example.com")
    end

    it "matches hosts case-insensitively" do
      selected = match(
        [ingress("api", rule("API.Example.COM", path("/", "Prefix")))],
        "api.example.com",
        "/"
      )

      expect(selected.rule.host).to eq("API.Example.COM")
    end

    it "does not match a different host" do
      selected = match(
        [ingress("api", rule("api.example.com", path("/", "Prefix")))],
        "other.example.com",
        "/"
      )

      expect(selected).to be_nil
    end

    it "treats a missing host as a catch-all" do
      selected = match(
        [ingress("web", rule(nil, path("/", "Prefix")))],
        "api.example.com",
        "/"
      )

      expect(selected.ingress.name).to eq("web")
      expect(selected.rule.host).to be_nil
    end

    it "matches a single-label wildcard host" do
      selected = match(
        [ingress("wildcard", rule("*.example.com", path("/", "Prefix")))],
        "api.example.com",
        "/"
      )

      expect(selected.rule.host).to eq("*.example.com")
    end

    it "does not match a wildcard against the parent domain" do
      selected = match(
        [ingress("wildcard", rule("*.example.com", path("/", "Prefix")))],
        "example.com",
        "/"
      )

      expect(selected).to be_nil
    end

    it "does not match a wildcard against extra DNS labels" do
      selected = match(
        [ingress("wildcard", rule("*.example.com", path("/", "Prefix")))],
        "foo.api.example.com",
        "/"
      )

      expect(selected).to be_nil
    end
  end

  describe "Exact path matching" do
    let(:ingresses) do
      [ingress("api", rule("api.example.com", path("/users", "Exact")))]
    end

    it "matches the exact path" do
      selected = match(ingresses, "api.example.com", "/users")

      expect(selected.path).to eq(path("/users", "Exact"))
    end

    it "does not match a trailing slash" do
      expect(match(ingresses, "api.example.com", "/users/")).to be_nil
    end

    it "does not match a longer path" do
      expect(match(ingresses, "api.example.com", "/users/42")).to be_nil
    end

    it "does not match a different path" do
      expect(match(ingresses, "api.example.com", "/user")).to be_nil
    end
  end

  describe "Prefix path matching" do
    let(:ingresses) do
      [ingress("api", rule("api.example.com", path("/users", "Prefix")))]
    end

    it "matches the prefix path itself" do
      selected = match(ingresses, "api.example.com", "/users")

      expect(selected.path).to eq(path("/users", "Prefix"))
    end

    it "matches a trailing slash after the prefix" do
      selected = match(ingresses, "api.example.com", "/users/")

      expect(selected.path.path).to eq("/users")
    end

    it "matches nested paths under the prefix" do
      selected = match(ingresses, "api.example.com", "/users/42")

      expect(selected.path.path).to eq("/users")
    end

    it "does not match a path that only shares a string prefix" do
      expect(match(ingresses, "api.example.com", "/usersx")).to be_nil
    end

    it "does not match when the last element is a substring" do
      selected = match(
        [ingress("api", rule("api.example.com", path("/aaa/bb", "Prefix")))],
        "api.example.com",
        "/aaa/bbb"
      )

      expect(selected).to be_nil
    end

    it "matches every path when the prefix is /" do
      selected = match(
        [ingress("api", rule("api.example.com", path("/", "Prefix")))],
        "api.example.com",
        "/anything/else"
      )

      expect(selected.path.path).to eq("/")
    end

    it "treats a trailing slash on a Prefix rule as the same elements" do
      selected = match(
        [ingress("api", rule("api.example.com", path("/users/", "Prefix")))],
        "api.example.com",
        "/users"
      )

      expect(selected.path.path).to eq("/users/")
    end
  end

  describe "ImplementationSpecific path matching" do
    let(:ingresses) do
      [ingress("api", rule("api.example.com", path("/users", "ImplementationSpecific")))]
    end

    it "matches only the exact path" do
      selected = match(ingresses, "api.example.com", "/users")

      expect(selected.path.path_type).to eq("ImplementationSpecific")
    end

    it "does not apply Prefix semantics" do
      expect(match(ingresses, "api.example.com", "/users/42")).to be_nil
    end

    it "treats a missing pathType like ImplementationSpecific" do
      selected = match(
        [ingress("api", rule("api.example.com", path("/users", nil)))],
        "api.example.com",
        "/users"
      )

      expect(selected.path.path_type).to be_nil
      expect(match(
        [ingress("api", rule("api.example.com", path("/users", nil)))],
        "api.example.com",
        "/users/42"
      )).to be_nil
    end

    it "does not match unknown path types" do
      selected = match(
        [ingress("api", rule("api.example.com", path("/users", "Regex")))],
        "api.example.com",
        "/users"
      )

      expect(selected).to be_nil
    end
  end

  describe "competing rules" do
    it "prefers the longest matching path even when it is on a wildcard host" do
      selected = match(
        [
          ingress("wildcard", rule("*.example.com", path("/users", "Prefix"))),
          ingress("exact", rule("api.example.com", path("/", "Prefix")))
        ],
        "api.example.com",
        "/users"
      )

      expect(selected.ingress.name).to eq("wildcard")
      expect(selected.path.path).to eq("/users")
    end

    it "prefers the longest matching path even when it is on a catch-all host" do
      selected = match(
        [
          ingress("any", rule(nil, path("/users", "Prefix"))),
          ingress("exact", rule("api.example.com", path("/", "Prefix")))
        ],
        "api.example.com",
        "/users"
      )

      expect(selected.ingress.name).to eq("any")
      expect(selected.path.path).to eq("/users")
    end

    it "prefers the longest matching Prefix on the same host" do
      selected = match(
        [
          ingress(
            "api",
            rule(
              "api.example.com",
              path("/", "Prefix"),
              path("/users", "Prefix"),
              path("/users/admin", "Prefix")
            )
          )
        ],
        "api.example.com",
        "/users/admin/edit"
      )

      expect(selected.path.path).to eq("/users/admin")
    end

    it "prefers Exact over Prefix when the matched paths are the same length" do
      selected = match(
        [
          ingress(
            "api",
            rule(
              "api.example.com",
              path("/users", "Prefix"),
              path("/users", "Exact")
            )
          )
        ],
        "api.example.com",
        "/users"
      )

      expect(selected.path.path_type).to eq("Exact")
    end

    it "selects a matching rule from among several Ingress resources" do
      selected = match(
        [
          ingress("web", rule("web.example.com", path("/", "Prefix"))),
          ingress("api", rule("api.example.com", path("/users", "Prefix")))
        ],
        "api.example.com",
        "/users/42"
      )

      expect(selected.ingress.name).to eq("api")
      expect(selected.path.path).to eq("/users")
    end

    it "breaks remaining ties by Ingress name as a KubeTraffic fallback" do
      selected = match(
        [
          ingress("zeta", rule("api.example.com", path("/", "Prefix"))),
          ingress("alpha", rule("api.example.com", path("/", "Prefix")))
        ],
        "api.example.com",
        "/"
      )

      expect(selected.ingress.name).to eq("alpha")
    end

    it "does not rank exact hosts over wildcards when path and pathType tie" do
      selected = match(
        [
          ingress("zeta", rule("api.example.com", path("/", "Prefix"))),
          ingress("alpha", rule("*.example.com", path("/", "Prefix")))
        ],
        "api.example.com",
        "/"
      )

      expect(selected.ingress.name).to eq("alpha")
    end
  end

  describe "backend Service reference" do
    it "exposes the matched path's Service name" do
      selected = match(
        [
          ingress(
            "api",
            rule(
              "api.example.com",
              path("/users", "Prefix", backend: service_backend("api", port_number: 80))
            )
          )
        ],
        "api.example.com",
        "/users"
      )

      expect(selected.backend.name).to eq("api")
    end

    it "exposes a numeric backend port" do
      selected = match(
        [
          ingress(
            "api",
            rule(
              "api.example.com",
              path("/users", "Prefix", backend: service_backend("api", port_number: 8080))
            )
          )
        ],
        "api.example.com",
        "/users"
      )

      expect(selected.backend.port_number).to eq(8080)
      expect(selected.backend.port_name).to be_nil
    end

    it "exposes a named backend port" do
      selected = match(
        [
          ingress(
            "api",
            rule(
              "api.example.com",
              path("/users", "Prefix", backend: service_backend("api", port_name: "http"))
            )
          )
        ],
        "api.example.com",
        "/users"
      )

      expect(selected.backend.name).to eq("api")
      expect(selected.backend.port_name).to eq("http")
      expect(selected.backend.port_number).to be_nil
    end

    it "exposes a missing backend as nil" do
      selected = match(
        [ingress("api", rule("api.example.com", path("/users", "Prefix")))],
        "api.example.com",
        "/users"
      )

      expect(selected.backend).to be_nil
    end

    it "keeps a Service name when the backend port cannot be interpreted" do
      selected = match(
        [
          ingress(
            "api",
            rule(
              "api.example.com",
              path("/users", "Prefix", backend: service_backend("api"))
            )
          )
        ],
        "api.example.com",
        "/users"
      )

      expect(selected.backend.name).to eq("api")
      expect(selected.backend.port_number).to be_nil
      expect(selected.backend.port_name).to be_nil
    end
  end

  it "returns nil when no rule matches" do
    selected = match(
      [ingress("api", rule("api.example.com", path("/health", "Exact")))],
      "api.example.com",
      "/users"
    )

    expect(selected).to be_nil
  end
end
