{
  pkgs ? import <nixpkgs> { },
}:
let
  # inherit (pkgs) lib;
  sources = import ../npins;
  manifest01 = sources.external-snapshotter;
in
pkgs.runCommand "external-snapshotter"
  {
    nativeBuildInputs = [
      pkgs.kustomize
    ];
  }
  ''
    set -e
    mkdir -p $out/
    kustomize init
    kustomize build ${manifest01}/client/config/crd > ./crds.yaml
    kustomize build ${manifest01}/deploy/kubernetes/csi-snapshotter > ./csi-snapshotter.yaml
    kustomize build ${manifest01}/deploy/kubernetes/snapshot-controller > ./snapshot-controller.yaml
    kustomize edit add resource *.yaml
    cp ./*.yaml $out/
  ''
