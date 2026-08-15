provider "oci" {
  region              = var.region
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

# Preflight: forces an authenticated Cloudflare API call during plan/refresh, so an
# invalid or IP-blocked token fails before the instance is created or replaced.
data "cloudflare_zone" "this" {
  zone_id = var.cloudflare_zone_id
}

variable "availability_domain" {
  type        = string
  description = "OCI availability domain, for example xJLJ:US-SANJOSE-1-AD-1"
}

variable "region" {
  type        = string
  description = "OCI region identifier, for example us-sanjose-1"
}

variable "oci_config_profile" {
  type        = string
  default     = "DEFAULT"
  description = "Profile name in ~/.oci/config used for OCI API-key auth. Each region/tenancy gets its own profile so deploys do not cross tenancies."
}

variable "compartment_id" {
  type        = string
  description = "OCI compartment OCID where the instance is created"
}

variable "subnet_id" {
  type        = string
  description = "OCI subnet OCID used by the instance VNIC"
}

variable "source_image_id" {
  type        = string
  description = "OCI image OCID for the compute instance"
}

variable "ssh_authorized_keys" {
  type        = list(string)
  description = "Public SSH keys for instance access"
}

variable "hashed_password" {
  type        = string
  sensitive   = true
  description = "SHA-512 password hash for the emergency backdoor cloud-init user"
}

variable "instance_display_name" {
  type        = string
  description = "Display name for the compute instance"
}

variable "vnic_display_name" {
  type        = string
  description = "Display name for the primary VNIC"
}

variable "ipv6_subnet_cidr" {
  type        = string
  description = "IPv6 CIDR block in the subnet to assign to the VNIC"
}

variable "shape" {
  type        = string
  description = "Compute shape"
}

variable "shape_memory_in_gbs" {
  type        = number
  description = "Instance memory in GB"
}

variable "shape_ocpus" {
  type        = number
  description = "Instance OCPU count"
}

variable "boot_volume_size_in_gbs" {
  type        = number
  description = "Boot volume size in GB"
}

variable "boot_volume_vpus_per_gb" {
  type        = number
  description = "Boot volume VPUs per GB"
}

variable "wg_interface" {
  type        = string
  description = "WireGuard interface name"

  # wg_interface and wg_rate_limit interpolate unquoted into PostUp/PostDown lines that
  # wg-quick executes through a shell as root (Infrastructure/OCI/host/bootstrap.sh); this closes
  # the same shell-injection surface the address/network variables above already validate.
  validation {
    condition     = can(regex("^[a-z0-9]{1,15}$", var.wg_interface))
    error_message = "wg_interface must be 1-15 lowercase alphanumeric characters, for example wg0."
  }
}

variable "wg_listen_port" {
  type        = number
  description = "WireGuard UDP listen port"
}

variable "wg_address_v4" {
  type        = string
  description = "WireGuard server IPv4 address CIDR"

  validation {
    condition = try(
      can(cidrnetmask(var.wg_address_v4)) &&
      split("/", var.wg_address_v4)[1] == "24",
      false
    )
    error_message = "wg_address_v4 must be a valid IPv4 /24 interface CIDR, for example 10.0.1.1/24."
  }
}

variable "wg_address_v6" {
  type        = string
  description = "WireGuard server IPv6 address CIDR"

  validation {
    condition = try(
      can(cidrhost(var.wg_address_v6, 0)) &&
      !can(cidrnetmask(var.wg_address_v6)) &&
      split("/", var.wg_address_v6)[1] == "64",
      false
    )
    error_message = "wg_address_v6 must be a valid IPv6 /64 interface CIDR, for example fd42:42:42:1::1/64."
  }
}

# Cross-variable subnet consistency is also checked by scripts/terraform-preflight.py. The
# resource preconditions below keep direct Terraform plan/apply use safe on Terraform 1.6,
# without relying on newer cross-variable validation blocks.
variable "wg_network_v4" {
  type        = string
  description = "WireGuard IPv4 network CIDR for NAT"

  validation {
    condition = try(
      can(cidrnetmask(var.wg_network_v4)) &&
      var.wg_network_v4 == cidrsubnet(var.wg_network_v4, 0, 0) &&
      split("/", var.wg_network_v4)[1] == "24",
      false
    )
    error_message = "wg_network_v4 must be a canonical IPv4 /24 network address, for example 10.0.1.0/24."
  }
}

variable "wg_network_v6" {
  type        = string
  description = "WireGuard IPv6 network CIDR for NAT"

  validation {
    condition = try(
      can(cidrhost(var.wg_network_v6, 0)) &&
      !can(cidrnetmask(var.wg_network_v6)) &&
      var.wg_network_v6 == cidrsubnet(var.wg_network_v6, 0, 0) &&
      split("/", var.wg_network_v6)[1] == "64",
      false
    )
    error_message = "wg_network_v6 must be a canonical IPv6 /64 network address, for example fd42:42:42:1::/64."
  }
}

variable "wg_dns_address_v4" {
  type        = string
  description = "WireGuard DNS server IPv4 address"

  validation {
    condition     = can(cidrnetmask("${var.wg_dns_address_v4}/32"))
    error_message = "wg_dns_address_v4 must be a valid IPv4 address, for example 10.0.1.1."
  }
}

variable "wg_dns_address_v6" {
  type        = string
  description = "WireGuard DNS server IPv6 address"

  validation {
    condition = try(
      can(cidrhost("${var.wg_dns_address_v6}/128", 0)) &&
      !can(cidrnetmask("${var.wg_dns_address_v6}/128")),
      false
    )
    error_message = "wg_dns_address_v6 must be a valid IPv6 address, for example fd42:42:42:1::1."
  }
}

variable "wg_rate_limit" {
  type        = string
  description = "Rate limit for new inbound UDP packets on WireGuard port"

  validation {
    condition     = can(regex("^[0-9]+/(second|minute|hour|day)$", var.wg_rate_limit))
    error_message = "wg_rate_limit must look like <n>/second|minute|hour|day, for example 25/second."
  }
}

variable "wg_rate_limit_burst" {
  type        = number
  description = "Rate limit burst for inbound WireGuard UDP packets"
}

variable "wg_server_private_key" {
  type        = string
  sensitive   = true
  description = "WireGuard server private key used in /etc/wireguard/wg0.conf"
}

variable "adguard_home_version" {
  type        = string
  default     = "v0.107.77"
  description = "AdGuard Home version installed by the regional host bootstrap"
}

variable "source_repo" {
  type        = string
  default     = "Albro3459/CloudGateway"
  description = "Public GitHub owner/repo the host fetches bootstrap and API source from"
}

variable "source_ref" {
  type        = string
  description = "Git ref fetched at boot: a pushed tag like deploy-v1.0.0, a full commit SHA, or a branch name. See docs/github-deployment-setup.md"
}

variable "region_id" {
  type        = string
  description = "CloudGateway region ID used by the regional API, for example us-sanjose-1"
}

variable "api_hostname" {
  type        = string
  description = "Public regional API hostname served by Caddy, for example us-sanjose-1.gocloudlaunch.com"
}

variable "dashboard_cors_origin" {
  type        = string
  description = "Exact dashboard URL allowed for browser CORS requests and used as the access email login link. Must be one URL with no globs, wildcards, patterns, or comma-separated origins, for example https://gocloudlaunch.com"
}

variable "fastapi_port" {
  type        = number
  default     = 8000
  description = "Localhost port the FastAPI control plane binds to"
}

variable "wg_endpoint_hostname" {
  type        = string
  description = "Non-proxied DNS hostname written into WireGuard client configs, for example wg.us-sanjose-1.gocloudlaunch.com"
}

variable "firebase_credentials_file" {
  type        = string
  default     = "/etc/cloudgateway/firebase-credentials.json"
  description = "Host path for the Firebase Admin credential file"
}

variable "firebase_credentials_json" {
  type        = string
  sensitive   = true
  default     = ""
  description = "Firebase Admin credential JSON written to the credential file; leave empty to provision the file manually"
}

variable "origin_cert_path" {
  type        = string
  default     = "/etc/caddy/origin-cert.pem"
  description = "Host path for the Cloudflare Origin CA certificate served by Caddy"
}

variable "origin_key_path" {
  type        = string
  default     = "/etc/caddy/origin-key.pem"
  description = "Host path for the Cloudflare Origin CA private key served by Caddy"
}

variable "origin_cert" {
  type        = string
  sensitive   = true
  description = "Cloudflare Origin CA certificate (PEM) Caddy serves on the origin TLS hop. ACME cannot validate a proxied hostname, so the origin uses this Cloudflare-issued cert."
}

variable "origin_key" {
  type        = string
  sensitive   = true
  description = "Cloudflare Origin CA private key (PEM) paired with origin_cert"
}

variable "region_display_name" {
  type        = string
  description = "Human-readable region name written to the Firestore region doc by cloudgateway-register-region"
}

variable "region_display_order" {
  type        = number
  default     = 1000
  description = "Dashboard sort order for the region; lower sorts first"
}

variable "region_capacity_limit" {
  type        = number
  default     = 20
  description = "Server capacity: maximum allocated clients for the region"
}

variable "ses_region" {
  type        = string
  description = "AWS region for SES deployment notification emails"
}

variable "ses_sender" {
  type        = string
  description = "Verified SES sender identity used for deployment notification emails"
}

variable "aws_access_key_id" {
  type        = string
  sensitive   = true
  description = "AWS access key ID for SES deployment notification emails"
}

variable "aws_secret_access_key" {
  type        = string
  sensitive   = true
  description = "AWS secret access key for SES deployment notification emails"
}

variable "cloudflare_api_token" {
  type        = string
  sensitive   = true
  description = "Cloudflare API token (Zone: gocloudlaunch.com -> DNS: Edit). Used only on the operator machine to manage the region's DNS records; never written to the host."
}

variable "cloudflare_zone_id" {
  type        = string
  description = "Cloudflare zone ID that owns the region DNS records (the gocloudlaunch.com zone)"
}

variable "caddy_acme_email" {
  type        = string
  default     = ""
  description = "Email used by Caddy ACME for the regional API hostname"
}

variable "cloudflare_origin_pull_ca_path" {
  type        = string
  default     = "/etc/caddy/cloudflare-origin-pull-ca.pem"
  description = "Host path for the Cloudflare Authenticated Origin Pull CA"
}

variable "cloudflare_origin_pull_ca_url" {
  type        = string
  default     = "https://developers.cloudflare.com/ssl/static/authenticated_origin_pull_ca.pem"
  description = "Download URL for the Cloudflare Authenticated Origin Pull CA"
}

variable "caddy_binary_tag" {
  type        = string
  description = "GitHub Release tag containing the prebuilt CloudGateway Caddy binary, for example caddy-v1.0.0"

  validation {
    condition     = can(regex("^caddy-v[0-9]+[.][0-9]+[.][0-9]+$", var.caddy_binary_tag))
    error_message = "caddy_binary_tag must look like caddy-vX.Y.Z."
  }
}

variable "caddy_binary_sha256" {
  type        = string
  description = "SHA-256 hex digest of the cloudgateway-caddy-linux-arm64 release asset"

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.caddy_binary_sha256))
    error_message = "caddy_binary_sha256 must be a lowercase 64-character SHA-256 hex digest."
  }
}

variable "caddy_api_rate_limit_events" {
  type        = number
  default     = 300
  description = "Maximum API requests allowed per Cloudflare client IP in the Caddy rate-limit window"
}

variable "caddy_api_rate_limit_window" {
  type        = string
  default     = "1m"
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
  subnet_registry         = jsondecode(file("${path.module}/subnet-registry.json"))
  subnet_registry_regions = try(local.subnet_registry.regions, [])
  selected_registry_regions = [
    for registry_region in local.subnet_registry_regions : registry_region
    if try(registry_region.region_id, "") == var.region_id
  ]
  selected_registry = try(local.selected_registry_regions[0], {})

  wg_network_v4_valid = try(
    cidrnetmask(var.wg_network_v4) != "" &&
    var.wg_network_v4 == cidrsubnet(var.wg_network_v4, 0, 0) &&
    split("/", var.wg_network_v4)[1] == "24",
    false
  )
  wg_network_v6_valid = try(
    cidrhost(var.wg_network_v6, 0) != "" &&
    !can(cidrnetmask(var.wg_network_v6)) &&
    var.wg_network_v6 == cidrsubnet(var.wg_network_v6, 0, 0) &&
    split("/", var.wg_network_v6)[1] == "64",
    false
  )
  wg_address_v4_valid = try(
    cidrnetmask(var.wg_address_v4) != "" &&
    split("/", var.wg_address_v4)[1] == "24",
    false
  )
  wg_address_v6_valid = try(
    cidrhost(var.wg_address_v6, 0) != "" &&
    !can(cidrnetmask(var.wg_address_v6)) &&
    split("/", var.wg_address_v6)[1] == "64",
    false
  )
  wg_address_v4_network_matches = try(
    cidrsubnet(var.wg_address_v4, 0, 0) == var.wg_network_v4,
    false
  )
  wg_address_v6_network_matches = try(
    cidrsubnet(var.wg_address_v6, 0, 0) == var.wg_network_v6,
    false
  )
  wg_dns_address_v4_valid = try(cidrnetmask("${var.wg_dns_address_v4}/32") != "", false)
  wg_dns_address_v6_valid = try(
    cidrhost("${var.wg_dns_address_v6}/128", 0) != "" &&
    !can(cidrnetmask("${var.wg_dns_address_v6}/128")),
    false
  )
  wg_address_v4_is_first_host = try(
    cidrhost("${split("/", var.wg_address_v4)[0]}/32", 0) == cidrhost(var.wg_network_v4, 1),
    false
  )
  wg_address_v6_is_first_host = try(
    cidrhost("${split("/", var.wg_address_v6)[0]}/128", 0) == cidrhost(var.wg_network_v6, 1),
    false
  )
  wg_dns_v4_matches_interface = try(
    cidrhost("${split("/", var.wg_address_v4)[0]}/32", 0) == cidrhost("${var.wg_dns_address_v4}/32", 0),
    false
  )
  wg_dns_v6_matches_interface = try(
    cidrhost("${split("/", var.wg_address_v6)[0]}/128", 0) == cidrhost("${var.wg_dns_address_v6}/128", 0),
    false
  )

  backdoor_user_data = templatefile("${path.module}/backdoor-cloud-init.yaml", {
    hashed_password = var.hashed_password
  })

  wireguard_user_data = templatefile("${path.module}/stub-cloud-init.sh.tftpl", {
    source_repo                    = var.source_repo
    source_ref                     = var.source_ref
    wg_interface                   = var.wg_interface
    wg_listen_port                 = var.wg_listen_port
    wg_address_v4                  = var.wg_address_v4
    wg_address_v6                  = var.wg_address_v6
    wg_dns_address_v4              = var.wg_dns_address_v4
    wg_dns_address_v6              = var.wg_dns_address_v6
    wg_network_v4                  = var.wg_network_v4
    wg_network_v6                  = var.wg_network_v6
    wg_server_private_key          = var.wg_server_private_key
    wg_rate_limit                  = var.wg_rate_limit
    wg_rate_limit_burst            = var.wg_rate_limit_burst
    adguard_home_version           = var.adguard_home_version
    region_id                      = var.region_id
    api_hostname                   = var.api_hostname
    dashboard_cors_origin          = var.dashboard_cors_origin
    fastapi_port                   = var.fastapi_port
    wg_endpoint_hostname           = var.wg_endpoint_hostname
    firebase_credentials_file      = var.firebase_credentials_file
    firebase_credentials_json      = var.firebase_credentials_json
    origin_cert                    = var.origin_cert
    origin_key                     = var.origin_key
    origin_cert_path               = var.origin_cert_path
    origin_key_path                = var.origin_key_path
    region_display_name            = var.region_display_name
    region_display_order           = var.region_display_order
    region_capacity_limit          = var.region_capacity_limit
    ses_region                     = var.ses_region
    ses_sender                     = var.ses_sender
    aws_access_key_id              = var.aws_access_key_id
    aws_secret_access_key          = var.aws_secret_access_key
    caddy_acme_email               = var.caddy_acme_email
    cloudflare_origin_pull_ca_path = var.cloudflare_origin_pull_ca_path
    cloudflare_origin_pull_ca_url  = var.cloudflare_origin_pull_ca_url
    caddy_binary_tag               = var.caddy_binary_tag
    caddy_binary_sha256            = var.caddy_binary_sha256
    caddy_api_rate_limit_events    = var.caddy_api_rate_limit_events
    caddy_api_rate_limit_window    = var.caddy_api_rate_limit_window
    cloudflare_ipv4_ranges         = var.cloudflare_ipv4_ranges
    cloudflare_ipv6_ranges         = var.cloudflare_ipv6_ranges
  })

  combined_user_data = <<-EOT
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="==CLOUDGATEWAY_BOUNDARY=="

--==CLOUDGATEWAY_BOUNDARY==
Content-Type: text/cloud-config; charset="us-ascii"

${trimspace(local.backdoor_user_data)}

--==CLOUDGATEWAY_BOUNDARY==
Content-Type: text/x-shellscript; charset="us-ascii"

${trimspace(local.wireguard_user_data)}

--==CLOUDGATEWAY_BOUNDARY==--
EOT
}

resource "oci_core_instance" "generated_oci_core_instance" {
  lifecycle {
    precondition {
      condition     = local.wg_network_v4_valid && local.wg_network_v6_valid
      error_message = "wg_network_v4 must be canonical IPv4 /24 and wg_network_v6 must be canonical IPv6 /64 networks."
    }
    precondition {
      condition     = local.wg_address_v4_valid && local.wg_address_v6_valid
      error_message = "wg_address_v4 must be an IPv4 interface with /24 and wg_address_v6 must be an IPv6 interface with /64."
    }
    precondition {
      condition     = local.wg_address_v4_is_first_host && local.wg_address_v6_is_first_host
      error_message = "wg_address_v4/v6 must use the first host address (.1/::1) of their exact networks."
    }
    precondition {
      condition     = local.wg_address_v4_network_matches && local.wg_address_v6_network_matches
      error_message = "wg_address_v4/v6 must derive exactly wg_network_v4/v6."
    }
    precondition {
      condition     = local.wg_dns_address_v4_valid && local.wg_dns_address_v6_valid
      error_message = "wg_dns_address_v4 and wg_dns_address_v6 must be plain addresses of the expected family."
    }
    precondition {
      condition     = local.wg_dns_v4_matches_interface && local.wg_dns_v6_matches_interface
      error_message = "Each WireGuard DNS address must equal its corresponding interface IP."
    }
    precondition {
      condition = length(local.selected_registry_regions) == 1 && try(
        local.selected_registry.status == "active" &&
        local.selected_registry.wg_network_v4 == var.wg_network_v4 &&
        local.selected_registry.wg_network_v6 == var.wg_network_v6,
        false
      )
      error_message = "region_id must select one active subnet-registry allocation, and wg_network_v4/v6 must match it exactly."
    }
  }

  agent_config {
    is_management_disabled = "false"
    is_monitoring_disabled = "false"
    plugins_config {
      desired_state = "DISABLED"
      name          = "Vulnerability Scanning"
    }
    plugins_config {
      desired_state = "DISABLED"
      name          = "Management Agent"
    }
    plugins_config {
      desired_state = "ENABLED"
      name          = "Custom Logs Monitoring"
    }
    plugins_config {
      desired_state = "DISABLED"
      name          = "Compute RDMA GPU Monitoring"
    }
    plugins_config {
      desired_state = "ENABLED"
      name          = "Compute Instance Monitoring"
    }
    plugins_config {
      desired_state = "DISABLED"
      name          = "Compute HPC RDMA Auto-Configuration"
    }
    plugins_config {
      desired_state = "DISABLED"
      name          = "Compute HPC RDMA Authentication"
    }
    plugins_config {
      desired_state = "ENABLED"
      name          = "Cloud Guard Workload Protection"
    }
    plugins_config {
      desired_state = "DISABLED"
      name          = "Block Volume Management"
    }
    plugins_config {
      desired_state = "DISABLED"
      name          = "Bastion"
    }
  }
  availability_config {
    recovery_action = "RESTORE_INSTANCE"
  }
  availability_domain = var.availability_domain
  compartment_id      = var.compartment_id
  create_vnic_details {
    assign_ipv6ip             = "true"
    assign_private_dns_record = "true"
    assign_public_ip          = "true"
    display_name              = var.vnic_display_name
    ipv6address_ipv6subnet_cidr_pair_details {
      ipv6subnet_cidr = var.ipv6_subnet_cidr
    }
    subnet_id = var.subnet_id
  }
  display_name = var.instance_display_name
  freeform_tags = {
    CloudGatewayManaged = "true"
  }
  instance_options {
    are_legacy_imds_endpoints_disabled = "false"
  }
  is_pv_encryption_in_transit_enabled = "true"
  metadata = {
    "ssh_authorized_keys" = join("\n", var.ssh_authorized_keys)
    "user_data"           = base64encode(local.combined_user_data)
  }
  shape = var.shape
  shape_config {
    memory_in_gbs = var.shape_memory_in_gbs
    ocpus         = var.shape_ocpus
  }
  source_details {
    boot_volume_size_in_gbs = var.boot_volume_size_in_gbs
    boot_volume_vpus_per_gb = var.boot_volume_vpus_per_gb
    source_id               = var.source_image_id
    source_type             = "image"
  }
}

# Regional DNS, managed from the operator machine (token never reaches the host).
# Both point at this instance's public IPv4 and update automatically on rebuild.
resource "cloudflare_record" "api" {
  zone_id         = data.cloudflare_zone.this.id
  name            = var.api_hostname
  type            = "A"
  content         = oci_core_instance.generated_oci_core_instance.public_ip
  proxied         = true
  ttl             = 1
  allow_overwrite = true
  comment         = "CloudGateway regional API (Terraform-managed)"
}

resource "cloudflare_record" "wg" {
  zone_id         = data.cloudflare_zone.this.id
  name            = var.wg_endpoint_hostname
  type            = "A"
  content         = oci_core_instance.generated_oci_core_instance.public_ip
  proxied         = false
  ttl             = 300
  allow_overwrite = true
  comment         = "CloudGateway WireGuard endpoint, grey-cloud (Terraform-managed)"
}
