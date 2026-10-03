#!/usr/bin/env bash
# Compare which live clusters every ClusterProfile/EventTrigger selects at git
# ref $1 (default origin/main) vs the working tree. Any difference means a
# profile would start or STOP matching a cluster (stop = Sveltos withdraws
# its resources unless LeavePolicies). Covers clusterSelector and EventTrigger
# source/destination selectors. Empty output + exit 0 = safe.
set -euo pipefail
base="${1:-origin/main}"
ctx="${KUBE_CONTEXT:-bealv/kubernetes-admin@mgmt}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
kubectl --context "$ctx" get clusters.cluster.x-k8s.io,sveltosclusters.lib.projectsveltos.io -A -o json |
  jq '[.items[] | {name: (.kind + ":" + .metadata.namespace + "/" + .metadata.name), labels: (.metadata.labels // {})}]' >"$tmp/clusters.json"
render() { kustomize build "$1/gitops/apps/sveltos/clusterprofiles" | yq -o json -I0 'select(.kind=="ClusterProfile" or .kind=="EventTrigger")' | jq -s .; }
git worktree add -q "$tmp/base" "$base"
render "$tmp/base" >"$tmp/before.json"
git worktree remove --force "$tmp/base"
render . >"$tmp/after.json"
# shellcheck disable=SC2016 # jq program, $vars are jq's
match='
def sels: [["selects", .spec.clusterSelector], ["source", .spec.sourceClusterSelector], ["destination", .spec.destinationClusterSelector]] | map(select(.[1] != null));
def ok($l; $s): ((($s.matchLabels // {}) | to_entries | all(. as $e | $l[$e.key] == $e.value))
  and (($s.matchExpressions // []) | all(. as $x |
     if $x.operator == "In" then ($l[$x.key] as $v | $x.values | index($v)) != null
     elif $x.operator == "NotIn" then ($l[$x.key] as $v | ($x.values | index($v)) == null)
     elif $x.operator == "Exists" then $l | has($x.key)
     elif $x.operator == "DoesNotExist" then ($l | has($x.key)) | not
     else error("operator") end)));
[.[] | (.kind + "/" + .metadata.name) as $n | sels[] | {k: ($n + " " + .[0]), s: .[1]}] as $p
| [$p[] | . as $q | {k: $q.k, m: [$clusters[] | select(ok(.labels; $q.s)) | .name] | sort}] | sort_by(.k)'
jq --slurpfile c "$tmp/clusters.json" "\$c[0] as \$clusters | $match" "$tmp/before.json" >"$tmp/m-before.json"
jq --slurpfile c "$tmp/clusters.json" "\$c[0] as \$clusters | $match" "$tmp/after.json" >"$tmp/m-after.json"
if diff <(jq -r '.[] | "\(.k) -> \(.m|join(","))"' "$tmp/m-before.json") <(jq -r '.[] | "\(.k) -> \(.m|join(","))"' "$tmp/m-after.json"); then
  echo "match sets identical ($(jq length "$tmp/m-after.json") profiles/triggers)"
else
  echo "MATCH SETS CHANGED" >&2
  exit 1
fi
