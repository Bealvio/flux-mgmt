#!/usr/bin/env python3
"""Lint: every Sveltos selector under gitops/apps/sveltos (including the ones
inside ConfigMap templates that EventTriggers render into ClusterProfiles),
and every EventSource labelFilter on a CAPI Cluster, may only use the add-on
label catalog below. Exit 1 on anything else.

Catalog: addons.bealv.io/<addon> (value `enabled`, or the variant for
cert-manager: gatewayapi|generic), `type` (mgmt|workload) and
`cluster.x-k8s.io/cluster-name` (per-cluster profiles).
"""
import pathlib, re, sys

ALLOWED = re.compile(r"^(addons\.bealv\.io/[a-z0-9-]+|type|cluster\.x-k8s\.io/cluster-name)$")
SELECTOR = re.compile(r"^(\s*)(clusterSelector|sourceClusterSelector|destinationClusterSelector):\s*$")
bad = []
for path in sorted(pathlib.Path("gitops/apps/sveltos").rglob("*.yaml")):
    lines = path.read_text().splitlines()
    for i, line in enumerate(lines):
        m = SELECTOR.match(line)
        if not m:
            continue
        base = len(m.group(1))
        j, mode = i + 1, None
        while j < len(lines) and (not lines[j].strip() or len(lines[j]) - len(lines[j].lstrip()) > base):
            l = lines[j].strip()
            if l in ("matchLabels:", "matchExpressions:"):
                mode = l[:-1]
            elif mode == "matchLabels" and ":" in l:
                key = l.split(":", 1)[0].strip().strip("'\"")
                if not ALLOWED.match(key):
                    bad.append(f"{path}:{j+1}: {key}")
            elif mode == "matchExpressions" and l.lstrip("- ").startswith("key:"):
                key = l.lstrip("- ")[4:].strip().strip("'\"")
                if not ALLOWED.match(key):
                    bad.append(f"{path}:{j+1}: {key}")
            j += 1
# EventSource labelFilters on CAPI Clusters select clusters by label too: an
# event that stops matching deletes the profile generated for it.
for path in sorted(pathlib.Path("gitops/apps/sveltos").rglob("*.yaml")):
    for doc in path.read_text().split("\n---\n"):
        if not re.search(r"(?m)^kind: EventSource$", doc):
            continue
        for sel in re.split(r"(?m)^\s*- group:", doc)[1:]:
            if not re.search(r'kind:\s*"?Cluster"?\s*$', sel, re.M):
                continue
            for key in re.findall(r"(?m)^\s*- key:\s*['\"]?([^'\"\s]+)", sel):
                if not ALLOWED.match(key):
                    bad.append(f"{path}: EventSource labelFilter {key}")
for b in bad:
    print("selector label outside the add-on catalog:", b)
sys.exit(1 if bad else 0)
