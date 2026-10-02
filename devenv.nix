let
  sources = import ./npins;
  # Shared by every build* script. Builds FIRST and only then replaces the
  # target dir, so a failed nix-build can't leave it empty, and copies from
  # "$out"/. so an empty result can never become `cp -r /* <dir>` (which once
  # copied the whole root filesystem into the repo). <nixpkgs> is the npins pin.
  buildInto = ''
    set -euo pipefail
    build_into() {
      local dest="$1"
      shift
      local out
      out="$(nix-build --no-out-link -I nixpkgs=${sources.nixpkgs} "$@")"
      if [ -z "$out" ] || [ ! -d "$out" ]; then
        echo "build_into: nix-build $* produced no output directory" >&2
        exit 1
      fi
      rm -rf "$dest"
      mkdir -p "$dest"
      cp -r --no-preserve=mode "$out"/. "$dest"/
    }
  '';
in
{
  pkgs,
  lib,
  ...
}:
{
  imports = [ "${sources.nixbook}/devenvModules/devenv.nix" ];

  packages = with pkgs; [
    kustomize
    npins
    yq-go
  ];

  scripts = {
    buildKubeProm.description = "Build kube-prometheus upstream manifests";
    buildKubeProm.exec = buildInto + ''
      build_into gitops/apps/monitoring/upstream nix/kube-prometheus.nix
    '';
    buildDashboards.description = "Build multi-cluster Grafana dashboards (cluster variable + Mimir)";
    buildDashboards.exec = buildInto + ''
      build_into gitops/apps/monitoring/grafana-dashboards/generated nix/grafana-dashboards.nix
    '';
    buildSnapshotter.description = "Build external-snapshotter upstream manifests";
    buildSnapshotter.exec = buildInto + ''
      build_into gitops/apps/external-snapshotter/upstream nix/external-snapshotter.nix
    '';
    buildFlux.description = "Build flux-operator upstream manifests (requires version arg)";
    buildFlux.exec = buildInto + ''
      fluxhash="$(nix-prefetch-url "https://github.com/controlplaneio-fluxcd/flux-operator/releases/download/$1/install.yaml")"
      build_into bootstrap/fluxcd/upstream nix/fluxcd.nix --argstr manifest01Hash "$fluxhash" --argstr version "$1"
    '';
    buildCertManager.description = "Build cert-manager upstream manifests (requires version arg)";
    buildCertManager.exec = buildInto + ''
      certmanagerhash="$(nix-prefetch-url "https://github.com/cert-manager/cert-manager/releases/download/$1/cert-manager.yaml")"
      build_into gitops/apps/cert-manager/upstream nix/cert-manager.nix --argstr certManagerHash "$certmanagerhash" --argstr version "$1"
    '';
    buildCapi.description = "Build cluster-api-operator upstream manifests (requires version arg)";
    buildCapi.exec = buildInto + ''
      capihash="$(nix-prefetch-url "https://github.com/kubernetes-sigs/cluster-api-operator/releases/download/$1/operator-components.yaml")"
      build_into gitops/apps/cluster-api/upstream nix/capi.nix --argstr manifest01Hash "$capihash" --argstr version "$1"
    '';
    buildIngressContour.description = "Build ingress-contour upstream manifests";
    buildIngressContour.exec = buildInto + ''
      build_into gitops/apps/ingress-controller/upstream nix/ingress-contour.nix
    '';
    buildKamaji.description = "Build kamaji upstream manifests";
    buildKamaji.exec = buildInto + ''
      build_into gitops/apps/kamaji/upstream nix/kamaji.nix
    '';
  };

  enterShell = ''
    echo ""
    echo "flux-mgmt development environment loaded"
    echo ""
    echo "Available tools:"
    ${lib.concatStringsSep "\n    " (
      map (pkg: "echo \"  - ${pkg.name or pkg.pname or "unknown"} - ${pkg.meta.description or ""}\"") (
        with pkgs;
        [
          kustomize
          npins
        ]
      )
    )}
    echo ""
    echo "Available build scripts:"
    echo ""
    echo "  buildKubeProm        - Build kube-prometheus upstream manifests"
    echo "  buildDashboards      - Build multi-cluster Grafana dashboards"
    echo "  buildSnapshotter     - Build external-snapshotter upstream manifests"
    echo "  buildFlux <version>  - Build flux-operator upstream manifests"
    echo "  buildCertManager <version> - Build cert-manager upstream manifests"
    echo "  buildCapi <version>  - Build cluster-api-operator upstream manifests"
    echo "  buildIngressContour  - Build ingress-contour upstream manifests"
    echo "  buildKamaji          - Build kamaji upstream manifests"
    echo ""
  '';
}
