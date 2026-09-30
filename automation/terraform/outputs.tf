output "public_ip" {
  description = "Public address of the VPN server."
  value       = oci_core_instance.vpn.public_ip
}

output "ssh_command" {
  description = "SSH into the server (allowed only from admin_cidr)."
  value       = "ssh ubuntu@${oci_core_instance.vpn.public_ip}"
}

output "next_steps" {
  description = "What to do after apply finishes."
  value       = <<-EOT
    1. Wait 2 to 4 minutes for first-boot setup, then confirm it finished:
         ssh ubuntu@${oci_core_instance.vpn.public_ip} 'cloud-init status --wait && ls /var/lib/vpn-bootstrap.done'
    2. Fetch a client config (the script saves it to ./clients/laptop.conf):
         ./automation/scripts/new-client.sh -H ${oci_core_instance.vpn.public_ip} laptop
    3. Record your real IP first, import the config in WireGuard, connect, then check:
         ./automation/scripts/verify-vpn.sh baseline
         ./automation/scripts/verify-vpn.sh check --expect ${oci_core_instance.vpn.public_ip}
    4. Tear everything down when you are done:
         terraform destroy
  EOT
}
