# cluster-installer-content

Versioned IaC content (Terraform / Ansible / Helm / Agama / Combustion+Ignition)
consumed at runtime by the [cluster-installer](https://github.com/cmars-devops/cluster-installer) Windows GUI.

The installer pulls a specific git tag of this repo via `go-git`. The exe is thin;
all installation logic lives here.

## Versioning

- `VERSION` and the matching `vX.Y.Z` git tag are the SSoT.
- Bumps follow semver. Breaking inventory schema changes → major.

## Layout

| Path | Purpose |
|------|---------|
| `schema/inventory.schema.json` | Authoritative JSON Schema for the wizard's output YAML |
| `images.yaml` | OS ISO catalog (URL + checksum + autoinst mode) |
| `seeds/agama/` | Agama unattended-install JSON profiles (openSUSE Leap / Tumbleweed) |
| `seeds/ignition/` | Combustion + Ignition templates (openSUSE MicroOS / SLE Micro) |
| `terraform/modules/` | Reusable provisioner modules (libvirt-vm, proxmox-vm) |
| `terraform/stacks/` | Top-level stacks the installer invokes |
| `ansible/playbooks/` | Numbered playbooks 00–40 driving the post-OS pipeline |
| `ansible/collections/requirements.yml` | External roles/collections pinned by git tag |
| `manifests/helm/<chart>/values.yaml.j2` | Templated Helm values |
| `tests/molecule/` | Idempotency tests for ansible roles |

## Pipeline contract

The installer runs playbooks in numeric order:

1. `00-preflight.yml` — package/time/firewall/sysctl readiness
2. `10-ceph-cephadm.yml` — bootstrap Ceph cluster on dedicated nodes
3. `20-rke2.yml` (or `20-k3s.yml`) — install Kubernetes
4. `30-csi-ceph.yml` — wire ceph-csi to k8s, create StorageClasses
5. `40-addons.yml` — kube-vip, ingress-nginx, cert-manager, monitoring, optional ArgoCD

Each must be idempotent.
