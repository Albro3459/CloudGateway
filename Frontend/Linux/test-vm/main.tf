# One throwaway Ubuntu VM that installs a published CloudGateway for Linux
# release at first boot. See README.md

terraform {
  required_providers {
    oci = {
      source = "oracle/oci"
    }
  }
}

provider "oci" {
  region              = var.region
  config_file_profile = var.oci_config_profile
}

variable "region" {
  type        = string
  description = "OCI region identifier, for example us-chicago-1"
}

variable "oci_config_profile" {
  type        = string
  default     = "DEFAULT"
  description = "Profile name in ~/.oci/config for this region's tenancy"
}

variable "availability_domain" {
  type        = string
  description = "OCI availability domain, for example xJLJ:US-CHICAGO-1-AD-1"
}

variable "compartment_id" {
  type        = string
  description = "OCI compartment OCID where the VM is created"
}

variable "subnet_id" {
  type        = string
  description = "OCI subnet OCID for the VM's VNIC. It needs a route to the internet"
}

variable "arch" {
  type        = string
  default     = "arm64"
  description = "arm64 or amd64. Picks the shape, which picks the image build"
}

variable "amd64_shape" {
  type        = string
  default     = "VM.Standard.E2.1.Micro"
  description = "AMD shape: Always Free E2.1.Micro, or paid E4.Flex with 1 OCPU and 1 GB"

  validation {
    condition     = contains(["VM.Standard.E2.1.Micro", "VM.Standard.E4.Flex"], var.amd64_shape)
    error_message = "Use VM.Standard.E2.1.Micro or VM.Standard.E4.Flex"
  }
}

variable "ubuntu_version" {
  type        = string
  default     = "24.04"
  description = "Ubuntu release. The VM uses OCI's newest image for it"
}

variable "release_version" {
  type        = string
  description = "CloudGateway for Linux version to install from the linux-v<version> GitHub release"
}

variable "hashed_password" {
  type        = string
  sensitive   = true
  description = "SHA-512 password hash for the backdoor console user"
}

variable "ssh_authorized_keys" {
  type        = list(string)
  default     = []
  description = "Public SSH keys for the ubuntu user, if the subnet allows SSH"
}

locals {
  # E2.1.Micro is free only in the home region and may not be offered there
  shapes = {
    arm64 = { name = "VM.Standard.A1.Flex", ocpus = 1, memory_in_gbs = 1 }
    amd64 = {
      name          = var.amd64_shape
      ocpus         = var.amd64_shape == "VM.Standard.E2.1.Micro" ? null : 1
      memory_in_gbs = var.amd64_shape == "VM.Standard.E2.1.Micro" ? null : 1
    }
  }
  shape = local.shapes[var.arch]

  backdoor_user_data = templatefile("${path.module}/../../../Infrastructure/OCI/terraform/backdoor-cloud-init.yaml", {
    hashed_password = var.hashed_password
  })

  install_user_data = templatefile("${path.module}/install-cloud-init.sh.tftpl", {
    release_version = var.release_version
  })

  user_data = <<-EOT
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="==CLOUDGATEWAY_BOUNDARY=="

--==CLOUDGATEWAY_BOUNDARY==
Content-Type: text/cloud-config; charset="us-ascii"

${trimspace(local.backdoor_user_data)}

--==CLOUDGATEWAY_BOUNDARY==
Content-Type: text/x-shellscript; charset="us-ascii"

${trimspace(local.install_user_data)}

--==CLOUDGATEWAY_BOUNDARY==--
EOT
}

# Newest standard image for the version that runs on the shape. The regex skips
# Minimal images, and the shape filter picks the aarch64 or x86 build
data "oci_core_images" "ubuntu" {
  compartment_id = var.compartment_id
  shape          = local.shape.name
  sort_by        = "TIMECREATED"
  sort_order     = "DESC"

  filter {
    name   = "display_name"
    values = ["^Canonical-Ubuntu-${replace(var.ubuntu_version, ".", "\\.")}-(aarch64-)?[0-9]{4}\\."]
    regex  = true
  }
}

resource "oci_core_instance" "test" {
  lifecycle {
    precondition {
      condition     = length(data.oci_core_images.ubuntu.images) > 0
      error_message = "OCI has no Ubuntu ${var.ubuntu_version} image for ${local.shape.name}"
    }
  }

  availability_domain = var.availability_domain
  compartment_id      = var.compartment_id
  display_name        = "CloudGateway-Linux-Test"
  shape               = local.shape.name

  preserve_boot_volume = false

  dynamic "shape_config" {
    for_each = local.shape.ocpus == null ? [] : [local.shape]
    content {
      ocpus         = shape_config.value.ocpus
      memory_in_gbs = shape_config.value.memory_in_gbs
    }
  }

  create_vnic_details {
    subnet_id        = var.subnet_id
    assign_public_ip = true
  }

  metadata = {
    ssh_authorized_keys = join("\n", var.ssh_authorized_keys)
    user_data           = base64encode(local.user_data)
  }

  source_details {
    source_type = "image"
    source_id   = data.oci_core_images.ubuntu.images[0].id
  }
}

output "image" {
  value = data.oci_core_images.ubuntu.images[0].display_name
}

output "public_ip" {
  value = oci_core_instance.test.public_ip
}
