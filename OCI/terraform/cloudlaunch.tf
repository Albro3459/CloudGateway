provider "oci" {
	region = var.region
}

terraform {
  required_providers {
    oci = {
      source = "oracle/oci"
    }
  }
}

variable "availability_domain" {
	type = string
	description = "OCI availability domain, for example xJLJ:US-SANJOSE-1-AD-1"
}

variable "region" {
	type = string
	description = "OCI region identifier, for example us-sanjose-1"
}

variable "compartment_id" {
	type = string
	description = "OCI compartment OCID where the instance is created"
}

variable "subnet_id" {
	type = string
	description = "OCI subnet OCID used by the instance VNIC"
}

variable "source_image_id" {
	type = string
	description = "OCI image OCID for the compute instance"
}

variable "ssh_authorized_keys" {
	type = list(string)
	description = "Public SSH keys for instance access"
}

variable "hashed_password" {
	type = string
	sensitive = true
	description = "SHA-512 password hash for the emergency backdoor cloud-init user"
}

variable "instance_display_name" {
	type = string
	description = "Display name for the compute instance"
}

variable "vnic_display_name" {
	type = string
	description = "Display name for the primary VNIC"
}

variable "ipv6_subnet_cidr" {
	type = string
	description = "IPv6 CIDR block in the subnet to assign to the VNIC"
}

variable "shape" {
	type = string
	description = "Compute shape"
}

variable "shape_memory_in_gbs" {
	type = number
	description = "Instance memory in GB"
}

variable "shape_ocpus" {
	type = number
	description = "Instance OCPU count"
}

variable "boot_volume_size_in_gbs" {
	type = number
	description = "Boot volume size in GB"
}

variable "boot_volume_vpus_per_gb" {
	type = number
	description = "Boot volume VPUs per GB"
}

variable "wg_interface" {
	type = string
	description = "WireGuard interface name"
}

variable "wg_listen_port" {
	type = number
	description = "WireGuard UDP listen port"
}

variable "wg_address_v4" {
	type = string
	description = "WireGuard server IPv4 address CIDR"
}

variable "wg_address_v6" {
	type = string
	description = "WireGuard server IPv6 address CIDR"
}

variable "wg_network_v4" {
	type = string
	description = "WireGuard IPv4 network CIDR for NAT"
}

variable "wg_network_v6" {
	type = string
	description = "WireGuard IPv6 network CIDR for NAT"
}

variable "wg_dns_address_v4" {
	type = string
	description = "WireGuard DNS server IPv4 address"
}

variable "wg_dns_address_v6" {
	type = string
	description = "WireGuard DNS server IPv6 address"
}

variable "wg_rate_limit" {
	type = string
	description = "Rate limit for new inbound UDP packets on WireGuard port"
}

variable "wg_rate_limit_burst" {
	type = number
	description = "Rate limit burst for inbound WireGuard UDP packets"
}

variable "wg_server_private_key" {
	type = string
	sensitive = true
	description = "WireGuard server private key used in /etc/wireguard/wg0.conf"
}

variable "region_id" {
	type = string
	description = "CloudLaunch region ID used by the regional API, for example us-sanjose-1"
}

variable "api_hostname" {
	type = string
	description = "Public regional API hostname served by Caddy, for example us-sanjose-1.gateway.gocloudlaunch.com"
}

variable "dashboard_cors_origin" {
	type = string
	description = "Dashboard origin allowed for browser CORS requests, for example https://gateway.gocloudlaunch.com"
}

variable "fastapi_port" {
	type = number
	default = 8000
	description = "Localhost port the FastAPI control plane binds to"
}

variable "wg_endpoint_ipv4" {
	type = string
	description = "Public IPv4 endpoint written into WireGuard client configs"
}

variable "firebase_credentials_file" {
	type = string
	default = "/etc/cloudlaunch/firebase-credentials.json"
	description = "Host path for the Firebase Admin credential file"
}

variable "firebase_credentials_json" {
	type = string
	sensitive = true
	default = ""
	description = "Firebase Admin credential JSON written to the credential file; leave empty to provision the file manually"
}

variable "caddy_acme_email" {
	type = string
	default = ""
	description = "Placeholder email for the later Caddy ACME configuration"
}

variable "cloudflare_origin_pull_ca_path" {
	type = string
	default = "/etc/caddy/cloudflare-origin-pull-ca.pem"
	description = "Placeholder path for the later Cloudflare Authenticated Origin Pull CA"
}

locals {
	api_source_files = {
		for source_path in setunion(
			fileset("${path.module}/../../API", "pyproject.toml"),
			fileset("${path.module}/../../API", "cloudlaunch_api/*.py")
		) : source_path => filebase64("${path.module}/../../API/${source_path}")
	}

	backdoor_user_data = templatefile("${path.module}/backdoor-cloud-init.yaml", {
		hashed_password = var.hashed_password
	})

	wireguard_user_data = templatefile("${path.module}/wireguard-cloud-init.sh.tftpl", {
		wg_interface = var.wg_interface
		wg_listen_port = var.wg_listen_port
		wg_address_v4 = var.wg_address_v4
		wg_address_v6 = var.wg_address_v6
		wg_dns_address_v4 = var.wg_dns_address_v4
		wg_dns_address_v6 = var.wg_dns_address_v6
		wg_network_v4 = var.wg_network_v4
		wg_network_v6 = var.wg_network_v6
		wg_server_private_key = var.wg_server_private_key
		wg_rate_limit = var.wg_rate_limit
		wg_rate_limit_burst = var.wg_rate_limit_burst
		region_id = var.region_id
		api_hostname = var.api_hostname
		dashboard_cors_origin = var.dashboard_cors_origin
		fastapi_port = var.fastapi_port
		wg_endpoint_ipv4 = var.wg_endpoint_ipv4
		firebase_credentials_file = var.firebase_credentials_file
		firebase_credentials_json = var.firebase_credentials_json
		caddy_acme_email = var.caddy_acme_email
		cloudflare_origin_pull_ca_path = var.cloudflare_origin_pull_ca_path
		api_source_files = local.api_source_files
	})

	combined_user_data = <<-EOT
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="==CLOUDLAUNCH_BOUNDARY=="

--==CLOUDLAUNCH_BOUNDARY==
Content-Type: text/cloud-config; charset="us-ascii"

${trimspace(local.backdoor_user_data)}

--==CLOUDLAUNCH_BOUNDARY==
Content-Type: text/x-shellscript; charset="us-ascii"

${trimspace(local.wireguard_user_data)}

--==CLOUDLAUNCH_BOUNDARY==--
EOT
}

resource "oci_core_instance" "generated_oci_core_instance" {
	agent_config {
		is_management_disabled = "false"
		is_monitoring_disabled = "false"
		plugins_config {
			desired_state = "DISABLED"
			name = "Vulnerability Scanning"
		}
		plugins_config {
			desired_state = "DISABLED"
			name = "Management Agent"
		}
		plugins_config {
			desired_state = "ENABLED"
			name = "Custom Logs Monitoring"
		}
		plugins_config {
			desired_state = "DISABLED"
			name = "Compute RDMA GPU Monitoring"
		}
		plugins_config {
			desired_state = "ENABLED"
			name = "Compute Instance Monitoring"
		}
		plugins_config {
			desired_state = "DISABLED"
			name = "Compute HPC RDMA Auto-Configuration"
		}
		plugins_config {
			desired_state = "DISABLED"
			name = "Compute HPC RDMA Authentication"
		}
		plugins_config {
			desired_state = "ENABLED"
			name = "Cloud Guard Workload Protection"
		}
		plugins_config {
			desired_state = "DISABLED"
			name = "Block Volume Management"
		}
		plugins_config {
			desired_state = "DISABLED"
			name = "Bastion"
		}
	}
	availability_config {
		recovery_action = "RESTORE_INSTANCE"
	}
	availability_domain = var.availability_domain
	compartment_id = var.compartment_id
	create_vnic_details {
		assign_ipv6ip = "true"
		assign_private_dns_record = "true"
		assign_public_ip = "true"
		display_name = var.vnic_display_name
		ipv6address_ipv6subnet_cidr_pair_details {
			ipv6subnet_cidr = var.ipv6_subnet_cidr
		}
		subnet_id = var.subnet_id
	}
	display_name = var.instance_display_name
	instance_options {
		are_legacy_imds_endpoints_disabled = "false"
	}
	is_pv_encryption_in_transit_enabled = "true"
	metadata = {
		"ssh_authorized_keys" = join("\n", var.ssh_authorized_keys)
		"user_data" = base64encode(local.combined_user_data)
	}
	shape = var.shape
	shape_config {
		memory_in_gbs = var.shape_memory_in_gbs
		ocpus = var.shape_ocpus
	}
	source_details {
		boot_volume_size_in_gbs = var.boot_volume_size_in_gbs
		boot_volume_vpus_per_gb = var.boot_volume_vpus_per_gb
		source_id = var.source_image_id
		source_type = "image"
	}
}
