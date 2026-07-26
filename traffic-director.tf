# ------------------------------------------------------------------------------
# Cloud Service Mesh (Traffic Director) Resources
# ------------------------------------------------------------------------------

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
