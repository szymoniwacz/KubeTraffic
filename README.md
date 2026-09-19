# KubeTraffic

Read-only CLI that traces how an HTTP request is routed through Kubernetes.

This repository is in early development. The CLI currently reports its version,
accepts a `trace` target, connects read-only to the current Kubernetes context,
and matches the target host and path against Ingress rules in the selected
namespace. It does not yet resolve the backend Service.

```text
$ bin/kubetraffic --version
KubeTraffic 0.0.1

$ bin/kubetraffic trace https://api.example.com/users
Tracing api.example.com/users in namespace default
Matched Ingress api
  host api.example.com
  path /users
  pathType Prefix

$ bin/kubetraffic --context staging -n apps trace api.example.com/users
Tracing api.example.com/users in namespace apps
Matched Ingress api
  host api.example.com
  path /users
  pathType Prefix
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
KubeTraffic-specific, not Kubernetes routing semantics.
