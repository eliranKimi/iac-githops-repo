# ------------------------------------------------------------------------------
# Firewall Rules
# ------------------------------------------------------------------------------

# Allow Google's health checker to reach pods on port 50051.
# Traffic Director health checks originate from these Google-owned IP ranges.
# Without this rule, health checks will fail even if the server is running.
resource "google_compute_firewall" "allow_health_checks" {
  name    = "allow-grpc-health-checks"
  project = var.project_id
  network = "grpc-proxyless-vpc"

  allow {
    protocol = "tcp"
    ports    = ["50051"]
  }

  # Google's health checker source IP ranges
  source_ranges = [
    "35.191.0.0/16",
    "130.211.0.0/22",
  ]

  target_tags = ["gke-grpc-proxyless-cluster"]
  description = "Allow Traffic Director health checks to reach gRPC server pods"
}
