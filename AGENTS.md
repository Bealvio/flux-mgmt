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
- `Kustomization/apps` → `gitops/kustomizations` (interval 10m, prune). Each file there is a Kustomization for one app (interval 10m, 30m for CRD/upstream bundles; usually `prune: true`, sometimes `healthChecks`/`dependsOn`). HelmReleases use 30m+. A new commit is still applied within ~1 min: the GitRepository polls every 1m and a new revision triggers the Kustomizations immediately; the interval only paces drift correction. Child clusters get the same (Sveltos `fluxcd` / `monitoring` templates).
- Everything is namespace `flux-system`, secret `github-fluxcd-chan` for GitHub access.

### What reaches the child clusters (important for blast radius)

Sveltos ClusterProfiles in `gitops/apps/sveltos/clusterprofiles/` deploy **paths of this repo** onto child clusters (e.g. `bealv`) through a `GitRepository/mgmt` created on each child. Changing these paths changes **every matching child cluster**, not just mgmt.

**Add-on labels** (argus-style, one file per add-on in `clusterprofiles/`). A child cluster gets an add-on when its CAPI `Cluster` carries the label. Every workload profile also requires `type: workload` (the mgmt SveltosCluster is `type: mgmt`):

| Label on the CAPI Cluster                            | Add-on (file)                                                                              | Paths deployed                                                        |
| ---------------------------------------------------- | ------------------------------------------------------------------------------------------ | --------------------------------------------------------------------- |
| `addons.bealv.io/flux: enabled`                      | flux-operator, FluxInstance, `GitRepository/mgmt` + `infra` (`fluxcd.yaml`)                | `bootstrap/fluxcd/upstream/`                                          |
| `addons.bealv.io/cilium: enabled`                    | Cilium chart + L2 policy; LB IP for the child API on mgmt (`cilium.yaml`)                  | -                                                                     |
| `addons.bealv.io/cert-manager: gatewayapi`/`generic` | cert-manager variant; Vault ClusterIssuer via the cert-vault trigger (`cert-manager.yaml`) | `gitops/apps/cert-manager/upstream`, `.../setup`                      |
| `addons.bealv.io/trust-manager: enabled`             | trust-manager (`trust-manager.yaml`)                                                       | `gitops/apps/trust-manager`                                           |
| `addons.bealv.io/external-dns: enabled`              | external-dns + PowerDNS zone (`external-dns.yaml`; also needs cert-manager)                | `clusterprofiles/templates/external-dns`                              |
| `addons.bealv.io/external-secrets: enabled`          | ESO + Vault backend (`external-secret.yaml`)                                               | -                                                                     |
| `addons.bealv.io/external-snapshotter: enabled`      | CSI snapshotter (`external-snapshotter.yaml`)                                              | `gitops/apps/external-snapshotter`                                    |
| `addons.bealv.io/ingress-controller: enabled`        | contour/envoy (`ingress-controller.yaml`)                                                  | `gitops/apps/ingress-controller`                                      |
| `addons.bealv.io/ingress-replication: enabled`       | Ingress → HTTPRoute mirroring (`ingress-replication.yaml`)                                 | -                                                                     |
| `addons.bealv.io/proxmox-csi: enabled`               | Proxmox CSI (`proxmox-csi.yaml`)                                                           | `gitops/apps/proxmox-csi`                                             |
| `addons.bealv.io/monitoring: enabled`                | kube-prometheus + remote_write to Mimir (`monitoring.yaml`)                                | `gitops/apps/monitoring` + `monitoring/upstream/kube-prometheus/crds` |
| `addons.bealv.io/velero: enabled`                    | Velero + bucket on minio-clusters (`velero.yaml`)                                          | `clusterprofiles/templates/velero`                                    |
| `addons.bealv.io/ballast: enabled`                   | Ballast right-sizing (`ballast.yaml`)                                                      | `gitops/apps/ballast` (+ `enrollment`)                                |
| `addons.bealv.io/descheduler: enabled`               | descheduler (`descheduler.yaml`)                                                           | `gitops/apps/descheduler`                                             |
| `addons.bealv.io/capsule: enabled`                   | Capsule tenants (`capsule.yaml`)                                                           | -                                                                     |

Any other value (chihiro writes `disabled`) means off. bealv's labels are set by hand (`kubectl -n capi-system label cluster bealv …`); clusters created by chihiro get them from `gitops/apps/chihiro/cm.yaml`, where each add-on is an admin toggle.

**Changing selectors or labels without withdrawing anything.** A ClusterProfile that stops matching a cluster (selector or label change, or the profile renamed/deleted) withdraws what it deployed, unless it is `LeavePolicies`. Many profiles changing at once also redeploys everything to the children (on 2026-10-02 that overloaded kamaji-etcd and took bealv's API down). So:

1. add new labels to the clusters first (additive, nothing changes);
2. change selectors a few profiles per PR. `scripts/sveltos-match-diff.sh [origin/main]` must print "match sets identical": it compares, for every ClusterProfile/EventTrigger (cluster, source and destination selectors), the live clusters matched at the base ref and in the working tree. `scripts/check-addon-labels.py` must pass: every selector, including those in ConfigMap templates rendered by EventTriggers (e.g. `cert-manager-configs-<cluster>`), uses only the catalog keys;
3. remove old labels last, and only after a live check shows nothing still using them: selectors of `clusterprofile,profile,eventtrigger` (including generated `sveltos-*` / `*-<cluster>` profiles) **and `eventsource` `labelFilters` on CAPI Clusters**. An EventSource that stops matching a cluster drops the event, and its EventTrigger deletes the profile generated for it (on 2026-10-03 removing `cni` from bealv did that to the `cilium-lb` profile; its resources survived only because the trigger is `LeavePolicies`);
4. never rename a profile.

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
| HelmRelease charts (HelmRepository / OCI). Images inside `spec.values` are **not** extracted: annotate them or add a narrow regex (e.g. the velero plugin initContainer)                                                                                                                         | `flux` / custom regex                               |
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
5. After merge Flux picks it up within ~1–2 min (GitRepository 1m; a new revision triggers the Kustomizations at once, their 10m/30m intervals are only for drift). To force: `flux reconcile source git infra -n flux-system` then `flux reconcile kustomization <name> -n flux-system` (`nix run nixpkgs#fluxcd -- …` if `flux` isn't on PATH). The API servers are on the private `10.250.0.0/24` network (mgmt `10.250.0.3`, bealv `10.250.0.13`), reachable only from inside the LAN/VPN.

### Lessons learned / pending upgrades

- **Image-only bumps of operators are dangerous**: a PR that only changes an operator image inside a vendored bundle leaves CRDs/RBAC at the old version (this is why vendored bundles are dashboard-approval only in Renovate). Operator upgrades need a full regen of the upstream bundle.
- cert-manager ≥ v1.21 renamed the controller metrics Service port to `http-metrics` → `gitops/apps/monitoring/servicemonitors/cert-manager.yaml` must match.
- external-dns ≥ v0.22 requires `--policy` and defaults to the `external-dns.kubernetes.io/` annotation prefix. We set `--policy=sync --enable-legacy-annotation-prefix` in `gitops/apps/external-dns/internal-deploy.yaml` **and** in the Sveltos template `gitops/apps/sveltos/clusterprofiles/templates/external-dns/deploy-patch.yaml`, whose args list fully replaces the base one. Keep both in sync.
- Pending (as of 2026-09-28), deliberately not merged:
  - dragonfly-operator v1.6.x and powerdns-operator v0.4.x (PR #172). dragonfly v1.6 adds NetworkPolicies that allow same-namespace clients only, plus new RBAC and a new env var. powerdns v0.4 has a breaking CRD change (Zone becomes namespaced, v1alpha2).
  - csi-provisioner v6.3.0 (PR #179) needs Kubernetes ≥ 1.34, but `bootstrap/kubernetes/kubeadm.yaml` pins v1.31.4.

## Ballast (request right-sizing)

Adopted from RPCU/argus. `gitops/apps/ballast` (operator HelmRelease, webhook post-rendered to `failurePolicy: Ignore`) and `gitops/apps/ballast/enrollment` (a `MutatingAdmissionPolicy` that labels controller-owned pods with the Ballast mode and the identity `ballast.bealv.io/workload=<ns>--<workload>`; skips pods with a CPU limit, Jobs/bare pods, CNPG instances and system/storage/monitoring namespaces). Deployed to children by the Sveltos `ballast` profile (opt-in label `ballast: "true"` on the CAPI Cluster; chihiro defaults to `"false"`).

- Mode is `measure` (collect only). Flip it to `apply` in `enrollment-policy.yaml` once `kubectl get workloadprofiles` looks sane; pods are then sized at their next restart. In-place resize stays dry-run until clusters are ≥ 1.35.
- Metrics come from metrics.k8s.io (prometheus-adapter of the `monitoring` profile), so monitoring must be on for that cluster.
- `MutatingAdmissionPolicy` is beta/off in 1.34: `--feature-gates=MutatingAdmissionPolicy=true` + `--runtime-config=admissionregistration.k8s.io/v1beta1=true` are set in the `KamajiControlPlaneTemplate`. Only valid while every cluster of the class is ≥ 1.34; drop them and move the policy to `admissionregistration.k8s.io/v1` at ≥ 1.36.
- Kill switch: `kubectl -n ballast-system create configmap ballast-kill-switch`.

## Metrics: Mimir

Adapted from RPCU/argus. `gitops/apps/mimir` (Kustomizations `mimir-bucket` then `mimir`) runs `mimir-distributed` on mgmt: 1 replica per component, no Kafka, no ruler or alertmanager. Blocks go to bucket `mimir` on minio-clusters and are kept 15 days.

- The bucket, policy and user are provider-minio MRs (`deletionPolicy: Orphan`). The user's keys are written to Secret `monitoring/mimir-s3`, so nothing is seeded by hand. The bucket and policy sit in a separate Kustomization because the provider's webhook rejects the user until the policy exists in MinIO.
- Senders: mgmt's Prometheus pushes to `http://mimir-gateway.monitoring.svc/api/v1/push` (patch in `gitops/kustomizations/monitoring.yaml`). Children push to `https://mimir.bealv-mgmt.lan/api/v1/push` (patch in the Sveltos `monitoring` profile). Both drop the raw API server/etcd histogram buckets (about half of mgmt's ~390k series); their recording rules are still sent. The `cluster` external label tells clusters apart.
- Alerting stays in each cluster's Prometheus/Alertmanager. `PrometheusRemoteStorageFailures` / `PrometheusRemoteWriteBehind` fire if Mimir stops accepting writes.
- Grafana: datasource `mimir` is the **default** in every Grafana (mgmt: `monitoring-mgmt/mimir-datasource.yaml`; bealv: in Bealvio/bealv), so dashboards open on all clusters and the `cluster` variable picks one. The local Prometheus stays in each dashboard's `datasource` dropdown (24h, that cluster only; there `cluster` is empty and `cluster=~""` matches everything).
- Multi-cluster dashboards: kube-prometheus' own `Kubernetes / …` dashboards already have `cluster`. The others are built by `devenv shell -- buildDashboards` (`nix/grafana-dashboards.nix` → `gitops/apps/monitoring/grafana-dashboards/generated`). `nix/dashboards/multicluster.py` adds the `datasource`/`cluster` variables and injects `cluster=~"$cluster"` into every query with `promtool promql label-matchers set`, and fails the build if a query can't be rewritten. Sources are pinned (grafana.com revision or git commit + sha256). To add a dashboard, add it to `external` there and rebuild; don't add `grafanaCom`/`url` GrafanaDashboards directly, they would not have the cluster picker. kube-prometheus dashboards without a visible `cluster` are rebuilt as `<configmap>-mc` and repointed by patches in `gitops/apps/monitoring/kustomization.yaml` (the upstream/ bundle is left as is: regenerating it currently drifts a lot).
- Storage must be S3, not filesystem: with separate ingester, compactor and store-gateway pods, the compactor never sees the blocks, so retention never applies.

## Descheduler

`gitops/apps/descheduler` (kubernetes-sigs descheduler chart, Deployment mode, every 30m) runs on mgmt (Flux Kustomization `descheduler`) and on children labelled `descheduler: "true"` (Sveltos `descheduler` profile). It is there to rebalance after a node reboot/drain and to fix broken affinity/taint/spread placement. The policy is deliberately conservative:

- pods with a PVC are protected, and so are system-critical pods (`nodeFit` is on);
- `kube-system`, `capi-system` (Kamaji tenant control planes, i.e. the bealv API server), `kamaji-system`, `vault` and the unsealer are excluded;
- at most 2 evictions per node, 1 per namespace and 5 per run;
- `LowNodeUtilization` uses requests: a node under 20% CPU+memory is underutilized, and pods move off nodes above 60%.

Before changing the policy, dry-run it locally. Extract the binary with `crane export registry.k8s.io/descheduler/descheduler:<tag> - | tar -x bin/descheduler`, then run `bin/descheduler --kubeconfig <kc> --policy-config-file <rendered policy.yaml> --dry-run`.

## Upgrading CAPI / providers (bealv workers must not roll)

State (2026-10-02): CAPI core + kubeadm bootstrap v1.12.11, CAPMOX v0.9.1 (templates `v1alpha2`), IPAM in-cluster v1.1.0, Kamaji provider v0.19.0, Kamaji 26.9.5-edge; ClusterClass and KubeadmConfigTemplate are CAPI `v1beta2`.

- **Pause the cluster** for anything that can change how CAPI computes bealv's templates (provider API versions, CAPI core): `kubectl -n capi-system patch cluster bealv --type merge -p '{"spec":{"paused":true}}'`, wait for the `Paused` condition, unpause when verified.
- **The alt worker class is the GPU group.** `templateAltID` must point at a kaassopeia template tagged `gpu` (nixOS-server CI publishes it with `hostpci0: mapping=igpu,mdev=i915-GVTg_V5_4`; full clones copy it). The iGPU (Proxmox PCI mapping `igpu`, `0000:00:02.0`) has one GVT-g vGPU slot, so `default-worker-alt` rolls out delete-first (`maxSurge: 0`, `maxUnavailable: 1`): the GPU node is down for a few minutes per rollout, and no other VM may hold the vGPU (a hand-added `hostpci` elsewhere blocks the new alt VM from starting). Nodes get `node-role.kubernetes.io/gpu`; pods request `gpu.intel.com/i915` (intel-gpu-plugin). CAPMOX's token needs `PVEMappingUser` on `/mapping/pci/igpu`.
- **Worker RAM is set by the Cluster variable `workerMemoryMiB`** (both classes; bealv: 16384). Unset, workers inherit reference template 997's 32 GB, and 4 x 32 GB workers during a rollout (2 replicas + surge + alt) made the Proxmox host OOM-kill VMs (2026-10-03). Size it so `(replicas + 1 surge) x workers + mgmt VMs` fits the host. Changing it rotates both worker classes.
- **Worker disk storage comes from the template unless `storage`/`storageAlt` is set.** Both worker classes share `kamaji-proxmox-v2` and differ only by `templateID`/`templateAltID`; without the optional Cluster variables `storage` (default-worker) and `storageAlt` (default-worker-alt), CAPMOX passes no target storage and Proxmox full-clones onto the template's own storage. Set them (Proxmox storage IDs, e.g. `disk_hdd`/`disk_hddb`) to pin each class; setting one rotates that class's workers.
- **CAPI matches ClusterClass patch selectors on the exact `apiVersion`.** When a provider changes its storage version, move the templates, ClusterClass refs _and_ selectors together. A stale selector silently drops the `templateID` patches (997/996) and rolls the workers onto the base template 102.
- **Migrate manifests by copying the stored object**, not by hand: read it back in the new version (`kubectl get <kind>.<version>.<group> ...`), then prove with a server-side dry-run (`--server-side --field-manager=kustomize-controller --dry-run=server`) that the result is identical to what is stored, and that base template + patch equals the cluster's current templates (`bealv-worker-*`).
- Save `{generation, spec}` of bealv's KamajiControlPlane, MachineDeployments and worker templates before, and diff after unpausing; no change means no rollout.
- Before a provider bump, compare the live webhook configurations with the _old_ release manifest: Helm can leave stale webhooks behind (Kamaji 26.x upgrade left `vdatastore.kb.io` → DataStore never Ready, tenant control planes unreconciled).
- CAPI picks up edits of ClusterClass templates only on its periodic resync (up to ~10 min).
- Renovate caps: Kamaji provider `<0.20` (v0.20+ = CAPI v1beta2 contract, no longer reconciles bealv without CLASTIX's paid conversion), CAPI core one minor at a time (`<1.13`).
- Kamaji provider v0.19 → v0.21 (v1beta2 contract) was done without CLASTIX's paid conversion: KamajiControlPlane(Template) `v1alpha2` spec is a strict superset of `v1alpha1`, so a storage-version migration is enough. With bealv paused: transitional CRDs serving both versions (`v1alpha2` storage, conversion `None`), `kubectl replace` each object as `v1alpha2` (same UID: the TenantControlPlane is owned by the KCP's UID, never delete/recreate it), set CRD `status.storedVersions` to `["v1alpha2"]`, then bump the provider and the git refs. Rehearsed on a local 1.34 apiserver first. Two gotchas after the old version stops being served: (1) objects still carrying `managedFields` entries for the removed version make Flux's server-side apply fail with "request to convert CR to an invalid group/version" — reset them with a JSON patch `replace /metadata/managedFields [{}]` (spec untouched); (2) kustomize-controller keeps its discovery cache, so its health check reports the object `NotFound` — `kubectl -n flux-system rollout restart deploy/kustomize-controller`. Owner references on the TenantControlPlane are moved to `v1alpha2` by the new controller on its first reconcile (a few one-off "no matches for kind ... v1alpha1" log lines before that are harmless).

## Conventions

- GitHub only allows **rebase merges** (`gh pr merge --rebase`); branches are auto-deleted. `main` is unprotected.
- Commit messages: conventional-ish (`fix:`, `chore(deps):`, `feat ✨:`, `refactor 🎨 (scope):`).
- Don't hand-edit `upstream/` directories; patch via kustomize patches next to them (e.g. `monitoring/*-patch.yaml`, `ingress-controller/cm-patch.yaml`).
- Secrets come from Vault through external-secrets (`ExternalSecret` → `ClusterSecretStore/vault-backend`); never commit plaintext credentials.
- Kamaji GitRepository tag / image tag and the CAPMOX `fetchConfig.url` drifted from their pins under updatecli (fixed 2026-10): when reviewing a Renovate PR for these, check that both values moved together.
- Tenant control planes (KamajiControlPlaneTemplate): apiserver/scheduler/controller-manager/konnectivity have resource requests (else BestEffort, first evicted under node memory pressure), a hostname topology spread (one replica per mgmt node, `matchLabelKeys` so surge rollouts schedule), and konnectivity `--keepalive-time=60s` on agent and server. Without the keepalive, a tenant LB IP moving between mgmt nodes (Cilium L2 lease failover, e.g. a node reboot) leaves the tunnel silently dead for up to 1h: `kubectl logs/exec/top`, aggregated APIs and webhooks time out. Quick fix: `kubectl -n kube-system rollout restart ds/konnectivity-agent` in the child. Keepalive must stay >= 30s (server EnforcementPolicy). mgmt nodes have 10 GB RAM: each bealv apiserver replica is ~1.6 GB.
- Kamaji tags changed format in 2026-03 (`edge-YY.M.P` → `YY.M.P-edge`); the Renovate versioning regex accepts both. Upgrading Kamaji also upgrades the bundled kamaji-etcd chart (version from the tag's `Chart.lock`, not the `>=` range). Since 26.x the parent chart switches kamaji-etcd to cert-manager certs (new CA), a ServiceMonitor and a liveness probe: `kamaji/setup/helmrelease.yaml` pins the old behaviour (`selfSignedCertificates`, `datastore.headless`, `livenessProbe: null`, `securityContext: null`) so bealv's datastore keeps its CA and the etcd pods don't restart. Before a Kamaji bump, render old vs new with `helm template` using the locked subchart and diff the etcd StatefulSet/DataStore.
- Tenant control planes roll with `maxSurge: 0, maxUnavailable: 1` (KamajiControlPlaneTemplate): a surge rollout doesn't fit in mgmt memory.
- Generators (`build*` in devenv.nix) go through `build_into`: build first, abort on empty output, copy from `"$out"/.`. The old `cp -r $(nix-build …)/* dir` copied the whole root filesystem into the repo when nix-build failed (`<nixpkgs>` unset); `<nixpkgs>` is now the npins pin.
- Known quirk: `nix/fluxcd.nix` fetch URL contains `flux-operator/flux-operator/releases` (duplicated path segment); `buildFlux` prefetches the hash from the correct URL — if `buildFlux` fails to fetch, fix the URL in `nix/fluxcd.nix`.

## Keep this file current

If you change anything described above, or learn something a future agent would otherwise have to rediscover, update this AGENTS.md in the same change. Also keep the sibling doc in Bealvio/bealv consistent when cross-repo behaviour changes.
