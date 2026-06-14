provider "oci" {
	region = var.region
	config_file_profile = var.oci_config_profile
}

terraform {
  required_providers {
    oci = {
      source = "oracle/oci"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.40"
    }
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

variable "availability_domain" {
	type = string
	description = "OCI availability domain, for example xJLJ:US-SANJOSE-1-AD-1"
}

variable "region" {
	type = string
	description = "OCI region identifier, for example us-sanjose-1"
}

variable "oci_config_profile" {
	type = string
	default = "DEFAULT"
	description = "Profile name in ~/.oci/config used for OCI API-key auth. Each region/tenancy gets its own profile so deploys do not cross tenancies."
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

variable "adguard_home_version" {
	type = string
	default = "v0.107.77"
	description = "AdGuard Home version installed by the regional host bootstrap"
}

variable "source_repo" {
	type = string
	default = "Albro3459/CloudGateway"
	description = "Public GitHub owner/repo the host fetches bootstrap and API source from"
}

variable "source_ref" {
	type = string
	description = "Git ref fetched at boot: a pushed tag like deploy-v1.0.0, a full commit SHA, or a branch name. See docs/github-deployment-setup.md"
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

variable "wg_endpoint_hostname" {
	type = string
	description = "Non-proxied DNS hostname written into WireGuard client configs, for example wg.us-sanjose-1.gateway.gocloudlaunch.com"
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

variable "origin_cert_path" {
	type = string
	default = "/etc/caddy/origin-cert.pem"
	description = "Host path for the Cloudflare Origin CA certificate served by Caddy"
}

variable "origin_key_path" {
	type = string
	default = "/etc/caddy/origin-key.pem"
	description = "Host path for the Cloudflare Origin CA private key served by Caddy"
}

variable "origin_cert" {
	type = string
	sensitive = true
	description = "Cloudflare Origin CA certificate (PEM) Caddy serves on the origin TLS hop. ACME cannot validate a proxied hostname, so the origin uses this Cloudflare-issued cert."
}

variable "origin_key" {
	type = string
	sensitive = true
	description = "Cloudflare Origin CA private key (PEM) paired with origin_cert"
}

variable "region_display_name" {
	type = string
	description = "Human-readable region name written to the Firestore region doc by cloudlaunch-register-region"
}

variable "region_display_order" {
	type = number
	default = 1000
	description = "Dashboard sort order for the region; lower sorts first"
}

variable "region_capacity_limit" {
	type = number
	default = 20
	description = "Server capacity: maximum allocated clients for the region"
}

variable "region_user_client_limit" {
	type = number
	default = 3
	description = "Maximum active clients per normal user in the region"
}

variable "cloudflare_api_token" {
	type = string
	sensitive = true
	description = "Cloudflare API token (Zone: gocloudlaunch.com -> DNS: Edit). Used only on the operator machine to manage the region's DNS records; never written to the host."
}

variable "cloudflare_zone_id" {
	type = string
	description = "Cloudflare zone ID that owns the region DNS records (the gocloudlaunch.com zone)"
}

variable "caddy_acme_email" {
	type = string
	default = ""
	description = "Email used by Caddy ACME for the regional API hostname"
}

variable "cloudflare_origin_pull_ca_path" {
	type = string
	default = "/etc/caddy/cloudflare-origin-pull-ca.pem"
	description = "Host path for the Cloudflare Authenticated Origin Pull CA"
}

variable "cloudflare_origin_pull_ca_url" {
	type = string
	default = "https://developers.cloudflare.com/ssl/static/authenticated_origin_pull_ca.pem"
	description = "Download URL for the Cloudflare Authenticated Origin Pull CA"
}

variable "caddy_version" {
	type = string
	default = "v2.8.4"
	description = "Caddy version built by xcaddy"
}

variable "xcaddy_version" {
	type = string
	default = "latest"
	description = "xcaddy version installed by go install"
}

variable "caddy_rate_limit_module" {
	type = string
	default = "github.com/mholt/caddy-ratelimit"
	description = "xcaddy module path for Caddy API rate limiting"
}

variable "caddy_api_rate_limit_events" {
	type = number
	default = 300
	description = "Maximum API requests allowed per Cloudflare client IP in the Caddy rate-limit window"
}

variable "caddy_api_rate_limit_window" {
	type = string
	default = "1m"
	description = "Caddy rate-limit window for /api/*"
}

variable "cloudflare_ipv4_ranges" {
	type = list(string)
	default = [
		"173.245.48.0/20",
		"103.21.244.0/22",
		"103.22.200.0/22",
		"103.31.4.0/22",
		"141.101.64.0/18",
		"108.162.192.0/18",
		"190.93.240.0/20",
		"188.114.96.0/20",
		"197.234.240.0/22",
		"198.41.128.0/17",
		"162.158.0.0/15",
		"104.16.0.0/13",
		"104.24.0.0/14",
		"172.64.0.0/13",
		"131.0.72.0/22",
	]
	description = "Cloudflare IPv4 CIDR ranges allowed to reach origin HTTP/HTTPS"
}

variable "cloudflare_ipv6_ranges" {
	type = list(string)
	default = [
		"2400:cb00::/32",
		"2606:4700::/32",
		"2803:f800::/32",
		"2405:b500::/32",
		"2405:8100::/32",
		"2a06:98c0::/29",
		"2c0f:f248::/32",
	]
	description = "Cloudflare IPv6 CIDR ranges allowed to reach origin HTTP/HTTPS"
}

locals {
	backdoor_user_data = templatefile("${path.module}/backdoor-cloud-init.yaml", {
		hashed_password = var.hashed_password
	})

	wireguard_user_data = templatefile("${path.module}/stub-cloud-init.sh.tftpl", {
		source_repo = var.source_repo
		source_ref = var.source_ref
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
		adguard_home_version = var.adguard_home_version
		region_id = var.region_id
		api_hostname = var.api_hostname
		dashboard_cors_origin = var.dashboard_cors_origin
		fastapi_port = var.fastapi_port
		wg_endpoint_hostname = var.wg_endpoint_hostname
		firebase_credentials_file = var.firebase_credentials_file
		firebase_credentials_json = var.firebase_credentials_json
		origin_cert = var.origin_cert
		origin_key = var.origin_key
		origin_cert_path = var.origin_cert_path
		origin_key_path = var.origin_key_path
		region_display_name = var.region_display_name
		region_display_order = var.region_display_order
		region_capacity_limit = var.region_capacity_limit
		region_user_client_limit = var.region_user_client_limit
		caddy_acme_email = var.caddy_acme_email
		cloudflare_origin_pull_ca_path = var.cloudflare_origin_pull_ca_path
		cloudflare_origin_pull_ca_url = var.cloudflare_origin_pull_ca_url
		caddy_version = var.caddy_version
		xcaddy_version = var.xcaddy_version
		caddy_rate_limit_module = var.caddy_rate_limit_module
		caddy_api_rate_limit_events = var.caddy_api_rate_limit_events
		caddy_api_rate_limit_window = var.caddy_api_rate_limit_window
		cloudflare_ipv4_ranges = var.cloudflare_ipv4_ranges
		cloudflare_ipv6_ranges = var.cloudflare_ipv6_ranges
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

# Regional DNS, managed from the operator machine (token never reaches the host).
# Both point at this instance's public IPv4 and update automatically on rebuild.
resource "cloudflare_record" "api" {
	zone_id = var.cloudflare_zone_id
	name    = var.api_hostname
	type    = "A"
	content = oci_core_instance.generated_oci_core_instance.public_ip
	proxied = true
	ttl     = 1
	comment = "CloudLaunch regional API (Terraform-managed)"
}

resource "cloudflare_record" "wg" {
	zone_id = var.cloudflare_zone_id
	name    = var.wg_endpoint_hostname
	type    = "A"
	content = oci_core_instance.generated_oci_core_instance.public_ip
	proxied = false
	ttl     = 300
	comment = "CloudLaunch WireGuard endpoint, grey-cloud (Terraform-managed)"
}
