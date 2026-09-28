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
scripts/renovate-post-upgrade.sh  # pin -> build* script mapping, run by Renovate after a pin bump
renovate.json5      # Renovate config (all dependency updates)
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

| Path in this repo                                                                       | Child-cluster label selector   |
| --------------------------------------------------------------------------------------- | ------------------------------ |
| `bootstrap/fluxcd/upstream/` (flux-operator) + FluxInstance template in `fluxcd.yaml`   | `fluxcd: "true"`               |
| `gitops/apps/cert-manager/upstream`, `.../setup`                                        | `cert-manager: "true"`         |
| `gitops/apps/ingress-controller` (contour/envoy)                                        | `ingress-controller: "true"`   |
| `gitops/apps/external-snapshotter`                                                      | `external-snapshotter: "true"` |
| `gitops/apps/monitoring` + `monitoring/upstream/kube-prometheus/crds`                   | `monitoring: "true"`           |
| `gitops/apps/proxmox-csi`, `gitops/apps/trust-manager`, external-dns / velero templates | respective labels              |

The child's own repo (e.g. Bealvio/bealv) is wired as `GitRepository/infra` + `Kustomization/apps` → `./gitops/kustomizations` by `fluxcd.yaml`.

## Environment & tooling

Use devenv (see workspace rules): `devenv shell -- <cmd>` or `direnv` (`.envrc` runs `use devenv`). The shell provides `kustomize`, `npins`, `yq`, `treefmt` (via the nixbook devenv module) and these generators:

| Script                       | Regenerates                                                             |
| ---------------------------- | ----------------------------------------------------------------------- |
| `buildFlux <version>`        | `bootstrap/fluxcd/upstream/` (flux-operator)                            |
| `buildCertManager <version>` | `gitops/apps/cert-manager/upstream/`                                    |
| `buildCapi <version>`        | `gitops/apps/cluster-api/upstream/`                                     |
| `buildKubeProm`              | `gitops/apps/monitoring/upstream/` (kube-prometheus + grafana-operator) |
| `buildSnapshotter`           | `gitops/apps/external-snapshotter/upstream/`                            |
| `buildIngressContour`        | `gitops/apps/ingress-controller/upstream/`                              |
| `buildKamaji`                | `gitops/apps/kamaji/upstream/`                                          |

Always run `devenv shell treefmt` before committing generated output. Entering `devenv shell` also installs git pre-commit hooks (treefmt, shellcheck, mdsh) and may reformat files.

If `devenv shell` fails with ``The option `dotenv.resolved' was accessed but has no value defined``, the devenv CLI is newer than the modules in `devenv.lock`: run `devenv update` and commit the lock. npins ≥ 0.5 needs the v8 `sources.json` format (`npins upgrade`). Validate with `kustomize build gitops/apps/<app>` for anything you touch.

## Update automation (Renovate)

All dependency updates come from **self-hosted Renovate**:

- **Workflow:** `.github/workflows/renovate.yaml` runs every 4h, on manual dispatch, and on pushes that change the config.
- **Identity:** the `update-chan` GitHub App (secrets `APP_ID`/`PRIVATE_KEY`).
- **Config:** `renovate.json5`.
- **Overview:** the **Dependency Dashboard** issue lists every pending, rate-limited or approval-gated update. Tick a checkbox there to force or approve one.

What is covered:

| Source                                                                                                                                                                                                                                                                                           | Manager                                             |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------- |
| Container images in manifests under `gitops/`                                                                                                                                                                                                                                                    | `kubernetes`                                        |
| HelmRelease charts (HelmRepository / OCI) and images in HelmRelease `spec.values`                                                                                                                                                                                                                | `flux`                                              |
| `images:` in kustomizations                                                                                                                                                                                                                                                                      | `kustomize` (grafana-operator excluded, see npins)  |
| `bootstrap/tf/vault` providers                                                                                                                                                                                                                                                                   | `terraform`                                         |
| Workflow actions (grouped, weekly)                                                                                                                                                                                                                                                               | `github-actions`                                    |
| `npins/sources.json` release pins (`GitRelease`) and branch pins (`Git`, weekly)                                                                                                                                                                                                                 | custom regex → `postUpgradeTasks`                   |
| Anything annotated with a `# renovate: datasource=<ds> depName=<name> [registryUrl=…] [versioning=…]` comment on the line above: CAPI provider `version:` + `fetchConfig.url`, konnectivity, Sveltos helm charts (cilium, capsule), Grafana CR version, kamaji-etcd, the Renovate version itself | custom regex                                        |
| Operator images in hand-vendored bundles (dragonfly, powerdns-operator, kubipam)                                                                                                                                                                                                                 | custom regex, **dashboard approval only** + warning |

**npins flow:** Renovate bumps `version` (or `revision` for branch pins), then runs `devenv shell -- ./scripts/renovate-post-upgrade.sh <pin> <version>`. The script runs `npins update --partial <pin>`, the matching `build*` generator (plus the yq tag edits for kamaji/grafana-operator) and `treefmt`. The PR therefore contains the whole regenerated `upstream/` bundle (images, CRDs, RBAC). When adding a pin or generator, add its case to that script.

**Generated `upstream/` dirs are in `ignorePaths`,** so Renovate never bumps single images inside them. `crossplane/upstream` is hand-written and _is_ managed.

**To make Renovate track a new value it can't detect,** add a `# renovate:` comment above it (see existing examples) rather than a new custom manager.

Other details:

- Commits and PR titles look like `chore(deps): update <dep> to <version>`. Updates must be at least 2 days old (except `zot.bealv.io/*` and Renovate itself). No automerge.
- PowerDNS workloads (`gitops/apps/powerdns/**`) are deliberately not updated.
- No CI checks run on PRs; review is manual.

## Reviewing / merging dependency PRs

1. Look at the **semantic** change (parse YAML; ignore description reflow). Look for CRD field removals, RBAC changes, flag/arg changes, renamed resources (e.g. contour `contour-certgen-vX-Y-Z` Job name changes each release — fine).
2. Read upstream release notes for minor/major bumps and 0.x minor bumps; check config/flags used in this repo against removals.
3. Remember the blast radius table above: cert-manager, flux-operator, contour/envoy, snapshotter and monitoring changes also roll to child clusters.
4. Renovate PRs touching the same file get rebased automatically after a merge; tick "rebase" in the PR if needed.
5. After merge Flux picks it up within ~1–2 min (GitRepository 1m, Kustomizations 1–2m). To force: `flux reconcile source git infra -n flux-system` then `flux reconcile kustomization <name> -n flux-system` (`nix run nixpkgs#fluxcd -- …` if `flux` isn't on PATH). The API servers are on the private `10.250.0.0/24` network (mgmt `10.250.0.3`, bealv `10.250.0.13`), reachable only from inside the LAN/VPN.

### Lessons learned / pending upgrades

- **Image-only bumps of operators are dangerous**: a PR that only changes an operator image inside a vendored bundle leaves CRDs/RBAC at the old version (this is why vendored bundles are dashboard-approval only in Renovate). Operator upgrades need a full regen of the upstream bundle.
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
