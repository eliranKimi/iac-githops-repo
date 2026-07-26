# IaC & GitOps Repository

This repository contains the Terraform infrastructure code and Kubernetes manifests for the proxyless gRPC service mesh on GCP.

## Architecture

- **GKE Cluster** on `grpc-proxyless-vpc` with Workload Identity enabled
- **Cloud Service Mesh (Traffic Director)** for proxyless gRPC load balancing
- **ArgoCD** for GitOps-based deployment
- **GitHub Actions** for CI/CD with Workload Identity Federation

## From-Scratch Deployment Guide

> **Prerequisites:** GCP project `utila-eliran-home` must exist. You must be authenticated with `gcloud auth application-default login`.

---

### Phase 1: Bootstrap the Terraform State Bucket

The GCS bucket for Terraform state must be created before the remote backend can be used.

```bash
# 1. Disable the remote backend temporarily
mv backend.tf backend.tf.disabled

# 2. Initialize with local state
terraform init

# 3. Create ONLY the GCS bucket
terraform apply -target=google_storage_bucket.tf_state

# 4. Re-enable the remote backend
mv backend.tf.disabled backend.tf

# 5. Migrate local state to GCS
terraform init -migrate-state
# Type "yes" when prompted
```

---

### Phase 2: Apply Core Infrastructure

```bash
# Apply VPC, GKE cluster, IAM, WIF, Traffic Director, and firewall rules
# NOTE: The data sources for NEGs will fail here — that's expected.
# Run with -target to skip the NEG-dependent resources on first apply.
terraform apply \
  -target=module.vpc \
  -target=module.gke \
  -target=google_service_account.terraform_sa \
  -target=google_service_account.gcr_pusher_sa \
  -target=google_project_iam_member.terraform_sa_roles \
  -target=google_project_iam_member.gcr_pusher_sa_role \
  -target=google_project_iam_member.gcr_pusher_sa_storage_role \
  -target=google_iam_workload_identity_pool.github_pool \
  -target=google_iam_workload_identity_pool_provider.github_provider \
  -target=google_service_account_iam_member.gcr_pusher_wif \
  -target=google_service_account_iam_member.terraform_wif \
  -target=google_service_account.greeter_sa \
  -target=google_project_iam_member.greeter_sa_traffic_director \
  -target=google_service_account_iam_member.greeter_workload_identity \
  -target=google_compute_health_check.grpc_health_check \
  -target=google_compute_backend_service.grpc_backend_service \
  -target=google_compute_url_map.grpc_url_map \
  -target=google_compute_target_grpc_proxy.grpc_proxy \
  -target=google_compute_global_forwarding_rule.grpc_forwarding_rule \
  -target=google_compute_firewall.allow_health_checks
```

---

### Phase 3: Install ArgoCD

```bash
# Get GKE credentials
gcloud container clusters get-credentials grpc-proxyless-cluster \
  --region=us-central1 \
  --project=utila-eliran-home

# Install ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml \
  --server-side

# Apply the ArgoCD Application (one-time bootstrap)
kubectl apply -f manifests/application.yaml
```

---

### Phase 4: Wait for GKE to Create NEGs

After ArgoCD syncs and deploys the server pods, GKE will automatically create Network Endpoint Groups (NEGs) in each zone where pods are running. This is triggered by the `cloud.google.com/neg` annotation on the Kubernetes Service.

```bash
# Wait for NEGs to appear (~2 minutes after pods are running)
watch gcloud compute network-endpoint-groups list --project=utila-eliran-home
```

---

### Phase 5: Add NEG Backends to Traffic Director

Once the NEGs exist, run `terraform apply` again to add them as backends:

```bash
# Update var.gke_node_zones in variables.tf to match the zones where NEGs were created
# Then apply:
terraform apply
```

---

### Phase 6: Verify

```bash
# Check backend health (should show HEALTHY)
gcloud compute backend-services get-health greeter-backend-service \
  --global --project=utila-eliran-home

# Check pods
kubectl get pods -n grpc-proxyless

# Check client logs (should show greetings)
kubectl logs -n grpc-proxyless -l app=greeter-client --tail=20
```

---

## Repository Structure

```
iac-gitops-repo/
├── backend.tf              # GCS remote backend configuration
├── firewall.tf             # Firewall rules (health check ingress)
├── gcs-backend.tf          # GCS bucket for Terraform state
├── github-actions-iam.tf   # Service accounts and WIF for GitHub Actions
├── main.tf                 # VPC and GKE cluster
├── traffic-director.tf     # Traffic Director (CSM) resources + greeter SA
├── variables.tf            # All configurable variables
└── manifests/
    ├── application.yaml    # ArgoCD Application (one-time bootstrap)
    ├── client.yaml         # gRPC client Deployment
    ├── namespace.yaml      # grpc-proxyless namespace
    ├── rbac.yaml           # ServiceAccount with Workload Identity annotation
    └── server.yaml         # gRPC server Deployment + headless Service with NEG
```

## GitHub Actions Secrets Required

| Secret | Description |
|--------|-------------|
| `GCP_PROJECT_NUMBER` | Numeric project number (not ID). Get with: `gcloud projects describe utila-eliran-home --format='value(projectNumber)'` |

## GitHub Environments Required

Create a `production` environment in GitHub repo settings with required reviewers to gate `terraform apply`.
