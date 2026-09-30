data "oci_identity_availability_domains" "ads" {
  compartment_id = var.compartment_ocid
}

data "oci_core_images" "ubuntu" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = var.ubuntu_version
  shape                    = var.shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

locals {
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[var.availability_domain_index].name
  image_id            = data.oci_core_images.ubuntu.images[0].id
  is_flex_shape       = endswith(var.shape, ".Flex")
}

module "cloud_init" {
  source = "./modules/cloud-init"

  wg_port         = var.wg_port
  vpn_cidr        = var.vpn_cidr
  client_dns      = var.client_dns
  initial_clients = var.initial_clients
}

# Network ---------------------------------------------------------------------

resource "oci_core_vcn" "this" {
  compartment_id = var.compartment_ocid
  cidr_blocks    = [var.vcn_cidr]
  display_name   = "${var.name_prefix}-vcn"
  dns_label      = "wgvpn"
}

resource "oci_core_internet_gateway" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name_prefix}-igw"
  enabled        = true
}

resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name_prefix}-public-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.this.id
  }
}

# Two inbound holes only: SSH from the admin network, WireGuard from anywhere.
# There is no admin web interface to expose. Compare with the lab, where TCP 943
# and 443 were open to 0.0.0.0/0.
resource "oci_core_security_list" "vpn" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name_prefix}-sl"

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
    stateless   = false
    description = "Allow all outbound"
  }

  ingress_security_rules {
    protocol    = "6" # TCP
    source      = var.admin_cidr
    stateless   = false
    description = "SSH from the admin network only"

    tcp_options {
      min = 22
      max = 22
    }
  }

  ingress_security_rules {
    protocol    = "17" # UDP
    source      = "0.0.0.0/0"
    stateless   = false
    description = "WireGuard"

    udp_options {
      min = var.wg_port
      max = var.wg_port
    }
  }

  ingress_security_rules {
    protocol    = "1" # ICMP
    source      = "0.0.0.0/0"
    stateless   = false
    description = "Path MTU discovery (fragmentation needed)"

    icmp_options {
      type = 3
      code = 4
    }
  }
}

resource "oci_core_subnet" "public" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.this.id
  cidr_block                 = var.subnet_cidr
  display_name               = "${var.name_prefix}-public"
  dns_label                  = "pub"
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_security_list.vpn.id]
  prohibit_public_ip_on_vnic = false
}

# Compute ---------------------------------------------------------------------

resource "oci_core_instance" "vpn" {
  compartment_id      = var.compartment_ocid
  availability_domain = local.availability_domain
  display_name        = "${var.name_prefix}-server"
  shape               = var.shape

  dynamic "shape_config" {
    for_each = local.is_flex_shape ? [1] : []
    content {
      ocpus         = var.ocpus
      memory_in_gbs = var.memory_gb
    }
  }

  source_details {
    source_type = "image"
    source_id   = local.image_id
  }

  create_vnic_details {
    subnet_id              = oci_core_subnet.public.id
    assign_public_ip       = true
    display_name           = "${var.name_prefix}-vnic"
    hostname_label         = "wg"
    skip_source_dest_check = false
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data           = module.cloud_init.user_data_base64
  }

  # Turn off the legacy (v1) metadata service. Only IMDSv2 is reachable.
  instance_options {
    are_legacy_imds_endpoints_disabled = true
  }

  is_pv_encryption_in_transit_enabled = true
  preserve_boot_volume                = false

  lifecycle {
    # A newer Ubuntu image appearing in the catalog must not replace the server.
    ignore_changes = [source_details[0].source_id]
  }
}
