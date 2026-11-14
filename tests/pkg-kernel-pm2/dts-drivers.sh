#!/usr/bin/env bash
set -euo pipefail

dtb=${1:?usage: dts-drivers.sh <dtb> <config> [table]}
config=${2:?usage: dts-drivers.sh <dtb> <config> [table]}
table=${3:-$(dirname "$0")/compatible-symbols.txt}

dtc -q -I dtb -O dts "$dtb" | awk -v table="$table" -v config="$config" '
BEGIN {
  while ((getline l < table) > 0) {
    if (l ~ /^[[:space:]]*$/) continue
    split(l, f, /[[:space:]]+/)
    sym[f[1]] = f[2]
  }
  while ((getline l < config) > 0) {
    if (l ~ /^CONFIG_[A-Za-z0-9_]+=[ym]$/) {
      split(l, f, "=")
      set[substr(f[1], 8)] = 1
    }
  }
  depth = 0
  path[0] = ""
}
/^[[:space:]]*[^[:space:]]+[[:space:]]*\{[[:space:]]*$/ {
  name = $0
  sub(/^[[:space:]]*/, "", name)
  sub(/[[:space:]]*\{.*/, "", name)
  sub(/^[^:]*:[[:space:]]*/, "", name)
  depth++
  if (name == "/") path[depth] = "/"
  else path[depth] = (path[depth - 1] == "/" ? "" : path[depth - 1]) "/" name
  nodes[path[depth]] = 1
  next
}
/^[[:space:]]*status[[:space:]]*=/ {
  if ($0 !~ /"okay"|"ok"/) off[path[depth]] = 1
  next
}
/^[[:space:]]*compatible[[:space:]]*=/ {
  line = $0
  sub(/^[^=]*=[[:space:]]*/, "", line)
  sub(/;[[:space:]]*$/, "", line)
  gsub(/"[[:space:]]*,[[:space:]]*"/, "\t", line)
  gsub(/\\0/, "\t", line)
  gsub(/"/, "", line)
  compat[path[depth]] = line
  next
}
/^[[:space:]]*\};[[:space:]]*$/ {
  if (depth > 0) depth--
  next
}
END {
  bad = 0
  for (p in compat) {
    enabled = 1
    q = p
    while (q != "") {
      if (q in off) { enabled = 0; break }
      sub(/\/[^\/]*$/, "", q)
    }
    if (!enabled) continue
    n = split(compat[p], c, "\t")
    known = 0
    ok = 0
    for (i = 1; i <= n; i++) {
      if (!(c[i] in sym)) continue
      known = 1
      if (sym[c[i]] == "-" || (sym[c[i]] in set)) ok = 1
    }
    if (!known) {
      printf "%s: no table entry for %s\n", p, compat[p]
      bad = 1
    } else if (!ok) {
      printf "%s: driver not enabled for %s\n", p, compat[p]
      bad = 1
    }
  }
  exit bad
}'
echo "dts-drivers: every enabled node has its driver"
