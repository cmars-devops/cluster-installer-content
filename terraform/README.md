# Terraform

Stacks invoked by the Windows installer through the `terraform.exe` it embeds.

## Layout

```
modules/
  libvirt-vm/      single-VM module against dmacvicar/libvirt
  proxmox-vm/      single-VM module against bpg/proxmox
stacks/
  libvirt/         multi-node stack consuming nodes[] from inventory
  proxmox/         multi-node stack
```

## Variable contract

The Windows installer renders `tfvars.json` from `inventory.yaml`. The shape
matches the `nodes` variable in each stack. The installer is responsible for:

1. Building each per-node seed ISO and uploading it to the target side
   (libvirt pool / Proxmox storage).
2. Filling `seed_iso_path` (libvirt) or `seed_iso_id` (proxmox) per node.
3. Pre-uploading the base OS image once per content-tag (caches the qcow2/iso).
4. Running `terraform init` against `TF_PLUGIN_CACHE_DIR` set to
   `%LOCALAPPDATA%\cluster-installer\cache\providers`, so providers download
   only once across runs.

## Provider versions

Pin in the installer's release notes; `>=` constraints in HCL allow forward
movement, but the installer's content-repo tag freezes the working set.
