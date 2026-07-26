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
resource "google_compute_health_check" "grpc_health_check" {
  name               = "grpc-health-check"
  project            = var.project_id
  timeout_sec        = 1
  check_interval_sec = 1

  grpc_health_check {
    port = 50051
  }
}

# Backend Service for the gRPC service
resource "google_compute_backend_service" "grpc_backend_service" {
  name                  = "greeter-backend-service"
  project               = var.project_id
  port_name             = "grpc"
  protocol              = "GRPC"
  load_balancing_scheme = "INTERNAL_SELF_MANAGED"
  health_checks         = [google_compute_health_check.grpc_health_check.id]
}

# URL Map to route requests to the backend service
resource "google_compute_url_map" "grpc_url_map" {
  name            = "greeter-url-map"
  project         = var.project_id
  default_service = google_compute_backend_service.grpc_backend_service.id

  host_rule {
    hosts        = ["greeter-service"]
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
resource "google_compute_global_forwarding_rule" "grpc_forwarding_rule" {
  name                  = "greeter-forwarding-rule"
  project               = var.project_id
  target                = google_compute_target_grpc_proxy.grpc_proxy.id
  ip_address            = "0.0.0.0"
  port_range            = "50051"
  load_balancing_scheme = "INTERNAL_SELF_MANAGED"
}
