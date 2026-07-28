// Copyright (c) 2026 RemotiveLabs, All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//         http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// Golden image for remotive-topology (RemotiveTopology) hosts: Docker CE,
// remotivebus, remotive CLI baked in (translation of the upstream
// remote-deployment ansible roles docker/remotivebus/remotive_cli).

packer {
  required_plugins {
    googlecompute = {
      source = "github.com/hashicorp/googlecompute"
      # Same constraint as cf_instance_template/packer/cuttlefish.pkr.hcl:
      # max_run_duration_in_seconds needs >= 1.2.3; v1.2.5 SIGSEGVs in
      # StepImportOSLoginSSHKey on Argo read-only /workspace.
      version = ">= 1.2.3, < 1.2.5"
    }
  }
}

variable "project_id" {
  type = string
}

variable "zone" {
  type = string
}

variable "region" {
  type = string
}

variable "network" {
  type = string
}

variable "subnetwork" {
  type = string
}

variable "source_image_project_id" {
  type = string
}

# Image family (e.g. ubuntu-2404-lts-amd64) — tracks the latest image in the family.
variable "source_image_family" {
  type = string
}

variable "machine_type" {
  type = string
}

variable "disk_size_gb" {
  type = number
}

variable "disk_type" {
  type = string
}

variable "image_name" {
  type = string
}

variable "image_description" {
  type = string
}

variable "ssh_username" {
  type = string
}

# Linux account baked into the image for interactive SSH (docker group, no baked keys —
# access via OS Login / IAP).
variable "default_user" {
  type = string
}

# Directory containing remotive_host_initialise.sh, uploaded to /tmp/remotive on the builder.
variable "remotive_script_path" {
  type = string
}

# GCE limit VM runtime on the ephemeral Packer builder only (not the baked image /
# instance template). Prevents orphaned builders if Argo kills the client or Packer hangs.
variable "packer_max_run_duration_seconds" {
  type        = number
  description = "Maximum wall-clock seconds the Packer builder instance may run before GCE deletes it."
}

# When Packer runs outside the builder VPC (Argo pod on GKE), plain SSH to the RFC1918
# address often never completes; IAP-tunneled SSH matches `gcloud compute ssh --tunnel-through-iap`.
variable "use_iap" {
  type    = bool
  default = true
}

variable "ssh_timeout" {
  type        = string
  default     = "15m"
  description = "How long to wait for SSH (boot + IAP tunnel ready)."
}

variable "iap_tunnel_launch_wait" {
  type        = number
  default     = 300
  description = "Seconds to wait for IAP tunnel before treating launch as failed."
}

source "googlecompute" "remotive" {
  project_id              = var.project_id
  source_image_project_id = [var.source_image_project_id]
  source_image_family     = var.source_image_family
  zone                    = var.zone
  machine_type            = var.machine_type
  # Default e2/n1/n2 machine types require MIGRATE (GCE's own default); TERMINATE
  # is only valid for preemptible instances or bare-metal families, neither of
  # which remotive uses today. Do not copy cvd/cf's TERMINATE override here.
  disk_size               = var.disk_size_gb
  disk_type               = var.disk_type
  network                 = var.network
  subnetwork              = var.subnetwork
  omit_external_ip        = true
  use_internal_ip         = true
  use_iap                 = var.use_iap
  ssh_timeout             = var.ssh_timeout
  iap_tunnel_launch_wait  = var.iap_tunnel_launch_wait
  ssh_username            = var.ssh_username
  image_name              = var.image_name
  image_description       = var.image_description
  image_storage_locations = [var.region]
  # If the job fails or the Packer client disconnects, the builder would otherwise keep
  # running until manual cleanup.
  max_run_duration_in_seconds = var.packer_max_run_duration_seconds
  instance_termination_action = "DELETE"
  metadata = {
    enable-oslogin = "true"
  }
}

build {
  sources = ["source.googlecompute.remotive"]

  provisioner "file" {
    source      = var.remotive_script_path
    destination = "/tmp/remotive"
  }

  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E bash '{{ .Path }}'"
    environment_vars = [
      "DEFAULT_USER=${var.default_user}",
    ]
    script = "${path.root}/provision_remotive_host.sh"
  }
}
