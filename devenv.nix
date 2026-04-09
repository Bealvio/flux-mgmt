let
  sources = import ./npins;
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
  ];

  scripts = {
    buildKubeProm.description = "Build kube-prometheus upstream manifests";
    buildKubeProm.exec = ''
      set -e
      rm -rf gitops/apps/monitoring/upstream
      mkdir -p gitops/apps/monitoring/upstream
      cp -r --no-preserve=mode $(nix-build nix/kube-prometheus.nix)/* gitops/apps/monitoring/upstream/
    '';
    buildSnapshotter.description = "Build external-snapshotter upstream manifests";
    buildSnapshotter.exec = ''
      set -e
      rm -rf gitops/apps/external-snapshotter/upstream
      mkdir -p gitops/apps/external-snapshotter/upstream
      cp -r --no-preserve=mode $(nix-build nix/external-snapshotter.nix)/* gitops/apps/external-snapshotter/upstream/
    '';
    buildFlux.description = "Build flux-operator upstream manifests (requires version arg)";
    buildFlux.exec = ''
      set -e
      rm -rf bootstrap/fluxcd/upstream
      mkdir -p bootstrap/fluxcd/upstream
      fluxhash=$(nix-prefetch-url https://github.com/controlplaneio-fluxcd/flux-operator/releases/download/$1/install.yaml)
      cp -r --no-preserve=mode $(nix-build nix/fluxcd.nix --argstr manifest01Hash "$fluxhash" --argstr version $1)/* bootstrap/fluxcd/upstream/
    '';
    buildCertManager.description = "Build cert-manager upstream manifests (requires version arg)";
    buildCertManager.exec = ''
      set -e
      rm -rf gitops/apps/cert-manager/upstream
      mkdir -p gitops/apps/cert-manager/upstream
      certmanagerhash=$(nix-prefetch-url https://github.com/cert-manager/cert-manager/releases/download/$1/cert-manager.yaml)
      cp -r --no-preserve=mode $(nix-build nix/cert-manager.nix --argstr certManagerHash "$certmanagerhash" --argstr version $1)/* gitops/apps/cert-manager/upstream/
    '';
    buildCapi.description = "Build cluster-api-operator upstream manifests (requires version arg)";
    buildCapi.exec = ''
      set -e
      rm -rf gitops/apps/cluster-api/upstream
      mkdir -p gitops/apps/cluster-api/upstream
      capihash=$(nix-prefetch-url https://github.com/kubernetes-sigs/cluster-api-operator/releases/download/$1/operator-components.yaml)
      cp -r --no-preserve=mode $(nix-build nix/capi.nix --argstr manifest01Hash "$capihash" --argstr version $1)/* gitops/apps/cluster-api/upstream/
    '';
    buildIngressContour.description = "Build ingress-contour upstream manifests";
    buildIngressContour.exec = ''
      set -e
      rm -rf gitops/apps/ingress-controller/upstream
      mkdir -p gitops/apps/ingress-controller/upstream
      cp -r --no-preserve=mode $(nix-build nix/ingress-contour.nix)/* gitops/apps/ingress-controller/upstream/
    '';
    buildKamaji.description = "Build kamaji upstream manifests";
    buildKamaji.exec = ''
      set -e
      rm -rf gitops/apps/kamaji/upstream
      mkdir -p gitops/apps/kamaji/upstream
      cp -r --no-preserve=mode $(nix-build nix/kamaji.nix)/* gitops/apps/kamaji/upstream/
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
    echo "  buildSnapshotter     - Build external-snapshotter upstream manifests"
    echo "  buildFlux <version>  - Build flux-operator upstream manifests"
    echo "  buildCertManager <version> - Build cert-manager upstream manifests"
    echo "  buildCapi <version>  - Build cluster-api-operator upstream manifests"
    echo "  buildIngressContour  - Build ingress-contour upstream manifests"
    echo "  buildKamaji          - Build kamaji upstream manifests"
    echo ""
  '';
}
