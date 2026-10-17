#!/usr/bin/env bash
set -euo pipefail

dir=${1:?usage: pkg-inputplumber.sh <rpmdir>}
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }
. "$dir/SOURCE.env"
version=${INPUTPLUMBER_VERSION:?SOURCE.env has no INPUTPLUMBER_VERSION}

rpm=$(find "$dir" -maxdepth 1 -name "inputplumber-$version-*.rpm" ! -name '*.src.rpm')
if [[ -z $rpm || $(wc -l <<<"$rpm") -ne 1 ]]; then
  echo "FAIL: expected one inputplumber RPM in $dir" >&2
  exit 1
fi
if [[ -z $(find "$dir" -maxdepth 1 -name "inputplumber-$version-*.src.rpm") ]]; then fail "SRPM missing"; fi
if [[ -n $(find "$dir" -maxdepth 1 \( -name '*-debuginfo-*' -o -name '*-debugsource-*' \)) ]]; then fail "debug RPM present"; fi

if [[ $(rpm -qp --qf '%{RELEASE}' "$rpm") != *.microos ]]; then fail "release"; fi
if [[ $(rpm -qp --qf '%{VENDOR}' "$rpm") != MicroOS ]]; then fail "vendor"; fi

writable=$(rpm -qp --qf '[%{FILEMODES:perms} %{FILENAMES}\n]' "$rpm" | awk 'substr($1, 1, 1) != "l" && (substr($1, 6, 1) == "w" || substr($1, 9, 1) == "w")')
if [[ -n $writable ]]; then fail "group or other writable: $writable"; fi

files=$(rpm -qlp "$rpm")
for f in \
  /usr/share/licenses/inputplumber/LICENSE \
  /usr/bin/inputplumber \
  /usr/lib/systemd/system/inputplumber.service \
  /usr/lib/systemd/system/inputplumber-suspend.service \
  /usr/share/dbus-1/system.d/org.shadowblip.InputPlumber.conf \
  /usr/share/polkit-1/actions/org.shadowblip.InputPlumber.policy \
  /usr/share/polkit-1/rules.d/50-microos-inputplumber.rules \
  /usr/lib/udev/rules.d/90-inputplumber-autostart.rules \
  /usr/share/inputplumber/schema/composite_device_v1.json \
  /usr/share/inputplumber/schema/capability_map_v2.json; do
  if ! grep -qx "$f" <<<"$files"; then fail "missing $f"; fi
done
for f in /usr/lib/modules-load.d/ /usr/share/dbus-1/system-services/ /usr/share/polkit-1/rules.d/org.shadowblip.InputPlumber.rules; do
  if grep -q "^$f" <<<"$files"; then fail "ships $f"; fi
done
if (( $(grep -c '^/usr/share/inputplumber/devices/.*\.yaml$' <<<"$files") < 50 )); then fail "upstream device configs missing"; fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
(cd "$tmp" && rpm2cpio "$rpm" | cpio -idm --quiet './usr/share/polkit-1/*')
policy=$tmp/usr/share/polkit-1/actions/org.shadowblip.InputPlumber.policy
rule=$tmp/usr/share/polkit-1/rules.d/50-microos-inputplumber.rules
grant='org.shadowblip.Input.CompositeDevice.SetTargetDevices org.shadowblip.Input.CompositeDevice.SetInterceptMode org.shadowblip.Output.ForceFeedback.Rumble'
python3 - "$policy" "$rule" "$grant" > "$tmp/ids" <<'PY' || fail "polkit rule partition"
import re, sys
import xml.etree.ElementTree as ET
policy, rule, grant = sys.argv[1], open(sys.argv[2]).read(), set(sys.argv[3].split())
ids = {}
for a in ET.parse(policy).getroot().findall("action"):
    d = a.find("defaults")
    ids[a.get("id")] = tuple(d.find(k).text for k in ("allow_any", "allow_inactive", "allow_active"))
closed = {i for i, v in ids.items() if v[0] != "yes"}
def array(name):
    m = re.search(r"var %s = \[(.*?)\];" % name, rule, re.S)
    return re.findall(r'"([^"]+)"', m.group(1)) if m else []
g, d = array("grant"), array("deny")
bad = []
if len(g) != len(set(g)) or len(d) != len(set(d)):
    bad.append("duplicate ids")
if set(g) != grant:
    bad.append("grant is %s" % sorted(g))
for i in sorted(closed):
    if (i in g) + (i in d) != 1:
        bad.append("%s in %d of grant and deny" % (i, (i in g) + (i in d)))
for i in sorted(set(g) | set(d)):
    if i not in ids:
        bad.append("%s not in the policy" % i)
    elif i not in closed:
        bad.append("%s is allow_any %s" % (i, ids[i][0]))
for i in ("Input.Keyboard.SendKey", "Input.CompositeDevice.SendEvent", "InputPlumber.CreateTargetDevice",
          "InputPlumber.AttachTargetDevice", "Input.CompositeDevice.LoadProfilePath",
          "Input.CompositeDevice.LoadProfileFromYaml", "InputPlumber.SetManageAllDevices",
          "Input.CompositeDevice.SetFilteredEvents"):
    if "org.shadowblip." + i not in d:
        bad.append("org.shadowblip.%s not in deny" % i)
if ids.get("org.shadowblip.Input.CompositeDevice.SetFilteredEvents") != ("no", "no", "auth_admin"):
    bad.append("SetFilteredEvents defaults %s" % (ids.get("org.shadowblip.Input.CompositeDevice.SetFilteredEvents"),))
if 'subject.user != "micro"' not in rule or "isInGroup" in rule:
    bad.append("rule is not keyed on subject.user micro alone")
for i in sorted(ids):
    print(i, "closed" if i in closed else "open")
if bad:
    sys.exit("\n".join(bad))
PY
command -v node >/dev/null || fail "node missing"
cat > "$tmp/eval.js" <<'JS'
const fs = require("fs");
const [rule, idsFile, grant] = process.argv.slice(2);
const rules = [];
const polkit = { Result: { YES: "yes", NO: "no" }, addRule: (f) => rules.push(f), log: () => {} };
new Function("polkit", fs.readFileSync(rule, "utf8"))(polkit);
if (rules.length !== 1) throw new Error("rules: " + rules.length);
const granted = new Set(grant.split(" "));
const bad = [];
for (const line of fs.readFileSync(idsFile, "utf8").trim().split("\n")) {
  const [id, kind] = line.split(" ");
  for (const user of ["micro", "deck", "root"]) {
    const subject = { user, isInGroup: () => { throw new Error("isInGroup"); } };
    const action = { id, lookup: () => undefined };
    const got = rules[0](action, subject);
    const want = user !== "micro" ? undefined : granted.has(id) ? "yes" : kind === "closed" ? "no" : undefined;
    if (got !== want) bad.push(`${user} ${id}: ${got}, want ${want}`);
  }
}
if (bad.length) { console.error(bad.join("\n")); process.exit(1); }
JS
node "$tmp/eval.js" "$rule" "$tmp/ids" "$grant" || fail "polkit rule evaluation"

exit "$rc"
