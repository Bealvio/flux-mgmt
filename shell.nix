{
  pkgs ? (
    import <nixpkgs> {
      config.allowUnfree = true;
    }
  ),
  ...
}:
pkgs.mkShell {
  buildInputs = [
    pkgs.kustomize
  ];
  packages = [
    (pkgs.writeShellScriptBin "buildKubeProm" ''
      #!/bin/bash
      set -e
      rm -rf gitops/apps/monitoring/upstream
      mkdir -p gitops/apps/monitoring/upstream
      cp -r --no-preserve=mode $(nix-build nix/kube-prometheus.nix)/* gitops/apps/monitoring/upstream/
    '')
    (pkgs.writeShellScriptBin "buildSnapshotter" ''
      #!/bin/bash
      set -e
      rm -rf gitops/apps/external-snapshotter/upstream
      mkdir -p gitops/apps/external-snapshotter/upstream
      cp -r --no-preserve=mode $(nix-build nix/external-snapshotter.nix)/* gitops/apps/external-snapshotter/upstream/
    '')
    (pkgs.writeShellScriptBin "buildFlux" ''
      #!/bin/bash
      set -e
      rm -rf bootstrap/fluxcd/upstream
      mkdir -p bootstrap/fluxcd/upstream
      fluxhash=$(nix-prefetch-url https://github.com/controlplaneio-fluxcd/flux-operator/releases/download/$1/install.yaml)
      cp -r --no-preserve=mode $(nix-build nix/fluxcd.nix --argstr manifest01Hash "$fluxhash" --argstr version $1)/* bootstrap/fluxcd/upstream/
    '')
    (pkgs.writeShellScriptBin "buildCertManager" ''
      #!/bin/bash
      set -e
      rm -rf gitops/apps/cert-manager/upstream
      mkdir -p gitops/apps/cert-manager/upstream
      certmanagerhash=$(nix-prefetch-url https://github.com/cert-manager/cert-manager/releases/download/$1/cert-manager.yaml)
      cp -r --no-preserve=mode $(nix-build nix/cert-manager.nix --argstr certManagerHash "$certmanagerhash" --argstr version $1)/* gitops/apps/cert-manager/upstream/
    '')
    (pkgs.writeShellScriptBin "buildCapi" ''
      #!/bin/bash
      set -e
      rm -rf gitops/apps/cluster-api/upstream
      mkdir -p gitops/apps/cluster-api/upstream
      capihash=$(nix-prefetch-url https://github.com/kubernetes-sigs/cluster-api-operator/releases/download/$1/operator-components.yaml)
      cp -r --no-preserve=mode $(nix-build nix/capi.nix --argstr manifest01Hash "$capihash" --argstr version $1)/* gitops/apps/cluster-api/upstream/
    '')
    (pkgs.writeShellScriptBin "buildIngressContour" ''
      #!/bin/bash
      set -e
      rm -rf gitops/apps/ingress-controller/upstream
      mkdir -p gitops/apps/ingress-controller/upstream
      cp -r --no-preserve=mode $(nix-build nix/ingress-contour.nix)/* gitops/apps/ingress-controller/upstream/
    '')
    (pkgs.writeShellScriptBin "buildKamaji" ''
      #!/bin/bash
      set -e
      rm -rf gitops/apps/kamaji/upstream
      mkdir -p gitops/apps/kamaji/upstream
      cp -r --no-preserve=mode $(nix-build nix/kamaji.nix)/* gitops/apps/kamaji/upstream/
    '')
  ];
}
