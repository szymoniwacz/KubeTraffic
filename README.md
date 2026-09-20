# KubeTraffic

Read-only CLI that traces how an HTTP request is routed through Kubernetes.

This repository is in early development. The CLI currently reports its version,
accepts a `trace` target, connects read-only to the current Kubernetes context,
matches the target host and path against Ingress rules in the selected
namespace, reports the referenced backend Service name and port, fetches that
Service to resolve the matching `spec.ports` entry, and lists EndpointSlices
labeled for that Service. Ready, not-ready, and unknown endpoints are counted
from retrieved `conditions.ready` values. `ready=true` and omitted/`nil` ready
conditions are usable (Kubernetes treats nil as true); only `ready=false` is
unusable. EndpointSlice `targetRef` values that name a Pod are fetched for
name, IP, phase, and readiness. Numeric `targetPort` values are shown as
retrieved. Named `targetPort` values are resolved per usable Pod. Different
pods may map the same name to different numbers. Unresolved named ports are
reported instead of guessed. The trace then shows the matching container
`containerPort` and states that this declaration does not prove a process is
listening.

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
EndpointSlice api-abc
  10.1.2.3 ready=true
  ready 1
  not-ready 0
  unknown readiness 0
Pod api-abc
  IP 10.1.2.3
  phase Running
  ready=true
Target port 8080
Container api on Pod api-abc
  port 8080 name http
declared containerPort is configuration, not proof a process is listening

$ bin/kubetraffic --context staging -n apps trace api.example.com/users
Tracing api.example.com/users in namespace apps
Matched Ingress api
  host api.example.com
  path /users
  pathType Prefix
  service api:80
Service api
  port 80 name http
EndpointSlice api-abc
  10.1.2.3 ready=true
  ready 1
  not-ready 0
  unknown readiness 0
Pod api-abc
  IP 10.1.2.3
  phase Running
  ready=true
Target port 8080
Container api on Pod api-abc
  port 8080 name http
declared containerPort is configuration, not proof a process is listening
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
reported without inventing a default port. EndpointSlices are selected with the
`kubernetes.io/service-name` label in the same namespace. Missing slices and
slices with no endpoints are reported. Endpoint readiness is shown as retrieved
and summarized as ready, not-ready, and unknown counts. Endpoints with
`ready=true` or omitted/`nil` `conditions.ready` are usable; unknown counts are
display-only. Only `ready=false` is unusable. Pods are resolved only from
EndpointSlice `targetRef` entries of kind `Pod`. Missing Pods and missing
target references are reported without matching endpoints to Pods by IP. A
numeric Service `targetPort` is shown directly. A named `targetPort` is
resolved per usable endpoint Pod. Different pods may map the same name to
different numbers. The name is unresolved only when an inspected usable Pod
does not declare it unambiguously. An omitted `targetPort` uses the Service
port number, matching Kubernetes. Not-ready endpoints are not used for
named-port resolution. A matching declared `containerPort` is shown as the last
hop. That field is configuration metadata, not proof that a process is listening.
