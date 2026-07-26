resource "google_storage_bucket" "tf_state" {
  name          = "utila-eliran-home-tf-state" # This name must be globally unique
  project       = var.project_id
  location      = "US"
  force_destroy = false

  uniform_bucket_level_access = true

  versioning {
    enabled = true
  }

  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      num_newer_versions = 10
    }
  }
}
