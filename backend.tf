terraform {
  backend "gcs" {
    bucket  = "utila-eliran-home-tf-state"
    prefix  = "terraform/state"
  }
}
