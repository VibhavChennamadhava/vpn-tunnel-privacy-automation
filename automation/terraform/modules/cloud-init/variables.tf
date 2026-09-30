variable "wg_port" {
  description = "UDP port WireGuard listens on."
  type        = number
  default     = 51820
}

variable "vpn_cidr" {
  description = "WireGuard tunnel network. Must be a /24. The server takes .1."
  type        = string
  default     = "10.66.66.0/24"
}

variable "client_dns" {
  description = "DNS resolvers pushed to clients."
  type        = list(string)
  default     = ["1.1.1.1", "1.0.0.1"]
}

variable "initial_clients" {
  description = "Client names to create on first boot."
  type        = list(string)
  default     = ["laptop", "phone"]
}
