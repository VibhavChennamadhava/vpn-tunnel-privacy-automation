terraform {
  required_version = ">= 1.5.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 6.0.0"
    }
  }
}

# Authentication is picked up from the environment. Any of these work:
#   * OCI Cloud Shell (Terraform is preinstalled and uses your console session)
#   * ~/.oci/config with a DEFAULT profile
#   * OCI_* environment variables
provider "oci" {
  region = var.region
}
