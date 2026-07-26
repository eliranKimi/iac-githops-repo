variable "project_id" {
  description = "The GCP project ID to deploy resources into."
  type        = string
  default     = "utila-eliran-home"
}

variable "region" {
  description = "The GCP region for the GKE cluster and other resources."
  type        = string
  default     = "us-central1"
}

variable "github_org" {
  description = "The GitHub organization or username that owns the repositories."
  type        = string
  default     = "eliranKimi"
}

variable "app_repo_name" {
  description = "The name of the application source code repository."
  type        = string
  default     = "app-repo"
}

variable "iac_repo_name" {
  description = "The name of the infrastructure and GitOps repository."
  type        = string
  default     = "iac-githops-repo"
}

variable "gke_node_zones" {
  description = "List of zones where GKE nodes (and NEGs) are created."
  type        = list(string)
  default     = ["us-central1-b", "us-central1-f"]
}
