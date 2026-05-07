terraform {
  required_version = ">= 1.6"
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = ">= 0.7.6"
    }
  }
}

variable "name"            { type = string }
variable "memory_mb"       { type = number }
variable "vcpu"            { type = number }
variable "disk_gb"         { type = number }
variable "extra_disks_gb"  { type = list(number); default = [] }
variable "base_volume_id"  {
  type        = string
  default     = ""
  description = "Optional. ID of a pre-uploaded base qcow2 to clone the root disk from. Required for MicroOS (boot_mode=iso). For boot_mode=kernel (Leap/Tumbleweed via Agama) leave empty — Agama partitions a blank volume from scratch during install."
}
variable "seed_iso_path"   { type = string; description = "Per-node seed ISO on the libvirt host (Combustion+Ignition for MicroOS, also generated for Leap as fallback)" }
variable "network_id"      { type = string }
variable "mac"             { type = string; default = null }
variable "pool"            { type = string; default = "default" }
variable "disk_format"     { type = string; default = "qcow2"     # qcow2=thin, raw=thick
                             validation {
                               condition     = contains(["qcow2", "raw"], var.disk_format)
                               error_message = "disk_format must be 'qcow2' (thin) or 'raw' (thick)."
                             } }

# ---- direct kernel boot (Agama: openSUSE Leap 16+ / Tumbleweed) -------
# When boot_mode == "kernel" the domain boots vmlinuz/initrd directly with
# cmdline (containing inst.auto=http://...) — bypassing the ISO's grub menu
# entirely. This is the only reliable way to deliver an Agama profile to a
# VM without remastering the netinstall ISO.
# When boot_mode == "iso" (Combustion/MicroOS) the seed ISO is attached as a
# second CD-ROM and the qcow2 boots normally.
variable "boot_mode" {
  type    = string
  default = "iso"
  validation {
    condition     = contains(["iso", "kernel"], var.boot_mode)
    error_message = "boot_mode must be 'iso' or 'kernel'."
  }
}
variable "kernel_path" { type = string; default = "" }
variable "initrd_path" { type = string; default = "" }
variable "cmdline"     { type = string; default = "" }

resource "libvirt_volume" "root" {
  name = "${var.name}-root.${var.disk_format}"
  pool = var.pool
  # Empty string → null → blank volume (provider behaviour). Required for
  # Agama kernel-boot domains where the installer formats the disk fresh.
  base_volume_id = var.base_volume_id != "" ? var.base_volume_id : null
  size           = var.disk_gb * 1024 * 1024 * 1024
  format         = var.disk_format
}

resource "libvirt_volume" "extra" {
  for_each = { for i, gb in var.extra_disks_gb : tostring(i) => gb }
  name     = "${var.name}-data-${each.key}.${var.disk_format}"
  pool     = var.pool
  size     = each.value * 1024 * 1024 * 1024
  format   = var.disk_format
}

resource "libvirt_domain" "vm" {
  name      = var.name
  memory    = var.memory_mb
  vcpu      = var.vcpu
  autostart = true

  cpu { mode = "host-passthrough" }

  # Direct kernel boot (Agama): provider passes <kernel>/<initrd>/<cmdline>
  # straight into the domain XML. Empty strings ⇒ provider omits the elements.
  kernel  = var.boot_mode == "kernel" ? var.kernel_path : ""
  initrd  = var.boot_mode == "kernel" ? var.initrd_path : ""
  cmdline = var.boot_mode == "kernel" && var.cmdline != "" ? [
    { _ = var.cmdline }
  ] : []

  network_interface {
    network_id     = var.network_id
    mac            = var.mac
    wait_for_lease = true
  }

  disk { volume_id = libvirt_volume.root.id }

  dynamic "disk" {
    for_each = libvirt_volume.extra
    content { volume_id = disk.value.id }
  }

  # Seed ISO carrying Agama profile or Ignition+Combustion config drive.
  # For boot_mode=="kernel" it's mostly inert (Agama fetches by HTTP) but
  # kept so the same disk slot serves rescue/recovery later.
  disk { file = var.seed_iso_path }

  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }

  graphics {
    type        = "spice"
    listen_type = "address"
  }
}

output "id"          { value = libvirt_domain.vm.id }
output "primary_ip"  { value = libvirt_domain.vm.network_interface[0].addresses[0] }
