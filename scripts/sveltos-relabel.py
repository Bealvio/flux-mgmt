#!/usr/bin/env python3
"""One-off helper for the addons.bealv.io/* label migration: rewrites the
clusterSelector (ClusterProfile) / sourceClusterSelector (EventTrigger) of the
named objects in gitops/apps/sveltos/clusterprofiles/*.yaml, in place and
textually (comments and formatting elsewhere untouched).

usage: sveltos-relabel.py NAME [NAME...]
"""
import glob, re, sys

OLD_TO_NEW = {
    ("fluxcd", "true"): ("addons.bealv.io/flux", "enabled"),
    ("cni", "cilium"): ("addons.bealv.io/cilium", "enabled"),
    ("cert-manager-setup", "gatewayapi"): ("addons.bealv.io/cert-manager", "gatewayapi"),
    ("cert-manager-setup", "generic"): ("addons.bealv.io/cert-manager", "generic"),
    ("external-secret", "true"): ("addons.bealv.io/external-secrets", "enabled"),
}

def new_label(k, v):
    if (k, v) in OLD_TO_NEW:
        return OLD_TO_NEW[(k, v)]
    if v == "true":
        return (f"addons.bealv.io/{k}", "enabled")
    raise SystemExit(f"no mapping for {k}={v}")

names = set(sys.argv[1:])
done = set()
for path in sorted(glob.glob("gitops/apps/sveltos/clusterprofiles/*.yaml")):
    docs = open(path).read().split("\n---\n")
    changed = False
    for i, doc in enumerate(docs):
        m = re.search(r"(?m)^kind: (ClusterProfile|EventTrigger)\nmetadata:\n  name: (\S+)", doc)
        if not m or m.group(2) not in names:
            continue
        sel = re.search(r"(?m)^(  (?:clusterSelector|sourceClusterSelector):\n    matchLabels:\n)((?:      \S+: .+\n)+)", doc)
        if not sel:
            raise SystemExit(f"{m.group(2)}: no matchLabels selector found")
        labels = re.findall(r"(?m)^      (\S+): (.+)$", sel.group(2))
        out = {}
        for k, v in labels:
            v = v.strip().strip('"').strip("'")
            if k == "type" or k.startswith("addons.bealv.io/"):
                out[k] = v
                continue
            if k == "cert-manager" and any(l[0] == "cert-manager-setup" for l in labels):
                continue  # folded into the cert-manager variant value
            nk, nv = new_label(k, v)
            out[nk] = nv
        if m.group(1) == "ClusterProfile" or "type" not in out:
            out.setdefault("type", "workload")
        body = "".join(f'      {k}: "{v}"\n' if k != "type" else f"      {k}: {v}\n" for k, v in sorted(out.items(), key=lambda kv: (kv[0] != "type", kv[0])))
        docs[i] = doc[: sel.start(2)] + body + doc[sel.end(2):]
        changed = True
        done.add(m.group(2))
        print(f"{m.group(2)}: {dict(labels)} -> {out}")
    if changed:
        open(path, "w").write("\n---\n".join(docs))
missing = names - done
if missing:
    raise SystemExit(f"not found: {sorted(missing)}")
