# KubeTraffic

Read-only CLI that traces how an HTTP request is routed through Kubernetes
configuration:

```text
Ingress -> Service -> EndpointSlice -> Pod -> Container/port
```

This is a configuration trace, not a packet capture. It explains which
Kubernetes objects would handle a host and path, and where that chain is
broken.

## Requirements

- Ruby 3.2 or newer
- read access to Ingress, Service, EndpointSlice, and Pod objects in the
  target namespace
- a kubeconfig (`KUBECONFIG` or `~/.kube/config`)

KubeTraffic does not write to the cluster.

## Installation

The project is not published as a gem yet. For development:

```text
git clone https://github.com/szymoniwacz/KubeTraffic.git
cd KubeTraffic
bundle install
bin/kubetraffic --version
```

## Usage

```text
bin/kubetraffic --version
bin/kubetraffic trace https://api.example.com/users
bin/kubetraffic --context staging -n apps trace api.example.com/users
```

`trace` accepts a URL or `host/path`. It loads kubeconfig, uses `--context`
when given, and verifies that the API is reachable before continuing.

Namespace resolution follows kubectl: `--namespace`/`-n`, then the selected
kubeconfig context namespace, then `default`.

Output is plaintext with `[ok]` and `[x]` markers. It does not use ANSI color.

```text
$ bin/kubetraffic --version
KubeTraffic 0.1.0

$ bin/kubetraffic trace https://api.example.com/users
Tracing api.example.com/users in namespace default

[ok] Ingress api
     host api.example.com
     path /users
     pathType Prefix
     service api:80

[ok] Service api
     port 80 name http

[ok] EndpointSlice
     api-abc
       10.1.2.3 ready=true
     ready 1
     not-ready 0
     unknown readiness 0

[ok] Pod api-abc
     IP 10.1.2.3
     phase Running
     ready=true

[ok] Target port
     8080

[ok] Container api on Pod api-abc
     port 8080 name http
     declared containerPort is configuration, not proof a process is listening

Result: configuration chain complete
```

A broken chain ends with `Result: failed (<code>)`. Codes currently include
`ingress_not_found`, `service_not_found`, `service_port_not_found`,
`service_no_endpoints`, `endpoint_not_ready`, `pod_not_found`, and
`target_port_unresolved`.

## What it inspects

- `networking.k8s.io/v1` Ingress host and path matching (`Exact`, `Prefix`;
  `ImplementationSpecific` and missing `pathType` match the exact path only)
- Ingress Service backends (named or numeric ports)
- core `v1` Service ports and `targetPort`
- `discovery.k8s.io/v1` EndpointSlices labeled
  `kubernetes.io/service-name=<service>`
- endpoint `conditions.ready` (only `true` is treated as usable)
- Pods named by EndpointSlice `targetRef` of kind `Pod`
- declared container ports used to resolve a named `targetPort`

Among matching Ingress rules, the longest path wins, then `Exact` over
`Prefix`. Remaining ties are broken by Ingress name; that fallback is
KubeTraffic-specific, not Kubernetes routing semantics.

An omitted Service `targetPort` uses the Service port number, matching
Kubernetes. KubeTraffic does not invent names, ports, Pods, or endpoints that
were not retrieved.

## Limitations

From configuration alone, KubeTraffic cannot prove:

- that a process is listening on a declared `containerPort`
- that packets are not dropped by a CNI, NetworkPolicy, or something outside
  the inspected objects
- that the application handler works
- that external DNS resolves
- that a service mesh is healthy

It also does not currently support Gateway API, NetworkPolicy analysis, watch
mode, JSON output, or active network probes.

## License

MIT
