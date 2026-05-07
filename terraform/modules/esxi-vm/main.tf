terraform {
  required_version = ">= 1.6"
  required_providers {
    vsphere = {
      source  = "hashicorp/vsphere"
      version = ">= 2.8.0"
    }
  }
}

# ── Inputs ────────────────────────────────────────────────────────────
variable "name"           { type = string }
variable "memory_mb"      { type = number }
variable "vcpu"           { type = number }
variable "disk_gb"        { type = number }
variable "extra_disks_gb" { type = list(number); default = [] }

# Datastore the VM's virtual disks live on. May differ from iso_datastore.
variable "datastore"      { type = string }

# Datastore that hosts the ISOs we attach as CD-ROMs (seed + base).
variable "iso_datastore"  { type = string }

# Datastore-relative path to the seed ISO uploaded by the orchestrator
# pre-TF — Combustion+Ignition for MicroOS, Agama remastered netinstall
# for Leap/Tumbleweed (when ISO remaster ships) or empty.
# Format: "cluster-installer/<run-id>/seed-<host>.iso"
variable "seed_iso_path"  { type = string }

# Datastore-relative path to the base install ISO. Empty for pure
# Combustion flows (MicroOS qcow2-equivalent), filled for Agama where
# the kernel-boot still needs the squashfs available locally.
variable "base_iso_path"  { type = string; default = "" }

variable "network"        { type = string; description = "vSphere port-group name" }
variable "mac"            { type = string; default = "" }

# disk_provisioning maps inventory's three-way choice to vSphere's
# enum: "thin", "thick" (lazy-zeroed), "thick-eager" (eagerZeroedThick).
variable "disk_provisioning" {
  type    = string
  default = "thin"
  validation {
    condition     = contains(["thin", "thick", "thick-eager"], var.disk_provisioning)
    error_message = "disk_provisioning must be 'thin', 'thick', or 'thick-eager'."
  }
}

# ESXi guest_id determines which paravirtual driver hints vSphere applies.
# 'opensuse64Guest' is the SUSE-tuned profile (issue #4 in
# docs/lessons-from-IDC.md — using 'otherLinux64Guest' silently disables
# vmxnet3 optimisations).
variable "guest_id" { type = string; default = "opensuse64Guest" }

# ── Datacenter / host resolution ─────────────────────────────────────
# Standalone ESXi: the synthetic "ha-datacenter" + the host itself.
# vCenter:        the real DC + a chosen host or cluster.
data "vsphere_datacenter" "dc" {}

data "vsphere_resource_pool" "rp" {
  name          = "Resources"
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_datastore" "ds" {
  name          = var.datastore
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_network" "net" {
  name          = var.network
  datacenter_id = data.vsphere_datacenter.dc.id
}

locals {
  # vSphere disk type strings — module input → provider field.
  vsphere_disk_type = {
    thin         = "thin"
    thick        = "lazy"          # provider calls lazy-zeroed "lazy"
    "thick-eager" = "eagerZeroedThick"
  }[var.disk_provisioning]
}

# ── VM resource ───────────────────────────────────────────────────────
resource "vsphere_virtual_machine" "vm" {
  name             = var.name
  resource_pool_id = data.vsphere_resource_pool.rp.id
  datastore_id     = data.vsphere_datastore.ds.id

  num_cpus = var.vcpu
  memory   = var.memory_mb
  guest_id = var.guest_id

  # Boot order: CD first so the netinstall ISO claims control on a fresh
  # disk. After install completes the VM powers off (Agama does this) and
  # the next power-on falls through to the disk. issue #6 in lessons-
  # from-IDC.md — explicit boot-order required, otherwise vSphere walks
  # devices in attach order which is unreliable across vmxnet3 / sata.
  boot_order = ["cdrom", "disk"]
  firmware   = "bios"

  network_interface {
    network_id   = data.vsphere_network.net.id
    adapter_type = "vmxnet3"
    use_static_mac = var.mac != ""
    mac_address    = var.mac != "" ? var.mac : null
  }

  # Root disk — empty, formatted by the installer.
  disk {
    label            = "disk0"
    size             = var.disk_gb
    eagerly_scrub    = local.vsphere_disk_type == "eagerZeroedThick"
    thin_provisioned = local.vsphere_disk_type == "thin"
  }

  # Optional extra disks (Ceph OSDs typically).
  dynamic "disk" {
    for_each = { for i, gb in var.extra_disks_gb : i => gb }
    content {
      label            = "disk${disk.key + 1}"
      size             = disk.value
      unit_number      = disk.key + 1
      eagerly_scrub    = local.vsphere_disk_type == "eagerZeroedThick"
      thin_provisioned = local.vsphere_disk_type == "thin"
    }
  }

  # Seed ISO — Combustion+Ignition (MicroOS) or remastered Agama
  # netinstall (Leap/Tumbleweed). Always attached even when empty so a
  # second 'cdrom' block doesn't shift unit_numbers between Apply runs.
  cdrom {
    datastore_id = data.vsphere_datastore.ds.id
    path         = var.seed_iso_path != "" ? var.seed_iso_path : "isos/empty.iso"
  }

  # Direct kernel boot is not available on vSphere the way libvirt does
  # it. Agama's only delivery path on ESXi is "remaster the ISO with
  # inst.auto baked into grub.cfg" — that's the work item phase-1 §4
  # tracks. Until that lands, ESXi support is MicroOS-only: the
  # Combustion ISO above is sufficient for first-boot config.

  wait_for_guest_net_timeout = 30
  wait_for_guest_ip_timeout  = 30
}

output "id"         { value = vsphere_virtual_machine.vm.id }
output "primary_ip" { value = vsphere_virtual_machine.vm.default_ip_address }
