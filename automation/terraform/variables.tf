variable "region" {
  description = "OCI region identifier, for example us-phoenix-1."
  type        = string
  default     = "us-phoenix-1"
}

variable "compartment_ocid" {
  description = "Compartment to create everything in. The tenancy OCID works for the root compartment."
  type        = string
}

variable "ssh_public_key" {
  description = "OpenSSH public key for the ubuntu user, for example the contents of ~/.ssh/id_ed25519.pub."
  type        = string

  validation {
    condition     = can(regex("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+) ", var.ssh_public_key))
    error_message = "ssh_public_key must be an OpenSSH public key line (ssh-ed25519 AAAA...)."
  }
}

variable "admin_cidr" {
  description = "Source network allowed to SSH to the server, for example 203.0.113.7/32. Must not be 0.0.0.0/0."
  type        = string

  validation {
    condition     = can(cidrhost(var.admin_cidr, 0)) && var.admin_cidr != "0.0.0.0/0"
    error_message = "admin_cidr must be a valid CIDR and must not be 0.0.0.0/0. Use your own address with /32."
  }
}

variable "name_prefix" {
  description = "Prefix for resource display names."
  type        = string
  default     = "wg-demo"
}

variable "shape" {
  description = "Compute shape. VM.Standard.A1.Flex (Arm) and VM.Standard.E2.1.Micro (x86) are the Always Free eligible shapes."
  type        = string
  default     = "VM.Standard.A1.Flex"
}

variable "ocpus" {
  description = "OCPUs for Flex shapes. Ignored for fixed shapes."
  type        = number
  default     = 1
}

variable "memory_gb" {
  description = "Memory in GB for Flex shapes. Ignored for fixed shapes."
  type        = number
  default     = 6
}

variable "ubuntu_version" {
  description = "Ubuntu release to look up in the OCI image catalog."
  type        = string
  default     = "24.04"
}

variable "availability_domain_index" {
  description = "Which availability domain to use (0, 1, 2). Try another if you see 'Out of host capacity'."
  type        = number
  default     = 0
}

variable "vcn_cidr" {
  description = "CIDR for the VCN."
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR for the public subnet. Must sit inside vcn_cidr."
  type        = string
  default     = "10.0.0.0/24"
}

variable "wg_port" {
  description = "UDP port for WireGuard."
  type        = number
  default     = 51820
}

variable "vpn_cidr" {
  description = "WireGuard tunnel network. Must be a /24 and must not overlap vcn_cidr."
  type        = string
  default     = "10.66.66.0/24"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+\\.0/24$", var.vpn_cidr))
    error_message = "vpn_cidr must be a /24 such as 10.66.66.0/24."
  }
}

variable "client_dns" {
  description = "DNS resolvers pushed to clients."
  type        = list(string)
  default     = ["1.1.1.1", "1.0.0.1"]
}

variable "initial_clients" {
  description = "Client names created on first boot. Add more later with wgctl."
  type        = list(string)
  default     = ["laptop", "phone"]

  validation {
    condition     = alltrue([for c in var.initial_clients : can(regex("^[A-Za-z0-9_-]{1,32}$", c))])
    error_message = "Client names may only contain letters, digits, underscore and dash (max 32)."
  }
}
