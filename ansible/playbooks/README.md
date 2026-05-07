# Playbooks

Numeric prefix dictates the order the installer runs them. The Windows wizard
treats the directory listing as the canonical pipeline definition — any new
playbook with a higher prefix is appended automatically.

## Convention

| Prefix | Phase |
|--------|-------|
| `00-` | Preflight (every host) |
| `10-` | Storage (Ceph) |
| `20-` | Kubernetes (RKE2 or K3s) |
| `30-` | Storage ↔ k8s integration (CSI) |
| `40-` | Day-2 add-ons |

Playbooks **must** be idempotent — the wizard re-runs them on retry.
