terraform {
  required_version = ">= 1.6"
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = ">= 0.7.6"
    }
  }
}

provider "libvirt" {
  uri = var.libvirt_uri
}

variable "libvirt_uri"     { type = string }
variable "pool"            { type = string; default = "default" }
variable "network_id"      { type = string }
variable "base_volume_id"  {
  type        = string
  default     = ""
  description = "Stack-level fallback base qcow2 ID — used for nodes whose own base_volume_id is empty. Empty everywhere → kernel-boot domains get blank volumes (correct for Agama)."
}

# Driven from inventory.yaml via `terraform apply -var-file=tfvars.json`
# (the Windows installer writes tfvars.json from the inventory).
variable "nodes" {
  type = list(object({
    name           = string
    memory_mb      = number
    vcpu           = number
    disk_gb        = number
    extra_disks_gb = list(number)
    seed_iso_path  = string
    mac            = optional(string)
    pool           = optional(string, "")       # per-node libvirt storage pool override
    disk_format    = optional(string, "qcow2")   # qcow2=thin, raw=thick
    boot_mode      = optional(string, "iso")    # "iso" (Combustion) or "kernel" (Agama)
    kernel_path    = optional(string, "")
    initrd_path    = optional(string, "")
    cmdline        = optional(string, "")
    # Per-node base qcow2 override. Empty → fall back to stack base_volume_id,
    # which itself may be empty for an all-Agama cluster. MicroOS nodes MUST
    # have a non-empty value (their own or the stack default).
    base_volume_id = optional(string, "")
  }))
}

module "vm" {
  for_each = { for n in var.nodes : n.name => n }
  source   = "../../modules/libvirt-vm"

  name           = each.value.name
  memory_mb      = each.value.memory_mb
  vcpu           = each.value.vcpu
  disk_gb        = each.value.disk_gb
  extra_disks_gb = each.value.extra_disks_gb
  seed_iso_path  = each.value.seed_iso_path
  # Per-node base qcow2 wins; falls back to the stack-level default; both
  # may be empty for all-Agama clusters (kernel boot needs no base image).
  base_volume_id = each.value.base_volume_id != "" ? each.value.base_volume_id : var.base_volume_id
  network_id     = var.network_id
  # Per-node pool override falls back to the stack-level default pool.
  pool           = each.value.pool != "" ? each.value.pool : var.pool
  disk_format    = each.value.disk_format
  mac            = each.value.mac

  boot_mode      = each.value.boot_mode
  kernel_path    = each.value.kernel_path
  initrd_path    = each.value.initrd_path
  cmdline        = each.value.cmdline
}

output "node_ips" {
  value = { for k, m in module.vm : k => m.primary_ip }
}
