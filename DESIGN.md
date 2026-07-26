# Technical Write-up: Proxyless gRPC Service Mesh on GCP

## 1. Objective

This document is the technical write-up for the Senior DevOps Engineer Home Assignment. It covers:
- Analysis of gRPC load balancing issues in Kubernetes
- Comparison of service mesh solutions
- Justification for the chosen architectural approach
- Summary of the hands-on implementation

---

## Part 1: Analysis of gRPC Load Balancing Issues

### Task 1: Identifying the Issues

#### Why gRPC over HTTP/2 with DNS Causes Load Balancing Problems

Standard Kubernetes service discovery relies on a single stable virtual IP (ClusterIP) backed by a DNS A record. When a gRPC client resolves `my-service.namespace.svc.cluster.local`, it receives this single ClusterIP. The problem is what happens next.

gRPC operates over **HTTP/2**, which is designed to multiplex many requests over a single, long-lived TCP connection. Once a gRPC client establishes a connection to the ClusterIP, `kube-proxy` routes that initial TCP connection to one specific backend pod. All subsequent gRPC calls are multiplexed over that same TCP connection — meaning they all go to the **same pod**, forever.

#### Two Specific Issues

**Issue 1: Persistent HTTP/2 Connection Pinning**

Once a gRPC client establishes a connection, it reuses it for all subsequent RPCs. The DNS resolution and TCP handshake happen only once. This means:
- Pod A gets all traffic from Client 1
- Pod B gets all traffic from Client 2
- Pod C gets no traffic at all (if no client happened to connect to it)

In practice, this leads to severe hot spots. A pod that happened to be the target of the first connection from a high-traffic client will be overwhelmed, while other pods sit idle. Horizontal Pod Autoscaling (HPA) cannot help because the load is not distributed — adding more pods doesn't help existing clients.

**Issue 2: Slow Reaction to Backend Changes**

When a pod is terminated (e.g., during a rolling deployment), clients pinned to it will experience connection failures. The client must wait for the TCP connection to time out before re-resolving DNS and connecting to a new pod. This can take tens of seconds, causing a significant availability gap.

Similarly, when new pods are added during a scale-out event, existing clients will not discover them because they never re-resolve DNS. The new pods receive zero traffic from existing clients until those clients restart or their connections are reset.

#### Real-World Impact Examples

- **Deployment rollouts:** During a rolling update, pods are replaced one by one. Clients pinned to the old pod experience errors until the connection times out. With 10 replicas and 10 clients, 10% of traffic fails during each pod replacement.
- **Autoscaling:** HPA scales up from 3 to 10 pods during a traffic spike. The 7 new pods receive zero traffic from existing clients. The 3 original pods remain overloaded. The scale-out has no effect.
- **Canary deployments:** Sending 10% of traffic to a canary pod is impossible with DNS-based load balancing — you cannot control which clients connect to which pod.

#### Why HTTP/1.1 Does Not Suffer from This

HTTP/1.1 uses a **connection-per-request** model (or short-lived keep-alive connections with a small pool). Each new request can trigger a new DNS lookup and establish a new TCP connection. Kubernetes' `kube-proxy` uses iptables/IPVS rules to randomly select a backend pod for each new TCP connection, achieving effective L4 load balancing.

With HTTP/1.1, even if a client makes 1000 requests per second, each request (or small batch) gets a fresh connection routed to a different pod, distributing load evenly across all replicas.

---

### Task 2: Solutions Comparison

#### Option 1: Golang Client-Side Load Balancing

The gRPC Go library supports client-side load balancing via the `grpc.WithDefaultServiceConfig` option and custom name resolvers. By using a `dns:///` resolver with a round-robin policy, the client resolves all pod IPs (via a headless service) and distributes requests across them.

**Pros:**
- No additional infrastructure required
- Fine-grained control over load balancing policy
- Zero latency overhead

**Cons:**
- Language-specific — every client in every language must implement this
- Requires code changes in every service
- Complex to manage at scale (policy changes require code deployments)
- Does not provide observability, security, or traffic management features

#### Option 2: Linkerd (Sidecar Proxy)

Linkerd is a lightweight service mesh that injects a sidecar proxy (written in Rust) into each pod. The proxy intercepts all gRPC traffic and performs L7 load balancing transparently.

**Pros:**
- Language-agnostic — works with any gRPC implementation
- Transparent — no application code changes required
- Strong security features (mTLS by default)
- Excellent observability (golden metrics out of the box)

**Cons:**
- Adds resource overhead (CPU/memory) for each pod's sidecar
- Adds a network hop (pod → sidecar → network → sidecar → pod)
- Adds operational complexity (managing the control plane)
- Another point of failure in the request path

#### Option 3: Envoy (Sidecar Proxy)

Envoy is the industry-standard data plane proxy, used by Istio and many other service meshes. It is highly configurable and feature-rich.

**Pros:**
- Extremely flexible and feature-rich
- Industry standard with a large ecosystem
- Supports advanced traffic policies (circuit breaking, retries, fault injection)

**Cons:**
- Complex configuration (xDS API is powerful but complex)
- Higher resource overhead than Linkerd
- Requires significant expertise to operate correctly
- Same sidecar overhead issues as Linkerd

#### Option 4: Managed Service Mesh (Proxyless gRPC with Traffic Director)

Google Cloud Service Mesh with Traffic Director enables **proxyless gRPC** — the service mesh intelligence is built directly into the gRPC client library via the xDS protocol. No sidecar proxy is needed.

**Pros:**
- **No sidecars** — eliminates resource overhead and the extra network hop
- **Native GCP integration** — integrates with IAM, Cloud Monitoring, and Cloud Logging
- **Centrally managed** — traffic policies configured via GCP APIs, not application code
- **Performance** — lower latency than sidecar-based approaches
- **Golang-native** — the gRPC Go library has first-class xDS support

**Cons:**
- Vendor lock-in to GCP
- Requires GCP-specific bootstrap configuration in each pod
- Fewer advanced features than Envoy/Istio

#### Best-Fit Solution for GCP: Proxyless gRPC with Traffic Director

For a **Golang-centric microservices architecture on GCP**, the proxyless service mesh pattern is the best fit. It eliminates the overhead of sidecar proxies while providing centralized traffic management, and it leverages the native xDS support in the gRPC Go library.

#### How to Avoid Sidecar Proxies (Golang-Centric)

The key is the **xDS protocol** built into the gRPC Go library. By importing `_ "google.golang.org/grpc/xds"` and using the `xds:///` scheme in the dial address, the gRPC client automatically:
1. Reads the xDS bootstrap configuration (injected by a GKE init container)
2. Connects to the Traffic Director control plane
3. Receives service discovery, load balancing, and routing configuration via the xDS API
4. Applies this configuration locally — no proxy needed

The server remains a standard `grpc.NewServer()` — it is registered as a backend in Traffic Director via a Network Endpoint Group (NEG), and Traffic Director handles routing to it.

#### Reference Articles

- [gRPC Load Balancing](https://grpc.io/blog/grpc-load-balancing/) — Official gRPC blog explaining the load balancing problem and client-side solutions
- [Understanding gRPC connection balancing on Kubernetes](https://kubernetes.io/blog/2021/03/24/understanding-grpc-connection-balancing-on-kubernetes/) — Kubernetes blog with practical examples
- [Proxyless service mesh with gRPC](https://cloud.google.com/traffic-director/docs/set-up-proxyless-grpc) — Official GCP documentation for Traffic Director proxyless setup
- [Google Cloud Service Mesh Documentation](https://cloud.google.com/service-mesh/docs) — Full CSM documentation
- [xDS-Based Global Load Balancing](https://cloud.google.com/load-balancing/docs/https/setting-up-global-traffic-mgmt) — Traffic Director architecture
- [gRPC xDS Features](https://github.com/grpc/grpc/blob/master/doc/grpc_xds_features.md) — xDS feature support matrix in gRPC
- [Proxyless Service Mesh in GKE](https://cloud.google.com/kubernetes-engine/docs/how-to/proxyless-grpc) — GKE-specific proxyless gRPC guide

---

## Part 2: Implementation Summary

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ GCP Project: utila-eliran-home                                  │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │ GKE Cluster: grpc-proxyless-cluster (us-central1)        │  │
│  │                                                          │  │
│  │  ┌─────────────────┐    xDS bootstrap    ┌───────────┐  │  │
│  │  │  Client Pod      │◄───────────────────│ Init Ctr  │  │  │
│  │  │  xds:///greeter- │                    └───────────┘  │  │
│  │  │  service:50051   │                                   │  │
│  │  └────────┬─────────┘                                   │  │
│  │           │ gRPC (load balanced)                        │  │
│  │    ┌──────┼──────┐                                      │  │
│  │    ▼      ▼      ▼                                      │  │
│  │  [Srv1] [Srv2] [Srv3]  ← grpc.NewServer() on :50051    │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │ Traffic Director (Cloud Service Mesh)                    │  │
│  │  Forwarding Rule → gRPC Proxy → URL Map → Backend Svc   │  │
│  │  Backend Svc → NEG (pods in us-central1-b, us-central1-f)│  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │ ArgoCD → syncs manifests from iac-gitops-repo            │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

### Task 3: IaC Setup (Terraform)

The infrastructure is fully managed by Terraform in `iac-gitops-repo/`:

| File | Resources |
|---|---|
| `main.tf` | VPC (`grpc-proxyless-vpc`), GKE cluster with Workload Identity |
| `traffic-director.tf` | Health check, backend service, URL map, gRPC proxy, forwarding rule, greeter SA |
| `github-actions-iam.tf` | CI/CD service accounts, Workload Identity Federation for GitHub Actions |
| `firewall.tf` | Firewall rule allowing Google health checker IPs (`35.191.0.0/16`, `130.211.0.0/22`) |
| `gcs-backend.tf` | GCS bucket for Terraform remote state |
| `backend.tf` | GCS backend configuration |
| `variables.tf` | All configurable variables |

### Task 4: gRPC Server (`server.go`)

The server is a **standard `grpc.NewServer()`** implementation. It does not use `xds.NewGRPCServer()` because in this architecture, Traffic Director manages routing on the **client side** — the server is simply a regular gRPC backend registered via a Network Endpoint Group (NEG).

Key features:
- Implements `SayHello` — returns `"Hello <name> from <hostname>"` (hostname identifies which pod served the request)
- Registers the gRPC health protocol (`grpc_health_v1`) for Traffic Director health checks
- Listens on port `50051`

### Task 5: gRPC Client (`client.go`)

The client uses the `xds:///` scheme to connect via Traffic Director:

```go
conn, err := grpc.NewClient("xds:///greeter-service:50051",
    grpc.WithTransportCredentials(insecure.NewCredentials()))
```

The `_ "google.golang.org/grpc/xds"` import registers the xDS resolver and balancer. The xDS bootstrap config (injected by the `grpc-td-init` init container) tells the gRPC library where to find the Traffic Director control plane.

### Task 6: Deployment with ArgoCD

ArgoCD is installed in the GKE cluster and configured to watch the `iac-gitops-repo` repository. The `manifests/application.yaml` is applied once to bootstrap ArgoCD, after which it automatically syncs all other manifests:

- `namespace.yaml` — `grpc-proxyless` namespace
- `rbac.yaml` — ServiceAccount with Workload Identity annotation (`greeter-sa@utila-eliran-home.iam.gserviceaccount.com`)
- `server.yaml` — 3-replica Deployment + headless Service with NEG annotation
- `client.yaml` — 1-replica Deployment with xDS bootstrap init container

### Key Architectural Decisions

| Decision | Rationale |
|---|---|
| `grpc.NewServer()` on server (not `xds.NewGRPCServer()`) | Server-side xDS requires Traffic Director to push Listener resources, creating a chicken-and-egg problem. The server is a standard backend; Traffic Director manages routing on the client side. |
| Headless Service with NEG annotation | Required for Traffic Director to discover pod endpoints. The `cloud.google.com/neg` annotation causes GKE to create a Network Endpoint Group per zone. |
| Separate firewall rule for health checks | Google's health checker probes come from `35.191.0.0/16` and `130.211.0.0/22` — not from within the VPC. Without this rule, all backends remain UNHEALTHY. |
| Workload Identity for pod permissions | Pods need `roles/trafficdirector.client` to connect to Traffic Director. Workload Identity links the Kubernetes SA to a GCP SA without storing credentials in the cluster. |
| xDS bootstrap via init container | The `gcr.io/trafficdirector-prod/td-grpc-bootstrap` init container generates the bootstrap JSON that tells the gRPC xDS library how to connect to Traffic Director. |
| GCS remote state for Terraform | Enables team collaboration and state locking. Versioning is enabled to protect against accidental state corruption. |
| GitHub Actions with WIF | Workload Identity Federation eliminates the need to store long-lived GCP credentials as GitHub secrets. |
