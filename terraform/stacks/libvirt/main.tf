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
variable "base_volume_id"  { type = string; description = "ID of pre-uploaded openSUSE/MicroOS image" }

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
    boot_mode      = optional(string, "iso")    # "iso" (Combustion) or "kernel" (Agama)
    kernel_path    = optional(string, "")
    initrd_path    = optional(string, "")
    cmdline        = optional(string, "")
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
  base_volume_id = var.base_volume_id
  network_id     = var.network_id
  pool           = var.pool
  mac            = each.value.mac

  boot_mode      = each.value.boot_mode
  kernel_path    = each.value.kernel_path
  initrd_path    = each.value.initrd_path
  cmdline        = each.value.cmdline
}

output "node_ips" {
  value = { for k, m in module.vm : k => m.primary_ip }
}
