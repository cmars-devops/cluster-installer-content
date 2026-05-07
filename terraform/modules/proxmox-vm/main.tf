terraform {
  required_version = ">= 1.6"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.66"
    }
  }
}

variable "name"            { type = string }
variable "node"            { type = string; description = "Proxmox node name" }
variable "memory_mb"       { type = number }
variable "vcpu"            { type = number }
variable "disk_gb"         { type = number }
variable "extra_disks_gb"  { type = list(number); default = [] }
variable "datastore_id"    { type = string; default = "local-lvm" }
variable "iso_datastore"   { type = string; default = "local" }
variable "base_iso_id"     { type = string; description = "e.g. local:iso/openSUSE-MicroOS.iso" }
variable "seed_iso_id"     { type = string; description = "Per-node seed ISO already uploaded to Proxmox" }
variable "bridge"          { type = string; default = "vmbr0" }
variable "vlan_id"         { type = number; default = null }
variable "mac"             { type = string; default = null }

resource "proxmox_virtual_environment_vm" "vm" {
  name      = var.name
  node_name = var.node
  on_boot   = true

  cpu {
    cores = var.vcpu
    type  = "host"
  }

  memory {
    dedicated = var.memory_mb
  }

  cdrom { file_id = var.base_iso_id }

  # Seed ISO carrying Agama/Combustion config-drive.
  disk {
    datastore_id = var.iso_datastore
    interface    = "ide2"
    file_id      = var.seed_iso_id
    iso          = true
  }

  disk {
    datastore_id = var.datastore_id
    interface    = "scsi0"
    size         = var.disk_gb
    file_format  = "raw"
  }

  dynamic "disk" {
    for_each = { for i, gb in var.extra_disks_gb : tostring(i) => gb }
    content {
      datastore_id = var.datastore_id
      interface    = "scsi${1 + tonumber(disk.key)}"
      size         = disk.value
      file_format  = "raw"
    }
  }

  network_device {
    bridge      = var.bridge
    vlan_id     = var.vlan_id
    mac_address = var.mac
  }

  serial_device {}

  agent { enabled = true }
}

output "id"   { value = proxmox_virtual_environment_vm.vm.id }
output "name" { value = proxmox_virtual_environment_vm.vm.name }
