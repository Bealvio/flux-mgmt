# AGENTS.md — Bealvio/flux-mgmt

Guide for AI agents (and humans) working in this repo. **Keep this file up to date:** whenever you make a significant change (new app, new upstream build script, change to the bootstrap/sync flow, new Sveltos ClusterProfile, change to update automation, new cross-repo dependency, or a gotcha you had to discover the hard way), update the relevant section here in the same PR/commit.

## What this repo is

GitOps source of truth for the **management cluster** (`bealv-mgmt`), reconciled by **FluxCD** (installed and managed by the **flux-operator**). The management cluster runs the platform that creates and feeds the child/workload clusters:

- **Cluster API** (operator + Proxmox infra provider + Kamaji control-plane provider + in-cluster IPAM) to create child clusters.
- **Sveltos** to push add-ons (Flux, cert-manager, Cilium, ingress, monitoring, CSI…) to child clusters selected by labels.
- Shared infra: Vault (+ unsealer), PowerDNS (+ operator), MinIO, Velero, external-secrets, trust-manager, cert-manager, monitoring, chihiro (self-service "Kubernetes as a service" portal).

The main workload cluster is **`bealv`**, whose own GitOps repo is **[Bealvio/bealv](https://github.com/Bealvio/bealv)**. Child cluster repos are resolved by name: `https://github.com/Bealvio/{{ .Cluster.metadata.name }}`.

## Layout

```
bootstrap/
  cilium/           # CNI bundle + L2 LB config (applied at cluster bootstrap)
  kubernetes/       # kubeadm config + secrets template for the mgmt cluster
  tf/vault/         # terraform for Vault
  fluxcd/
    kustomization.yaml, repo.yaml, sync.yaml, apps.yaml   # the Flux entrypoint
    setup/instance.yaml   # FluxInstance (flux-operator CR): components, patches (tmpfs, --concurrent=2)
    upstream/             # GENERATED flux-operator install.yaml (buildFlux)
gitops/
  kustomizations/   # one Flux Kustomization per app -> ./gitops/apps/<app>
  apps/<app>/       # the manifests; `upstream/` subdirs are GENERATED, don't hand-edit
nix/                # nix derivations that fetch & package upstream manifests
npins/sources.json  # pinned upstream versions (drives the generated upstream/ dirs)
updatecli/          # updatecli autodiscovery for container images / flux helm charts
devenv.nix          # dev shell + build scripts
```

### Flux wiring

- `GitRepository/infra` → this repo, `main`, only `/bootstrap/fluxcd` and `/gitops` are included (see `ignore:` in `bootstrap/fluxcd/repo.yaml`).
- `Kustomization/flux-system` → `bootstrap/fluxcd/setup` (FluxInstance).
- `Kustomization/flux-operator` → `bootstrap/fluxcd/upstream`.
- `Kustomization/apps` → `gitops/kustomizations` (interval 2m, prune). Each file there is a Kustomization for one app (interval 1m, usually `prune: true`, sometimes `healthChecks`/`dependsOn`).
- Everything is namespace `flux-system`, secret `github-fluxcd-chan` for GitHub access.

### What reaches the child clusters (important for blast radius)

Sveltos ClusterProfiles in `gitops/apps/sveltos/clusterprofiles/` deploy **paths of this repo** onto child clusters (e.g. `bealv`) through a `GitRepository/mgmt` created on each child. Changing these paths changes **every matching child cluster**, not just mgmt:

| Path in this repo | Child-cluster label selector |
|---|---|
| `bootstrap/fluxcd/upstream/` (flux-operator) + FluxInstance template in `fluxcd.yaml` | `fluxcd: "true"` |
| `gitops/apps/cert-manager/upstream`, `.../setup` | `cert-manager: "true"` |
| `gitops/apps/ingress-controller` (contour/envoy) | `ingress-controller: "true"` |
| `gitops/apps/external-snapshotter` | `external-snapshotter: "true"` |
| `gitops/apps/monitoring` + `monitoring/upstream/kube-prometheus/crds` | `monitoring: "true"` |
| `gitops/apps/proxmox-csi`, `gitops/apps/trust-manager`, external-dns / velero templates | respective labels |

The child's own repo (e.g. Bealvio/bealv) is wired as `GitRepository/infra` + `Kustomization/apps` → `./gitops/kustomizations` by `fluxcd.yaml`.

## Environment & tooling

Use devenv (see workspace rules): `devenv shell -- <cmd>` or `direnv` (`.envrc` runs `use devenv`). The shell provides `kustomize`, `npins`, `treefmt` (via the nixbook devenv module) and these generators:

| Script | Regenerates |
|---|---|
| `buildFlux <version>` | `bootstrap/fluxcd/upstream/` (flux-operator) |
| `buildCertManager <version>` | `gitops/apps/cert-manager/upstream/` |
| `buildCapi <version>` | `gitops/apps/cluster-api/upstream/` |
| `buildKubeProm` | `gitops/apps/monitoring/upstream/` (kube-prometheus + grafana-operator) |
| `buildSnapshotter` | `gitops/apps/external-snapshotter/upstream/` |
| `buildIngressContour` | `gitops/apps/ingress-controller/upstream/` |
| `buildKamaji` | `gitops/apps/kamaji/upstream/` |

Always run `devenv shell treefmt` before committing generated output. Validate with `kustomize build gitops/apps/<app>` for anything you touch.

## Update automation (bots)

- **npins workflow** (`.github/workflows/npins-update.yaml`, every 6h): `npins update <pin>` then the matching `build*` script, then `treefmt`; opens `npins-update-<pin>` PRs titled `chore(deps): update <pin>`. These regenerate the whole `upstream/` dir (images, CRDs, RBAC) — **preferred** way to bump upstream components.
- **updatecli** (`.github/workflows/updatecli-discovery.yaml`, `updatecli/updatecli.d/`): autodiscovers container images in `gitops/apps/` and opens `deps: bump container image …` PRs.
  - Gotcha: kubernetes autodiscovery here does **not** ignore `*/upstream/*`, so it also bumps single images inside generated upstream bundles and reformats the whole file with yq (hundreds of lines of pure `description:` reflow). Those PRs are redundant/conflicting with the npins PR for the same component — prefer the npins PR and close the updatecli one as superseded. Verify with a semantic YAML diff, not the line diff.
- No CI checks run on PRs; review is manual. PR author is the `update-chan` GitHub App.

## Reviewing / merging dependency PRs

1. Look at the **semantic** change (parse YAML; ignore description reflow). Look for CRD field removals, RBAC changes, flag/arg changes, renamed resources (e.g. contour `contour-certgen-vX-Y-Z` Job name changes each release — fine).
2. Read upstream release notes for minor/major bumps and 0.x minor bumps; check config/flags used in this repo against removals.
3. Remember the blast radius table above: cert-manager, flux-operator, contour/envoy, snapshotter and monitoring changes also roll to child clusters.
4. Merge npins PRs before updatecli ones touching the same files; close superseded ones.
5. After merge Flux picks it up within ~1–2 min (GitRepository 1m, Kustomizations 1–2m). To force: `flux reconcile source git infra -n flux-system` then `flux reconcile kustomization <name> -n flux-system` (`nix run nixpkgs#fluxcd -- …` if `flux` isn't on PATH). The API servers are on the private `10.250.0.0/24` network (mgmt `10.250.0.3`, bealv `10.250.0.13`), reachable only from inside the LAN/VPN.

### Lessons learned / pending upgrades

- **Image-only bumps of operators are dangerous**: an updatecli PR that only changes an operator image inside a vendored bundle leaves CRDs/RBAC at the old version. Operator upgrades need a full regen of the upstream bundle.
- cert-manager ≥ v1.21 renamed the controller metrics Service port to `http-metrics` → `gitops/apps/monitoring/servicemonitors/cert-manager.yaml` must match.
- external-dns ≥ v0.22 requires `--policy` and defaults to the `external-dns.kubernetes.io/` annotation prefix. We set `--policy=sync --enable-legacy-annotation-prefix` in `gitops/apps/external-dns/internal-deploy.yaml` **and** in the Sveltos template `gitops/apps/sveltos/clusterprofiles/templates/external-dns/deploy-patch.yaml`, whose args list fully replaces the base one. Keep both in sync.
- Pending (as of 2026-09-28), deliberately not merged:
  - dragonfly-operator v1.6.x and powerdns-operator v0.4.x (PR #172). dragonfly v1.6 adds NetworkPolicies that allow same-namespace clients only, plus new RBAC and a new env var. powerdns v0.4 has a breaking CRD change (Zone becomes namespaced, v1alpha2).
  - csi-provisioner v6.3.0 (PR #179) needs Kubernetes ≥ 1.34, but `bootstrap/kubernetes/kubeadm.yaml` pins v1.31.4.

## Conventions

- GitHub only allows **rebase merges** (`gh pr merge --rebase`); branches are auto-deleted. `main` is unprotected.
- Commit messages: conventional-ish (`fix:`, `chore(deps):`, `feat ✨:`, `refactor 🎨 (scope):`).
- Don't hand-edit `upstream/` directories; patch via kustomize patches next to them (e.g. `monitoring/*-patch.yaml`, `ingress-controller/cm-patch.yaml`).
- Secrets come from Vault through external-secrets (`ExternalSecret` → `ClusterSecretStore/vault-backend`); never commit plaintext credentials.
- Known quirk: `nix/fluxcd.nix` fetch URL contains `flux-operator/flux-operator/releases` (duplicated path segment); `buildFlux` prefetches the hash from the correct URL — if `buildFlux` fails to fetch, fix the URL in `nix/fluxcd.nix`.

## Keep this file current

If you change anything described above, or learn something a future agent would otherwise have to rediscover, update this AGENTS.md in the same change. Also keep the sibling doc in Bealvio/bealv consistent when cross-repo behaviour changes.
