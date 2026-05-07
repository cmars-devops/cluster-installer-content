# Seed templates

Per-node first-boot configuration. The Windows installer renders each
template (Go `text/template`) into a per-node ISO labeled `OEMDRV` (Agama
auto-pickup) or `ignition` (Combustion+Ignition pickup), then attaches the ISO
to the VM as a second virtual CD-ROM.

| File | OS | Picked up by |
|------|----|--------------|
| `agama/leap.auto.json.tmpl` | openSUSE Leap | Agama installer via `agama.auto=device://OEMDRV/agama/profile.json` (or `agama.auto=URL` when served over HTTP) |
| `agama/tumbleweed.auto.json.tmpl` | openSUSE Tumbleweed | same |
| `ignition/microos-base.ign.tmpl` | openSUSE MicroOS / SLE Micro | Ignition stage in initrd, file at `/ignition/config.ign` |
| `ignition/combustion-script.tmpl` | openSUSE MicroOS / SLE Micro | Combustion stage, file at `/combustion/script` |

## Why Agama, not AutoYaST?

Agama is the next-generation openSUSE installer (replacement for YaST/AutoYaST).
Its unattended profile is a single JSON document driven by `agama-cli`, with a
documented schema and clean separation between product, localization,
network, storage, software, and scripts. AutoYaST profiles are not directly
portable to Agama, so the installer commits to Agama from v0.1.

Caveat: Agama is still maturing as of 2025–2026. If a release blocks on a
missing Agama feature, fall back path is to add an `autoyast/*.tmpl` next to
this directory; the Go renderer already abstracts the seed format.

## Template variables

The Go renderer feeds the following struct into every template:

```go
type SeedContext struct {
    Cluster ClusterCtx   // .Cluster.Name, .Cluster.Domain, .Cluster.Timezone
    Network NetworkCtx   // .Network.{Gateway,DNS,PrefixLen,PodCIDR,ServiceCIDR}
    Node    NodeCtx      // .Node.{Hostname,IP,Roles,OS,NetworkInterface,SSHAuthorizedKeys,NeedsCeph}
}
```

`.Node.NeedsCeph` is `true` if the node carries any `ceph-*` role.

## Why `.tmpl`, not `.j2`?

`.j2` (Jinja2) is reserved for files Ansible itself renders. The seed files
are rendered by the Windows installer's Go runtime *before* the OS even
boots, so they use Go template syntax (`{{ .Field }}`).
