terraform {
  required_version = ">= 1.3.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.40.0, < 7.0.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# ------------------------------------------------------------------------------
# VPC Network
# ------------------------------------------------------------------------------
module "vpc" {
  source  = "terraform-google-modules/network/google"
  version = "~> 9.0"

  project_id   = var.project_id
  network_name = "grpc-proxyless-vpc"

  subnets = [
    {
      subnet_name              = "gke-subnet"
      subnet_ip                = "10.10.0.0/24"
      subnet_region            = var.region
      subnet_private_access    = true  # Required for GKE nodes to reach Google APIs without public IPs
    },
  ]

  # Secondary ranges for VPC-native GKE cluster
  secondary_ranges = {
    "gke-subnet" = [
      {
        range_name    = "pods-range"
        ip_cidr_range = "10.20.0.0/16"
      },
      {
        range_name    = "services-range"
        ip_cidr_range = "10.30.0.0/20"
      },
    ]
  }
}

# ------------------------------------------------------------------------------
# GKE Cluster
# ------------------------------------------------------------------------------
module "gke" {
  source  = "terraform-google-modules/kubernetes-engine/google"
  version = "~> 33.0"

  project_id        = var.project_id
  name              = "grpc-proxyless-cluster"
  region            = var.region
  network           = module.vpc.network_name
  subnetwork        = module.vpc.subnets_names[0]
  ip_range_pods     = "pods-range"
  ip_range_services = "services-range"

  # Enable Workload Identity — identity_namespace enables it at cluster level
  identity_namespace = "${var.project_id}.svc.id.goog"

  node_pools = [
    {
      name                      = "default-node-pool"
      machine_type              = "e2-medium"
      min_count                 = 1
      max_count                 = 3
      local_ssd_count           = 0
      auto_repair               = true
      auto_upgrade              = true
    },
  ]

  # node_metadata defaults to "GKE_METADATA" which enables Workload Identity on nodes
  node_metadata = "GKE_METADATA"

  node_pools_oauth_scopes = {
    all = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]
  }
}
