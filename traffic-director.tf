# ------------------------------------------------------------------------------
# Cloud Service Mesh (Traffic Director) Resources
# ------------------------------------------------------------------------------

# Health Check for the gRPC service
resource "google_compute_health_check" "grpc_health_check" {
  name                = "grpc-health-check"
  project             = "eliran-home"
  timeout_sec         = 1
  check_interval_sec  = 1
  grpc_health_check {
    port_name          = "grpc"
    serving_status     = "SERVING"
  }
}

# Backend Service for the gRPC service
resource "google_compute_backend_service" "grpc_backend_service" {
  name                  = "greeter-backend-service"
  project               = "eliran-home"
  port_name             = "grpc"
  protocol              = "GRPC"
  load_balancing_scheme = "INTERNAL_SELF_MANAGED"
  health_checks         = [google_compute_health_check.grpc_health_check.id]
}

# URL Map to route requests to the backend service
resource "google_compute_url_map" "grpc_url_map" {
  name            = "greeter-url-map"
  project         = "eliran-home"
  default_service = google_compute_backend_service.grpc_backend_service.id

  host_rule {
    hosts        = ["greeter-service:50051"]
    path_matcher = "allpaths"
  }

  path_matcher {
    name            = "allpaths"
    default_service = google_compute_backend_service.grpc_backend_service.id
  }
}

# Target gRPC Proxy
resource "google_compute_target_grpc_proxy" "grpc_proxy" {
  name            = "greeter-grpc-proxy"
  project         = "eliran-home"
  url_map         = google_compute_url_map.grpc_url_map.id
  validate_for_proxyless = true
}

# Global Forwarding Rule
resource "google_compute_global_forwarding_rule" "grpc_forwarding_rule" {
  name                  = "greeter-forwarding-rule"
  project               = "eliran-home"
  target                = google_compute_target_grpc_proxy.grpc_proxy.id
  port_range            = "50051"
  load_balancing_scheme = "INTERNAL_SELF_MANAGED"
}
