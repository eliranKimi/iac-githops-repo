# ------------------------------------------------------------------------------
# IAM for GitHub Actions CI/CD
# ------------------------------------------------------------------------------

# Service Account for Terraform to manage infrastructure
resource "google_service_account" "terraform_sa" {
  project      = var.project_id
  account_id   = "terraform-sa"
  display_name = "Terraform Service Account"
}

# Service Account for pushing images to GCR / Artifact Registry
resource "google_service_account" "gcr_pusher_sa" {
  project      = var.project_id
  account_id   = "gcr-pusher-sa"
  display_name = "GCR Pusher Service Account"
}

# IAM roles for the Terraform Service Account
# These roles are required to create all resources in this project
resource "google_project_iam_member" "terraform_sa_roles" {
  for_each = toset([
    "roles/compute.admin",              # VPC, forwarding rules, health checks
    "roles/container.admin",            # GKE cluster management
    "roles/iam.serviceAccountAdmin",    # Create/manage service accounts
    "roles/iam.serviceAccountUser",     # Attach service accounts to resources
    "roles/iam.workloadIdentityPoolAdmin", # Create WIF pools and providers
    "roles/storage.admin",              # GCS bucket for Terraform state
    "roles/resourcemanager.projectIamAdmin", # Grant IAM roles on the project
    "roles/gkehub.admin",              # GKE Hub / Fleet membership
    "roles/serviceusage.serviceUsageAdmin", # Enable GCP APIs
  ])

  project = var.project_id
  role    = each.key
  member  = "serviceAccount:${google_service_account.terraform_sa.email}"
}

# IAM role for the GCR Pusher Service Account
# Artifact Registry Writer is preferred over storage.admin for new projects
resource "google_project_iam_member" "gcr_pusher_sa_role" {
  project = var.project_id
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${google_service_account.gcr_pusher_sa.email}"
}

# Also grant storage.admin for legacy GCR (gcr.io) support
resource "google_project_iam_member" "gcr_pusher_sa_storage_role" {
  project = var.project_id
  role    = "roles/storage.admin"
  member  = "serviceAccount:${google_service_account.gcr_pusher_sa.email}"
}

# ------------------------------------------------------------------------------
# Workload Identity Federation
# ------------------------------------------------------------------------------

# Workload Identity Pool
resource "google_iam_workload_identity_pool" "github_pool" {
  project                   = var.project_id
  workload_identity_pool_id = "github-pool"
  display_name              = "GitHub Actions Pool"
  description               = "Identity pool for GitHub Actions workflows"
}

# Workload Identity Provider for GitHub
resource "google_iam_workload_identity_pool_provider" "github_provider" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github_pool.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"
  display_name                       = "GitHub Provider"
  description                        = "OIDC provider for GitHub Actions"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.actor"      = "assertion.actor"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  # Restrict to only your GitHub org/user for security
  attribute_condition = "attribute.repository_owner == \"${var.github_org}\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# Allow the app-repo GitHub Actions to impersonate the GCR Pusher SA
resource "google_service_account_iam_member" "gcr_pusher_wif" {
  service_account_id = google_service_account.gcr_pusher_sa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github_pool.name}/attribute.repository/${var.github_org}/${var.app_repo_name}"
}

# Allow the iac-gitops-repo GitHub Actions to impersonate the Terraform SA
resource "google_service_account_iam_member" "terraform_wif" {
  service_account_id = google_service_account.terraform_sa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github_pool.name}/attribute.repository/${var.github_org}/${var.iac_repo_name}"
}
