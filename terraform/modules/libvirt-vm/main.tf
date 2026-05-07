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
variable "base_volume_id"  { type = string }
variable "seed_iso_path"   { type = string; description = "Per-node seed ISO on the libvirt host (Combustion+Ignition for MicroOS, also generated for Leap as fallback)" }
variable "network_id"      { type = string }
variable "mac"             { type = string; default = null }
variable "pool"            { type = string; default = "default" }

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
  name             = "${var.name}-root.qcow2"
  pool             = var.pool
  base_volume_id   = var.base_volume_id
  size             = var.disk_gb * 1024 * 1024 * 1024
}

resource "libvirt_volume" "extra" {
  for_each = { for i, gb in var.extra_disks_gb : tostring(i) => gb }
  name     = "${var.name}-data-${each.key}.qcow2"
  pool     = var.pool
  size     = each.value * 1024 * 1024 * 1024
  format   = "qcow2"
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
