# ------------------------------------------------------------------------------
# Cloud Service Mesh (Traffic Director) Resources
# ------------------------------------------------------------------------------

# Service Account for the application pods (greeter server and client)
resource "google_service_account" "greeter_sa" {
  project      = var.project_id
  account_id   = "greeter-sa"
  display_name = "Greeter Application Service Account"
}

# Grant Traffic Director permissions to the greeter service account
resource "google_project_iam_member" "greeter_sa_traffic_director" {
  project = var.project_id
  role    = "roles/trafficdirector.client"
  member  = "serviceAccount:${google_service_account.greeter_sa.email}"
}

# Workload Identity binding: allow the Kubernetes SA to impersonate the GCP SA
resource "google_service_account_iam_member" "greeter_workload_identity" {
  service_account_id = google_service_account.greeter_sa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[grpc-proxyless/greeter-service-account]"
}

# Health Check for the gRPC service
# The server uses a standard grpc.NewServer() (not xds.NewGRPCServer()),
# so the health check hits port 50051 directly.
resource "google_compute_health_check" "grpc_health_check" {
  name               = "grpc-health-check"
  project            = var.project_id
  timeout_sec        = 5
  check_interval_sec = 10

  grpc_health_check {
    port = 50051
  }
}

# Data sources for NEGs in each zone where GKE nodes run.
# GKE creates one NEG per zone when the cloud.google.com/neg annotation is set.
# Update var.gke_node_zones in variables.tf if nodes move to different zones.
data "google_compute_network_endpoint_group" "greeter_neg" {
  for_each = toset(var.gke_node_zones)
  project  = var.project_id
  name     = "greeter-neg"
  zone     = each.value
}

# Backend Service for the gRPC service
resource "google_compute_backend_service" "grpc_backend_service" {
  name                  = "greeter-backend-service"
  project               = var.project_id
  port_name             = "grpc"
  protocol              = "GRPC"
  load_balancing_scheme = "INTERNAL_SELF_MANAGED"
  health_checks         = [google_compute_health_check.grpc_health_check.id]

  # Dynamically add NEGs from all zones where pods are running
  dynamic "backend" {
    for_each = data.google_compute_network_endpoint_group.greeter_neg
    content {
      group                 = backend.value.id
      balancing_mode        = "RATE"
      max_rate_per_endpoint = 100
    }
  }
}

# URL Map to route requests to the backend service.
# The host must match EXACTLY what the client uses in xds:///greeter-service:50051
# Traffic Director uses the host:port as the Listener resource name.
resource "google_compute_url_map" "grpc_url_map" {
  name            = "greeter-url-map"
  project         = var.project_id
  default_service = google_compute_backend_service.grpc_backend_service.id

  host_rule {
    # Include both with and without port to handle all client configurations
    hosts        = ["greeter-service", "greeter-service:50051"]
    path_matcher = "allpaths"
  }

  path_matcher {
    name            = "allpaths"
    default_service = google_compute_backend_service.grpc_backend_service.id
  }
}

# Target gRPC Proxy
resource "google_compute_target_grpc_proxy" "grpc_proxy" {
  name                   = "greeter-grpc-proxy"
  project                = var.project_id
  url_map                = google_compute_url_map.grpc_url_map.id
  validate_for_proxyless = true
}

# Global Forwarding Rule
# For proxyless gRPC with INTERNAL_SELF_MANAGED, ip_address must be 0.0.0.0
# IMPORTANT: The network must match the VPC where the GKE cluster runs.
# Traffic Director matches xDS clients to forwarding rules by network.
resource "google_compute_global_forwarding_rule" "grpc_forwarding_rule" {
  name                  = "greeter-forwarding-rule"
  project               = var.project_id
  target                = google_compute_target_grpc_proxy.grpc_proxy.id
  ip_address            = "0.0.0.0"
  port_range            = "50051"
  load_balancing_scheme = "INTERNAL_SELF_MANAGED"
  network               = "projects/${var.project_id}/global/networks/grpc-proxyless-vpc"
}
