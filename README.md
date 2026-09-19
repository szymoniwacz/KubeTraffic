# KubeTraffic

Read-only CLI that traces how an HTTP request is routed through Kubernetes.

This repository is in early development. The CLI currently reports its version,
accepts a `trace` target, and connects read-only to the current Kubernetes
context. It does not yet inspect Ingress routing.

```text
$ bin/kubetraffic --version
KubeTraffic 0.0.1

$ bin/kubetraffic trace https://api.example.com/users
Tracing api.example.com/users

$ bin/kubetraffic --context staging trace api.example.com/users
Tracing api.example.com/users
```

`trace` loads kubeconfig from `KUBECONFIG` or `~/.kube/config` and verifies that
the Kubernetes API is reachable before continuing. Use `--context` to select a
named kubeconfig context.
