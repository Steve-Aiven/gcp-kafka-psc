provider "aiven" {
  # API token is set via TF_VAR_aiven_token environment variable (keep out of tfvars)
  api_token = var.aiven_token
}

provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
}
