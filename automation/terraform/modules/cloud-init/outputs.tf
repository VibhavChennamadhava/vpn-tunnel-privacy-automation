output "user_data" {
  description = "Rendered cloud-config (plain text)."
  value       = local.user_data
}

output "user_data_base64" {
  description = "Rendered cloud-config, base64 encoded for the OCI metadata field."
  value       = base64encode(local.user_data)
}
