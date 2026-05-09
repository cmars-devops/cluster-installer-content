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
variable "vsphere_password" {
  type      = string
  sensitive = true
}
variable "tls_insecure" {
  type    = bool
  default = true
}

# Stack-level ISO datastore. VM disk placement is per-disk (each disk
# in the disks list carries its own datastore — the tfvars renderer
# fills it with the VM's primary datastore when the operator left it
# blank). `network` is also stack-level: a default port-group used for
# any NIC entry that left `network` blank.
variable "iso_datastore" { type = string }
variable "network"       { type = string }

variable "nodes" {
  type = list(object({
    name             = string
    memory_mb        = number
    vcpu             = number
    # disks: list of disks. [0] is the OS install disk (the only
    # required entry); rest are blank extras. Each disk carries its own
    # datastore (the tfvars renderer fills empty values with the VM's
    # primary datastore) and provisioning mode.
    disks = list(object({
      size_gb      = number
      datastore    = string
      provisioning = string
      label        = optional(string, "")
    }))
    # nics: list of NICs. [0] is the primary. Each NIC has a port-group
    # and pre-allocated MAC; the orchestrator hashes (cluster_name,
    # hostname, nic_index) so re-runs reuse the same MACs.
    nics = list(object({
      network = string
      mac     = string
      label   = optional(string, "")
    }))
    seed_iso_path    = string                                 # datastore-relative
    install_iso_path = optional(string, "")                    # per-node remaster (Leap/Tumbleweed) or shared (Ubuntu)
    guest_id         = optional(string, "opensuse64Guest")
  }))
}

# ── VMs ──────────────────────────────────────────────────────────────
module "vm" {
  for_each = { for n in var.nodes : n.name => n }
  source   = "../../modules/esxi-vm"

  name             = each.value.name
  memory_mb        = each.value.memory_mb
  vcpu             = each.value.vcpu
  disks            = each.value.disks
  nics             = each.value.nics
  seed_iso_path    = each.value.seed_iso_path
  install_iso_path = each.value.install_iso_path
  guest_id         = each.value.guest_id
  iso_datastore    = var.iso_datastore
}

output "node_ips" {
  value = { for k, m in module.vm : k => m.primary_ip }
}
