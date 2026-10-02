#!/usr/bin/env python3
"""Rewrite a Grafana dashboard so it works on a multi-cluster datasource (Mimir).

- one `datasource` variable (Prometheus type, follows the Grafana default) that
  every Prometheus panel, target and variable uses;
- a visible single-value `cluster` variable;
- `cluster=~"$cluster"` added to every selector of every query and variable
  query (with promtool's PromQL rewriter, not regexes). On a single-cluster
  Prometheus the variable is empty and `cluster=~""` matches everything, so the
  dashboards keep working there.

Usage: multicluster.py <in.json> <out.json>
Writes a report of the expressions it could not rewrite to stderr.
"""

import json
import re
import subprocess
import sys

DS = {"type": "prometheus", "uid": "${datasource}"}
GRAFANA_BUILTIN = {"-- Grafana --", "grafana", "-- Mixed --", "-- Dashboard --"}
# Grafana variables: ${name}, ${name:fmt}, $name, [[name]]
VAR_RE = re.compile(r"\$\{[^}]+\}|\$\w+|\[\[\w+\]\]")

failures = []


def protect(expr):
    """Replace Grafana variables outside string literals with placeholders
    PromQL can parse: a duration inside [...] (range/subquery), else a number."""
    out, mapping = [], {}
    i, quote, depth, n = 0, None, 0, 0
    while i < len(expr):
        c = expr[i]
        if quote:
            out.append(c)
            if c == "\\" and quote != "`" and i + 1 < len(expr):
                out.append(expr[i + 1])
                i += 2
                continue
            if c == quote:
                quote = None
            i += 1
            continue
        if c in "\"'`":
            quote = c
            out.append(c)
            i += 1
            continue
        m = VAR_RE.match(expr, i)
        if m:
            n += 1
            unit = re.match(r"(ms|[smhdwy])\b", expr[m.end():]) if depth > 0 else None
            if unit:
                # `[${__range_s}s]`: a small count PromQL prints unchanged.
                ph = f"{(n - 1) % 6 + 1}{unit.group(1)}"
                if ph in mapping:
                    ph = f"{n}{unit.group(1)}"
                mapping[ph] = m.group(0) + unit.group(1)
                out.append(ph)
                i = m.end() + len(unit.group(1))
                continue
            # Sub-second durations and 9xxxxx numbers are printed as written.
            ph = f"{900 + n}ms" if depth > 0 else f"{900000 + n}"
            mapping[ph] = m.group(0)
            out.append(ph)
            i = m.end()
            continue
        if c == "[":
            depth += 1
        elif c == "]":
            depth = max(0, depth - 1)
        out.append(c)
        i += 1
    return "".join(out), mapping


def add_cluster(expr):
    if not isinstance(expr, str) or not expr.strip():
        return expr
    protected, mapping = protect(expr)
    res = subprocess.run(
        [
            "promtool",
            "--experimental",
            "promql",
            "label-matchers",
            "set",
            "--type==~",
            "--",
            protected,
            "cluster",
            "$cluster",
        ],
        capture_output=True,
        text=True,
    )
    if res.returncode != 0:
        failures.append((expr, res.stderr.strip().splitlines()[-1:]))
        return expr
    out = res.stdout.strip()
    # Longest placeholders first so 1001y never eats part of 10011y.
    for ph in sorted(mapping, key=len, reverse=True):
        out = re.sub(rf"(?<![\w.]){re.escape(ph)}(?![\w.])", lambda _: mapping[ph], out)
    return out


def rewrite_var_query(q):
    """label_values(sel, label) / label_values(label) / query_result(expr)."""
    if not isinstance(q, str):
        return q
    s = q.strip()
    m = re.fullmatch(r"label_values\(\s*(\w+)\s*\)", s)
    if m:
        return f'label_values({{cluster=~"$cluster"}}, {m.group(1)})'
    m = re.fullmatch(r"label_values\((.*),\s*(\w+)\s*\)", s, re.S)
    if m:
        return f"label_values({add_cluster(m.group(1))}, {m.group(2)})"
    m = re.fullmatch(r"query_result\((.*)\)", s, re.S)
    if m:
        return f"query_result({add_cluster(m.group(1))})"
    return q


def is_prometheus_ref(ds, ds_names):
    if ds is None:
        return False
    if isinstance(ds, str):
        return ds not in GRAFANA_BUILTIN
    if isinstance(ds, dict):
        uid, typ = ds.get("uid"), ds.get("type")
        if uid in GRAFANA_BUILTIN or typ in ("grafana", "datasource", "dashboard"):
            return False
        return typ in (None, "prometheus") or uid in ds_names
    return False


def walk(node, ds_names):
    if isinstance(node, dict):
        if "datasource" in node and is_prometheus_ref(node["datasource"], ds_names):
            node["datasource"] = dict(DS)
        if "expr" in node and "$cluster" not in str(node["expr"]):
            node["expr"] = add_cluster(node["expr"])
        for k, v in node.items():
            if k != "templating":
                walk(v, ds_names)
    elif isinstance(node, list):
        for v in node:
            walk(v, ds_names)


def main(src, dst):
    raw = open(src).read()
    d = json.loads(raw)
    tl = d.setdefault("templating", {}).setdefault("list", [])

    # Datasource inputs / variables (DS_PROMETHEUS, DATASOURCE, ...) -> $datasource
    old = [i["name"] for i in d.get("__inputs", []) if i.get("type") == "datasource"]
    old += [v["name"] for v in tl if v.get("type") == "datasource"]
    text = json.dumps(d)
    for name in set(old):
        text = text.replace("${%s}" % name, "${datasource}")
        text = re.sub(r"\$%s\b" % re.escape(name), "${datasource}", text)
    d = json.loads(text)
    tl = d["templating"]["list"]
    for k in ("__inputs", "__requires", "id"):
        d.pop(k, None)

    tl[:] = [v for v in tl if v.get("type") != "datasource"]
    ds_var = {
        "name": "datasource",
        "label": "Data source",
        "type": "datasource",
        "query": "prometheus",
        "hide": 0,
        "current": {},
        "options": [],
        "refresh": 1,
        "regex": "",
    }
    cluster = next((v for v in tl if v.get("name") == "cluster"), None)
    if cluster:
        tl.remove(cluster)
        cluster["hide"] = 0
        cluster["datasource"] = dict(DS)
    else:
        q = 'label_values(up, cluster)'
        cluster = {
            "name": "cluster",
            "label": "cluster",
            "type": "query",
            "datasource": dict(DS),
            "query": {"query": q, "refId": "PrometheusVariableQueryEditor-VariableQuery", "qryType": 1},
            "definition": q,
            "refresh": 2,
            "hide": 0,
            "includeAll": False,
            "multi": False,
            "sort": 1,
            "current": {},
            "options": [],
        }
    tl[:0] = [ds_var, cluster]

    for v in tl[2:]:
        if v.get("type") != "query":
            continue
        if is_prometheus_ref(v.get("datasource"), set(old)) or v.get("datasource") is None:
            v["datasource"] = dict(DS)
        if isinstance(v.get("query"), dict):
            v["query"]["query"] = rewrite_var_query(v["query"].get("query"))
        else:
            v["query"] = rewrite_var_query(v.get("query"))
        if isinstance(v.get("definition"), str):
            v["definition"] = rewrite_var_query(v["definition"])
        v["current"] = {}
        v["options"] = []

    walk(d, set(old))
    with open(dst, "w") as f:
        json.dump(d, f, indent=1, sort_keys=False)
        f.write("\n")
    for expr, err in failures:
        print(f"{src}: not rewritten: {expr[:160]!r} {err}", file=sys.stderr)
    # Fail the build rather than ship a panel that ignores the cluster picker.
    if failures:
        sys.exit(1)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
