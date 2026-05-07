terraform {
  required_version = ">= 1.6"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.66"
    }
  }
}

provider "proxmox" {
  endpoint  = var.endpoint
  api_token = var.api_token
  insecure  = var.tls_insecure
  ssh {
    agent    = true
    username = var.ssh_username
  }
}

variable "endpoint"     { type = string }
variable "api_token"    { type = string; sensitive = true }
variable "tls_insecure" { type = bool; default = false }
variable "ssh_username" { type = string; default = "root" }
variable "pve_node"     { type = string; description = "Target Proxmox node name" }
variable "base_iso_id"  { type = string }
variable "datastore_id" { type = string; default = "local-lvm" }
variable "iso_datastore"{ type = string; default = "local" }
variable "bridge"       { type = string; default = "vmbr0" }

variable "nodes" {
  type = list(object({
    name           = string
    memory_mb      = number
    vcpu           = number
    disk_gb        = number
    extra_disks_gb = list(number)
    seed_iso_id    = string
    mac            = optional(string)
    datastore_id   = optional(string, "")    # per-node Proxmox storage override
    file_format    = optional(string, "qcow2") # qcow2=thin, raw=thick
    discard        = optional(bool, true)
  }))
}

module "vm" {
  for_each = { for n in var.nodes : n.name => n }
  source   = "../../modules/proxmox-vm"

  name           = each.value.name
  node           = var.pve_node
  memory_mb      = each.value.memory_mb
  vcpu           = each.value.vcpu
  disk_gb        = each.value.disk_gb
  extra_disks_gb = each.value.extra_disks_gb
  base_iso_id    = var.base_iso_id
  seed_iso_id    = each.value.seed_iso_id
  # Per-node datastore override falls back to the stack-level default.
  datastore_id   = each.value.datastore_id != "" ? each.value.datastore_id : var.datastore_id
  iso_datastore  = var.iso_datastore
  bridge         = var.bridge
  mac            = each.value.mac
  file_format    = each.value.file_format
  discard        = each.value.discard
}

output "vm_ids" {
  value = { for k, m in module.vm : k => m.id }
}
