# ------------------------------------------------------------------------------
# IAM for GitHub Actions CI/CD
# ------------------------------------------------------------------------------

# Service Account for Terraform to manage infrastructure
resource "google_service_account" "terraform_sa" {
  project      = "eliran-home"
  account_id   = "terraform-sa"
  display_name = "Terraform Service Account"
}

# Service Account for pushing images to GCR
resource "google_service_account" "gcr_pusher_sa" {
  project      = "eliran-home"
  account_id   = "gcr-pusher-sa"
  display_name = "GCR Pusher Service Account"
}

# IAM roles for the Terraform Service Account
resource "google_project_iam_member" "terraform_sa_roles" {
  for_each = toset([
    "roles/container.admin",
    "roles/compute.admin",
    "roles/iam.serviceAccountUser",
  ])

  project = "eliran-home"
  role    = each.key
  member  = "serviceAccount:${google_service_account.terraform_sa.email}"
}

# IAM role for the GCR Pusher Service Account
resource "google_project_iam_member" "gcr_pusher_sa_role" {
  project = "eliran-home"
  role    = "roles/storage.admin"
  member  = "serviceAccount:${google_service_account.gcr_pusher_sa.email}"
}

# ------------------------------------------------------------------------------
# Workload Identity Federation
# ------------------------------------------------------------------------------

# Workload Identity Pool
resource "google_iam_workload_identity_pool" "github_pool" {
  project                  = "eliran-home"
  workload_identity_pool_id = "github-pool"
  display_name             = "GitHub Actions Pool"
}

# Workload Identity Provider for GitHub
resource "google_iam_workload_identity_pool_provider" "github_provider" {
  project                            = "eliran-home"
  workload_identity_pool_id          = google_iam_workload_identity_pool.github_pool.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"
  display_name                       = "GitHub Provider"
  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.actor"      = "assertion.actor"
    "attribute.repository" = "assertion.repository"
  }
  oidc = {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# Allow the app-repo GitHub Actions to impersonate the GCR Pusher SA
resource "google_service_account_iam_member" "gcr_pusher_wif" {
  service_account_id = google_service_account.gcr_pusher_sa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github_pool.name}/attribute.repository/eliranKimi/app-repo" # Assuming app-repo is under the same user
}

# Allow the iac-gitops-repo GitHub Actions to impersonate the Terraform SA
resource "google_service_account_iam_member" "terraform_wif" {
  service_account_id = google_service_account.terraform_sa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github_pool.name}/attribute.repository/eliranKimi/iac-githops-repo"
}
