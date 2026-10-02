# Multi-cluster Grafana dashboards -> gitops/apps/monitoring/grafana-dashboards/generated
# (devenv: buildDashboards).
#
# Every dashboard gets a `datasource` variable that follows the Grafana default
# (Mimir) and a visible `cluster` variable, and every query gets
# `cluster=~"$cluster"` (dashboards/multicluster.py, PromQL rewritten by
# promtool). Sources are pinned: grafana.com revisions and git commits.
#
# - `external`: dashboards fetched from the internet. They replace the
#   GrafanaDashboards of the same name (same uid in Grafana).
# - `kubePrometheus`: kube-prometheus dashboards that hid or lacked the
#   `cluster` variable, read from the committed upstream bundle. They are
#   written as `<configmap>-mc` and gitops/apps/monitoring/kustomization.yaml
#   points the upstream GrafanaDashboards at them, so the generated upstream/
#   dir is left untouched.
{
  pkgs ? import <nixpkgs> { },
}:
let
  inherit (pkgs) lib;
  external = [
    {
      name = "node-exporter";
      url = "https://grafana.com/api/dashboards/1860/revisions/37/download";
      sha256 = "0qza4j8lywrj08bqbww52dgh2p2b9rkhq5p313g72i57lrlkacfl";
    }
    {
      name = "cluster-overview";
      url = "https://grafana.com/api/dashboards/21410/revisions/3/download";
      sha256 = "1cx6vjr9cmzqacylsxpz917zdp192j1z1r728zplx1fbdhamhj9s";
    }
    {
      name = "flux-cluster";
      url = "https://raw.githubusercontent.com/fluxcd/flux2-monitoring-example/7ab65dc8b90f7a6751d88f18bbb4e1bee33bf334/monitoring/configs/dashboards/cluster.json";
      sha256 = "02fk9rsdvjarl9wmdzr1ij08drf8scr46lh3fxn1dvkzr8bd8lia";
    }
    {
      name = "contour";
      url = "https://grafana.com/api/dashboards/21396/revisions/2/download";
      sha256 = "0qiidc9lxyjib3aabdhzfigpfdzx3xjkyifgj4wkv3i2n48h1c8a";
    }
    {
      name = "cert-manager";
      url = "https://grafana.com/api/dashboards/20842/revisions/3/download";
      sha256 = "1qpram8q5zjdrjk8ybl46334ff84jzxg8ni7mj3y0v259hjalqx7";
    }
    {
      name = "coredns";
      url = "https://raw.githubusercontent.com/monitoring-mixins/website/97c701c0918b211a1d33791cf9d70c4fdb57a2cb/assets/coredns/dashboards/coredns.json";
      sha256 = "0f5pblh2il05ipi47hpr94z5axqknm3mv1naqhv02w3jcrq70sz0";
    }
    {
      name = "blackbox-exporter";
      url = "https://grafana.com/api/dashboards/13659/revisions/1/download";
      sha256 = "0m4gskf936jam2mrwhd8i1mnam9y26wklcg69hmaba60a1c4aw4y";
    }
  ];
  kubePrometheus = [
    "nodes"
    "node-cluster-rsrc-use"
    "node-rsrc-use"
    "alertmanager-overview"
    "grafana-overview"
  ];
  kubePromDefinitions = ../gitops/apps/monitoring/upstream/kube-prometheus/grafana-dashboardDefinitions.yaml;

  grafanaDashboard = name: ''
    apiVersion: grafana.integreatly.org/v1beta1
    kind: GrafanaDashboard
    metadata:
      name: ${name}
    spec:
      folder: administration
      instanceSelector:
        matchLabels:
          dashboards: "grafana"
      resyncPeriod: 10m
      configMapRef:
        name: grafana-dashboard-${name}
        key: ${name}.json
  '';
in
pkgs.runCommand "grafana-dashboards"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.prometheus.cli
      pkgs.kubectl
      pkgs.kustomize
      pkgs.yq-go
    ];
  }
  ''
    set -euo pipefail
    mkdir -p $out work
    cd work

    ${lib.concatMapStrings (d: ''
      python3 ${./dashboards/multicluster.py} ${pkgs.fetchurl { inherit (d) url sha256; }} ${d.name}.json
      kubectl create configmap grafana-dashboard-${d.name} --namespace monitoring \
        --from-file=${d.name}.json=${d.name}.json --dry-run=client -o yaml > $out/${d.name}-cm.yaml
      printf '%s' ${lib.escapeShellArg (grafanaDashboard d.name)} > $out/${d.name}.yaml
    '') external}

    ${lib.concatMapStrings (n: ''
      yq '.items[] | select(.metadata.name == "grafana-dashboard-${n}") | .data["${n}.json"]' \
        ${kubePromDefinitions} > ${n}.src.json
      python3 ${./dashboards/multicluster.py} ${n}.src.json ${n}.json
      kubectl create configmap grafana-dashboard-${n}-mc --namespace monitoring \
        --from-file=${n}.json=${n}.json --dry-run=client -o yaml > $out/${n}-mc-cm.yaml
    '') kubePrometheus}

    cd $out
    kustomize init
    kustomize edit add resource *.yaml
  ''
