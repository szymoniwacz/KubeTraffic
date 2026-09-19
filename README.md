# KubeTraffic

Read-only CLI that traces how an HTTP request is routed through Kubernetes.

This repository is in early development. The CLI currently reports its version
and accepts a `trace` target. It does not yet inspect a Kubernetes cluster.

```text
$ bin/kubetraffic --version
KubeTraffic 0.0.1

$ bin/kubetraffic trace https://api.example.com/users
Tracing api.example.com/users
```
