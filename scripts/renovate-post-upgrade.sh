#!/usr/bin/env bash
# Renovate postUpgradeTask (see renovate.json5), run inside `devenv shell`.
# Renovate has already bumped `version` (or `revision` for branch pins) of
# <pin> in npins/sources.json; refresh the rest of the pin and regenerate
# whatever is built from it.
#
# Usage: scripts/renovate-post-upgrade.sh <pin> <version>
set -euo pipefail

pin="$1"
version="${2:-}"

npins update --partial "$pin"

case "$pin" in
cert-manager) buildCertManager "$version" ;;
cluster-api-operator) buildCapi "$version" ;;
contour) buildIngressContour ;;
external-snapshotter) buildSnapshotter ;;
flux-operator) buildFlux "$version" ;;
kube-prometheus | kubevirt-monitoring) buildKubeProm ;;
grafana-operator)
  buildKubeProm
  yq e -i '(.images[] | select(.name == "ghcr.io/grafana/grafana-operator")).newTag = "'"$version"'"' \
    gitops/apps/monitoring/kustomization.yaml
  ;;
kamaji)
  buildKamaji
  yq e -i '.spec.ref.tag = "'"$version"'"' gitops/apps/kamaji/setup/gitrepo.yaml
  yq e -i '.spec.values.image.tag = "'"$version"'"' gitops/apps/kamaji/setup/helmrelease.yaml
  ;;
nixbook) ;; # devenv module, nothing to generate
*)
  echo "renovate-post-upgrade: no build step known for pin '$pin'" >&2
  exit 1
  ;;
esac

treefmt
