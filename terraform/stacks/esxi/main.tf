terraform {
  required_version = ">= 1.6"
  required_providers {
    vsphere = {
      source  = "hashicorp/vsphere"
      version = ">= 2.8.0"
    }
  }
}

# ── Provider ──────────────────────────────────────────────────────────
# The Windows installer passes vsphere_user + vsphere_password through
# tfvars.json from the run.json secrets bag. ESXi labs are routinely
# self-signed → tls_insecure default true matches the wizard's default.
provider "vsphere" {
  user                 = var.vsphere_user
  password             = var.vsphere_password
  vsphere_server       = var.vsphere_server
  allow_unverified_ssl = var.tls_insecure
}

# ── Inputs ────────────────────────────────────────────────────────────
variable "vsphere_server"   { type = string }
variable "vsphere_user"     { type = string }
variable "vsphere_password" { type = string; sensitive = true }
variable "tls_insecure"     { type = bool; default = true }

# Cluster-level defaults. Per-node overrides (when set) win.
variable "datastore"     { type = string }
variable "iso_datastore" { type = string }
variable "network"       { type = string }

variable "nodes" {
  type = list(object({
    name              = string
    memory_mb         = number
    vcpu              = number
    disk_gb           = number
    extra_disks_gb    = list(number)
    seed_iso_path     = string                       # datastore-relative
    base_iso_path     = optional(string, "")
    mac               = optional(string, "")
    datastore         = optional(string, "")          # per-node placement override
    iso_datastore     = optional(string, "")
    disk_provisioning = optional(string, "thin")
    guest_id          = optional(string, "opensuse64Guest")
  }))
}

# ── VMs ──────────────────────────────────────────────────────────────
module "vm" {
  for_each = { for n in var.nodes : n.name => n }
  source   = "../../modules/esxi-vm"

  name              = each.value.name
  memory_mb         = each.value.memory_mb
  vcpu              = each.value.vcpu
  disk_gb           = each.value.disk_gb
  extra_disks_gb    = each.value.extra_disks_gb
  seed_iso_path     = each.value.seed_iso_path
  base_iso_path     = each.value.base_iso_path
  mac               = each.value.mac
  disk_provisioning = each.value.disk_provisioning
  guest_id          = each.value.guest_id

  # Per-node datastore + iso_datastore + network override; falls back to
  # stack-level defaults when blank. Mirrors the libvirt pool/Proxmox
  # datastore_id pattern so the wizard form is consistent across targets.
  datastore     = each.value.datastore != "" ? each.value.datastore : var.datastore
  iso_datastore = each.value.iso_datastore != "" ? each.value.iso_datastore : var.iso_datastore
  network       = var.network
}

output "node_ips" {
  value = { for k, m in module.vm : k => m.primary_ip }
}
