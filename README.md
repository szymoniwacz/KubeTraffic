# KubeTraffic

Read-only CLI that traces how an HTTP request is routed through Kubernetes.

This repository is in early development. The CLI currently reports its version,
accepts a `trace` target, connects read-only to the current Kubernetes context,
matches the target host and path against Ingress rules in the selected
namespace, reports the referenced backend Service name and port, and fetches
that Service to resolve the matching `spec.ports` entry. It does not yet look
up EndpointSlices or resolve `targetPort`.

```text
$ bin/kubetraffic --version
KubeTraffic 0.0.1

$ bin/kubetraffic trace https://api.example.com/users
Tracing api.example.com/users in namespace default
Matched Ingress api
  host api.example.com
  path /users
  pathType Prefix
  service api:80
Service api
  port 80 name http

$ bin/kubetraffic --context staging -n apps trace api.example.com/users
Tracing api.example.com/users in namespace apps
Matched Ingress api
  host api.example.com
  path /users
  pathType Prefix
  service api:80
Service api
  port 80 name http
```

`trace` loads kubeconfig from `KUBECONFIG` or `~/.kube/config` and verifies that
the Kubernetes API is reachable before continuing. Use `--context` to select a
named kubeconfig context.

Namespace resolution follows kubectl: `--namespace`/`-n` wins, then the selected
kubeconfig context namespace, then `default`. Ingress listing and matching use
this namespace. Host matching follows Kubernetes Ingress rules, including
single-label wildcards and catch-all hosts. Path matching supports `Exact` and
`Prefix`. `ImplementationSpecific` and missing `pathType` match only the exact
path. Among matching rules, the longest path wins, then `Exact` over `Prefix`.
Any remaining tie is broken deterministically by Ingress name; that fallback is
KubeTraffic-specific, not Kubernetes routing semantics. The matched path's
`networking.k8s.io/v1` Service backend is shown as `service name:port`. Missing
or non-Service backends, and unreadable ports, are reported instead of defaulting
to a name or port 80. A numeric Ingress backend port is matched against
`Service.spec.ports[].port`; a named backend port is matched against
`Service.spec.ports[].name`. A missing Service or unmatched Service port is
reported without inventing a default port.
