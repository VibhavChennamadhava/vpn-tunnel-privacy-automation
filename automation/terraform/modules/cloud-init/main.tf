terraform {
  required_version = ">= 1.5.0"
}

locals {
  nftables_conf = templatefile("${path.module}/files/nftables.conf.tftpl", {
    wg_port  = var.wg_port
    vpn_cidr = var.vpn_cidr
  })

  wgctl_script = file("${path.module}/files/wgctl")

  ssh_hardening = <<-EOT
    # Managed by Terraform. Named 00- so it wins over the cloud image defaults
    # (sshd uses the first value it reads for each keyword).
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PermitRootLogin no
    X11Forwarding no
    MaxAuthTries 3
    LoginGraceTime 20
  EOT

  sysctl_conf = <<-EOT
    net.ipv4.ip_forward = 1
    net.ipv4.conf.all.rp_filter = 1
    net.ipv4.conf.all.accept_redirects = 0
    net.ipv4.conf.all.send_redirects = 0
  EOT

  # yamlencode guarantees valid YAML, so there is no indentation to get wrong.
  cloud_config = {
    package_update  = true
    package_upgrade = true
    packages = [
      "wireguard",
      "nftables",
      "qrencode",
      "fail2ban",
      "unattended-upgrades",
    ]
    write_files = [
      {
        path        = "/etc/sysctl.d/99-wireguard.conf"
        permissions = "0644"
        content     = local.sysctl_conf
      },
      {
        path        = "/etc/ssh/sshd_config.d/00-hardening.conf"
        permissions = "0644"
        content     = local.ssh_hardening
      },
      {
        path        = "/etc/nftables.conf"
        permissions = "0644"
        encoding    = "b64"
        content     = base64encode(local.nftables_conf)
      },
      {
        path        = "/usr/local/sbin/wgctl"
        permissions = "0750"
        owner       = "root:root"
        encoding    = "b64"
        content     = base64encode(local.wgctl_script)
      },
    ]
    runcmd = concat(
      [
        # Oracle's Ubuntu images restore iptables rules at boot and REJECT
        # everything but SSH. Replace them with the nftables ruleset above.
        "systemctl disable --now netfilter-persistent || true",
        "systemctl mask netfilter-persistent || true",
        "sysctl --system",
        "systemctl enable --now nftables",
        "nft -f /etc/nftables.conf",
        "systemctl enable --now fail2ban",
        "systemctl restart ssh || systemctl restart sshd",
        ["/usr/local/sbin/wgctl", "init", "--port", tostring(var.wg_port), "--cidr", var.vpn_cidr, "--dns", join(", ", var.client_dns)],
      ],
      [for c in var.initial_clients : ["/usr/local/sbin/wgctl", "add", c]],
      ["touch /var/lib/vpn-bootstrap.done"],
    )
  }

  user_data = "#cloud-config\n${yamlencode(local.cloud_config)}\n"
}
