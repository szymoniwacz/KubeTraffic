# KubeTraffic

Read-only CLI that traces how an HTTP request is routed through Kubernetes.

This repository is in early development. The CLI currently reports its version,
accepts a `trace` target, connects read-only to the current Kubernetes context,
and lists Ingress resources in the selected namespace. It does not yet match
host or path rules.

```text
$ bin/kubetraffic --version
KubeTraffic 0.0.1

$ bin/kubetraffic trace https://api.example.com/users
Tracing api.example.com/users in namespace default
Ingress candidates:
  api

$ bin/kubetraffic --context staging -n apps trace api.example.com/users
Tracing api.example.com/users in namespace apps
Ingress candidates:
  api
```

`trace` loads kubeconfig from `KUBECONFIG` or `~/.kube/config` and verifies that
the Kubernetes API is reachable before continuing. Use `--context` to select a
named kubeconfig context.

Namespace resolution follows kubectl: `--namespace`/`-n` wins, then the selected
kubeconfig context namespace, then `default`. Ingress listing uses this namespace.
