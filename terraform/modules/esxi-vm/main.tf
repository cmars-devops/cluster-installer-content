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
variable "name"      { type = string }
variable "memory_mb" { type = number }
variable "vcpu"      { type = number }

# disks: ordered list, [0] is the OS install disk; the rest are blank
# extras the guest sees as /dev/sd[bcd...]. Each disk has its own size,
# datastore, and provisioning so heterogeneous storage layouts (e.g.
# small-fast OS disk on NVMe + bulk data disks on a larger HDD-backed
# datastore) are expressible without a stack-wide compromise.
variable "disks" {
  type = list(object({
    size_gb      = number
    datastore    = string
    provisioning = string
    label        = string
  }))
  validation {
    condition     = length(var.disks) > 0
    error_message = "at least one disk is required (the OS install disk)."
  }
  validation {
    condition = alltrue([
      for d in var.disks : contains(["thin", "thick", "thick-eager"], d.provisioning)
    ])
    error_message = "each disk.provisioning must be 'thin', 'thick', or 'thick-eager'."
  }
}

# nics: ordered list, [0] is the primary (default route + verify SSH
# target). Each NIC has its own port-group and pre-allocated MAC.
variable "nics" {
  type = list(object({
    network = string
    mac     = string
    label   = string
  }))
  validation {
    condition     = length(var.nics) > 0
    error_message = "at least one NIC is required."
  }
}

# Datastore that hosts the ISOs we attach as CD-ROMs (seed + base).
variable "iso_datastore" { type = string }

# Datastore-relative path to the seed ISO. Always present:
#   MicroOS  → Combustion+Ignition (this is the install payload itself).
#   Agama    → secondary CD carrying SSH keys / hostname / first-boot
#              hooks; the primary install media is install_iso_path.
#   Ubuntu   → cidata CD carrying user-data + meta-data (cloud-init NoCloud).
# Format: "cluster-installer/<run-id>/seed-<host>.iso"
variable "seed_iso_path" { type = string }

# Datastore-relative path to the per-node remastered netinstall ISO.
# Empty for MicroOS. When set this is mounted as the FIRST cdrom (boot
# order picks it ahead of the seed disk) so the bootloader's rewritten
# cmdline drives the install.
variable "install_iso_path" {
  type    = string
  default = ""
}

# ESXi guest_id determines which paravirtual driver hints vSphere applies.
# 'opensuse64Guest' for SUSE, 'ubuntu64Guest' for Ubuntu — issue #4 in
# docs/lessons-from-IDC.md (using 'otherLinux64Guest' silently disables
# vmxnet3 optimisations).
variable "guest_id" {
  type    = string
  default = "opensuse64Guest"
}

# ── Datacenter / host resolution ─────────────────────────────────────
data "vsphere_datacenter" "dc" {}

data "vsphere_resource_pool" "rp" {
  name          = "Resources"
  datacenter_id = data.vsphere_datacenter.dc.id
}

# Resolve every distinct datastore referenced by the disks list +
# the iso_datastore. for_each on a unique-set so duplicates collapse.
locals {
  disk_datastores = toset([for d in var.disks : d.datastore])
  nic_networks    = toset([for n in var.nics : n.network])
}
data "vsphere_datastore" "by_name" {
  for_each      = local.disk_datastores
  name          = each.value
  datacenter_id = data.vsphere_datacenter.dc.id
}
data "vsphere_datastore" "iso_ds" {
  name          = var.iso_datastore
  datacenter_id = data.vsphere_datacenter.dc.id
}
data "vsphere_network" "by_name" {
  for_each      = local.nic_networks
  name          = each.value
  datacenter_id = data.vsphere_datacenter.dc.id
}

# vSphere disk type string — provider field for each disk.
locals {
  provisioning_to_vsphere = {
    thin          = "thin"
    thick         = "lazy"             # provider calls lazy-zeroed "lazy"
    "thick-eager" = "eagerZeroedThick"
  }
}

# ── VM resource ───────────────────────────────────────────────────────
resource "vsphere_virtual_machine" "vm" {
  name             = var.name
  resource_pool_id = data.vsphere_resource_pool.rp.id
  # The VM-level datastore is the OS disk's datastore (disks[0]). Per-
  # disk overrides apply to additional disks via dynamic blocks below.
  datastore_id = data.vsphere_datastore.by_name[var.disks[0].datastore].id

  num_cpus = var.vcpu
  memory   = var.memory_mb
  guest_id = var.guest_id

  # Boot order: vSphere BIOS default is floppy → CD → HD → network.
  # A single-disk VM hits CD first and boots fine. BUT multi-disk VMs
  # (Ceph OSD nodes carrying 2-4 SCSI disks for data/db/wal) trip a
  # BIOS NVRAM caching quirk: the SCSI bus scan runs long enough on
  # first power-on that CD-ROM enumeration times out, BIOS learns
  # "no CD present" and skips it on subsequent boots — VM falls
  # through to HDD (no boot record) → network → PXE. CORE nodes (1
  # disk) don't show this behavior.
  #
  # Fix: extra_config below pins the device class order AND gives the
  # SCSI subsystem a 5s grace period so CD enumeration completes
  # before BIOS picks a boot device. This costs 5s on every power-on
  # but is bullet-proof — required for any multi-disk Ceph node and
  # harmless for single-disk dev-vm / CORE.
  firmware = "bios"

  extra_config = {
    # Restrict BIOS to try CD then HD then network in that order.
    # 'allow:cd,hd,net' is the documented vSphere syntax — without
    # restricting, BIOS firmware may include floppy + serial + USB
    # in the search and skip CD when bus scan is slow.
    "bios.bootDeviceClasses" = "allow:cd,hd,net"
    # Hold POST 5s before picking a boot device so the SCSI bus has
    # time to enumerate every disk + the IDE CD-ROM controller has
    # time to mount the attached ISO. Default 0ms is too tight for
    # multi-disk VMs on busy datastores.
    "bios.bootDelay" = "5000"
  }

  # NICs — one network_interface block per entry. nic[0] is the primary
  # default-route holder by netplan convention; entries beyond [0] are
  # configured by the guest OS but the wizard doesn't manage their
  # routing rules.
  dynamic "network_interface" {
    for_each = { for i, n in var.nics : i => n }
    content {
      network_id     = data.vsphere_network.by_name[network_interface.value.network].id
      adapter_type   = "vmxnet3"
      use_static_mac = network_interface.value.mac != ""
      mac_address    = network_interface.value.mac != "" ? network_interface.value.mac : null
    }
  }

  # Disks — one disk block per entry. [0] is the OS install disk; rest
  # are blank extras. Each disk picks its own datastore via
  # `datastore_id` and its own thin/thick mode via `eagerly_scrub` /
  # `thin_provisioned`.
  dynamic "disk" {
    for_each = { for i, d in var.disks : i => d }
    content {
      label = disk.value.label != "" ? disk.value.label : "disk${disk.key}"
      size  = disk.value.size_gb
      # Place this disk on its own datastore. Empty in inventory →
      # tfvars renderer fills with the VM's primary datastore.
      datastore_id = data.vsphere_datastore.by_name[disk.value.datastore].id
      unit_number  = disk.key
      eagerly_scrub    = local.provisioning_to_vsphere[disk.value.provisioning] == "eagerZeroedThick"
      thin_provisioned = local.provisioning_to_vsphere[disk.value.provisioning] == "thin"
    }
  }

  # CD-ROM 1 — primary boot media.
  # Agama nodes: the per-node remastered netinstall ISO.
  # MicroOS nodes: the Combustion seed ISO.
  # Ubuntu nodes: the (shared) live-server install ISO.
  cdrom {
    datastore_id = data.vsphere_datastore.iso_ds.id
    path         = var.install_iso_path != "" ? var.install_iso_path : var.seed_iso_path
  }

  # CD-ROM 2 — secondary, only when install_iso_path is set (Agama,
  # Ubuntu). Carries either the Combustion seed or the cidata.
  dynamic "cdrom" {
    for_each = var.install_iso_path != "" ? [1] : []
    content {
      datastore_id = data.vsphere_datastore.iso_ds.id
      path         = var.seed_iso_path
    }
  }

  wait_for_guest_net_timeout = 30
  wait_for_guest_ip_timeout  = 30
}

output "id"         { value = vsphere_virtual_machine.vm.id }
output "primary_ip" { value = vsphere_virtual_machine.vm.default_ip_address }
