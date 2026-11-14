#!/usr/bin/env bash
set -euo pipefail

src=${1:?usage: smb5-pd.sh <kernel source dir> <dtb>}
dtb=${2:?usage: smb5-pd.sh <kernel source dir> <dtb>}
c=$src/drivers/power/supply/qcom_pm8150b_charger.c
here=$(cd "$(dirname "$0")" && pwd)
cases=$here/smb5-pd
[[ -f $c ]] || { echo "smb5-pd: no $c" >&2; exit 1; }
[[ -f $dtb ]] || { echo "smb5-pd: no $dtb" >&2; exit 1; }

body() {
	awk -v name="$2" '
		/^[A-Za-z_][A-Za-z0-9_][A-Za-z0-9_ *]*[ *][A-Za-z_][A-Za-z0-9_]*\(/ && !/;[[:space:]]*$/ {
			n = $0
			sub(/\(.*/, "", n)
			sub(/.*[ *]/, "", n)
			if (n == name) { on = 1; print; next }
			on = 0
		}
		on { print }
		on && /^}/ { exit }
	' "$1"
}

fail() {
	echo "smb5-pd: $1" >&2
	exit 1
}

check_dtb() {
	local text ph

	text=$(dtc -q -I dtb -O dts "$dtb")
	[[ -n $text ]] || fail "dtc produced nothing for $dtb"

	ph=$(printf '%s\n' "$text" | awk '
		function endnode(d) {
			if (comp[d] == "qcom,pm8150b-charger") { charger = ph[d]; has_charger = 1; cps = ps[d]; has_cps = has_ps[d] }
			if (comp[d] == "qcom,pm8150b-typec") { typec = ph[d]; has_typec = (ph[d] != "") }
			if (comp[d] == "qcom,pm8150b-fg") { fg = ph[d]; has_fg = 1; fps = ps[d] }
			comp[d] = ""; ph[d] = ""; ps[d] = ""; has_ps[d] = 0
		}
		/\{[[:space:]]*$/ && !/=/ {
			d++
			comp[d] = ""; ph[d] = ""; ps[d] = ""; has_ps[d] = 0
			next
		}
		/^[[:space:]]*\};[[:space:]]*$/ { endnode(d); d--; next }
		/^[[:space:]]*compatible = "/ {
			v = $0
			sub(/.*compatible = "/, "", v)
			sub(/".*/, "", v)
			if (comp[d] == "") comp[d] = v
			next
		}
		/^[[:space:]]*phandle = </ {
			v = $0
			sub(/.*phandle = </, "", v)
			sub(/>.*/, "", v)
			ph[d] = v
			next
		}
		/^[[:space:]]*power-supplies = </ {
			v = $0
			sub(/.*power-supplies = </, "", v)
			sub(/>.*/, "", v)
			ps[d] = v
			has_ps[d] = 1
			next
		}
		END {
			if (!has_charger) { print "NOCHARGER"; exit }
			if (!has_cps) { print "NOPS"; exit }
			if (!has_typec) { print "NOTYPEC"; exit }
			if (!has_fg) { print "NOFG"; exit }
			if (cps != typec) { printf "PSNOTTYPEC %s %s\n", cps, typec; exit }
			if (fps != charger) { printf "FGNOTCHARGER %s %s\n", fps, charger; exit }
			print "OK"
		}
	') || fail "the device tree power-supplies links are wrong"

	case $ph in
	OK) ;;
	NOCHARGER) fail "no qcom,pm8150b-charger node in $dtb" ;;
	NOTYPEC) fail "no qcom,pm8150b-typec node with a phandle in $dtb" ;;
	NOFG) fail "no qcom,pm8150b-fg node in $dtb" ;;
	NOPS) fail "the charger node has no power-supplies" ;;
	PSNOTTYPEC*) fail "the charger power-supplies $(printf '%s' "$ph" | cut -d' ' -f2) is not the typec phandle $(printf '%s' "$ph" | cut -d' ' -f3)" ;;
	FGNOTCHARGER*) fail "the fuel gauge power-supplies $(printf '%s' "$ph" | cut -d' ' -f2) is not the charger phandle $(printf '%s' "$ph" | cut -d' ' -f3)" ;;
	*) fail "the device tree power-supplies check returned $ph" ;;
	esac
}

check_lock() {
	awk '
		function funcname(l) {
			s = l
			sub(/\(.*/, "", s)
			sub(/.*[ *]/, "", s)
			return s
		}
		{ line[NR] = $0 }
		END {
			n = NR
			i = 1
			while (i <= n) {
				l = line[i]
				if (l ~ /^[A-Za-z_][A-Za-z0-9_][A-Za-z0-9_ *]*[ *][A-Za-z_][A-Za-z0-9_]*\(/ && l !~ /;[[:space:]]*$/) {
					if (fname != "" && held) {
						printf "%s never unlocks chip->lock\n", fname
						bad = 1
					}
					fname = funcname(l)
					held = 0
					bodyline = 0
					early = 0
					i++
					continue
				}
				if (fname == "") { i++; continue }
				if (l ~ /^}/) {
					if (held) {
						printf "%s never unlocks chip->lock\n", fname
						bad = 1
					}
					fname = ""
					held = 0
					early = 0
					i++
					continue
				}
				bodyline++
				if (bodyline == 1 && l ~ /^[[:space:]]*lockdep_assert_held\(&chip->lock\);[[:space:]]*$/)
					held = 1
				if (l ~ /^[[:space:]]*mutex_lock\(&chip->lock\);[[:space:]]*$/) {
					held = 1
					i++
					continue
				}
				if (l ~ /^[[:space:]]*mutex_unlock\(&chip->lock\);[[:space:]]*$/) {
					j = i + 1
					while (j <= n && line[j] ~ /^[[:space:]]*$/)
						j++
					if (j <= n && line[j] ~ /^[[:space:]]*(return|goto)/) {
						early++
						if (early > 1) {
							printf "%s line %d has more than one early exit unlock\n", fname, i
							bad = 1
						}
					} else {
						held = 0
					}
					i++
					continue
				}
				if (l ~ /(^|[^A-Za-z0-9_])(smb5_write_icl|smb5_apsd_rerun|smb5_set_bc12)\(/ && !held) {
					printf "%s line %d calls a helper without chip->lock\n", fname, i
					bad = 1
				}
				if (held && l ~ /(^|[^A-Za-z0-9_])(power_supply_changed|power_supply_get_property_from_supplier|mod_delayed_work|regmap_read)\(/) {
					printf "%s line %d runs an unlocked operation under chip->lock\n", fname, i
					bad = 1
				}
				i++
			}
			exit bad ? 1 : 0
		}
	' "$1" || fail "the chip->lock regions are wrong in $1"

	awk '
		{
			l = $0
			if (l ~ /^[A-Za-z_][A-Za-z0-9_][A-Za-z0-9_ *]*[ *][A-Za-z_][A-Za-z0-9_]*\(/ && l !~ /;[[:space:]]*$/) {
				n = l
				sub(/\(.*/, "", n)
				sub(/.*[ *]/, "", n)
				fname = n
				guarded = 0
				next
			}
			if (fname == "")
				next
			if (l ~ /^}/) {
				fname = ""
				next
			}
			if (l ~ /^[[:space:]]*lockdep_assert_held\(&chip->lock\);[[:space:]]*$/) {
				guarded = 1
				next
			}
			if (l ~ /(^|[^A-Za-z0-9_])(regmap_write|regmap_update_bits|regmap_bulk_write)\(/ &&
			    l ~ /USBIN_CURRENT_LIMIT_CFG|USBIN_ICL_OPTIONS|CMD_ICL_OVERRIDE|USBIN_LOAD_CFG|CMD_APSD|USBIN_OPTIONS_1_CFG/ &&
			    !guarded && fname != "smb5_init_seq") {
				printf "%s line %d writes a locked register without lockdep_assert_held\n", fname, NR
				bad = 1
			}
		}
		END { exit bad ? 1 : 0 }
	' "$1" || fail "a locked register write has no lockdep_assert_held in $1"

	! grep -qE 'guard\(mutex\)|scoped_guard\(' "$1" || fail "guard() replaced the explicit lock in $1"
}

check_structure() {
	local p w

	! grep -q 'msleep' "$1" || fail "msleep in $1"
	! grep -q 'Apsd not ready' "$1" || fail "Apsd not ready log in $1"
	grep -q '\.external_power_changed' "$1" || fail "no external_power_changed in $1"
	! grep -q '3300000' "$1" || fail "3300000 still in $1"
	grep -qE '^#define SDP_CURRENT_UA[[:space:]]+500000$' "$1" || fail "SDP_CURRENT_UA is not 500000 in $1"
	grep -qE '^#define CDP_CURRENT_UA[[:space:]]+1500000$' "$1" || fail "CDP_CURRENT_UA is not 1500000 in $1"
	grep -qE '^#define DCP_CURRENT_UA[[:space:]]+3000000$' "$1" || fail "DCP_CURRENT_UA is not 3000000 in $1"
	grep -qE '^#define APSD_RERUNS[[:space:]]+4$' "$1" || fail "APSD_RERUNS is not 4 in $1"

	p=$(body "$1" smb5_probe | grep -n 'devm_mutex_init\|devm_delayed_work_autocancel\|devm_power_supply_register' | cut -d: -f1)
	[[ $(printf '%s\n' "$p" | grep -c .) -eq 3 ]] || fail "smb5_probe does not init the lock and the work once each"
	[[ $(printf '%s\n' "$p" | sed -n '1p') -lt $(printf '%s\n' "$p" | sed -n '3p') ]] \
		|| fail "devm_mutex_init comes after devm_power_supply_register"
	[[ $(printf '%s\n' "$p" | sed -n '2p') -lt $(printf '%s\n' "$p" | sed -n '3p') ]] \
		|| fail "devm_delayed_work_autocancel comes after devm_power_supply_register"

	w=$(body "$1" smb5_status_change_work)
	[[ -n $w ]] || fail "smb5_status_change_work not found in $1"
	[[ $w == *'smb5_rerun_step('* ]] || fail "the work does not call smb5_rerun_step"

	printf '%s\n' "$w" | awk '
		/READ_ONCE\(chip->plug_gen\)/ { want = NR + 1; next }
		want == NR {
			if ($0 !~ /^[[:space:]]*rmb\(\);[[:space:]]*$/) {
				print "no rmb() after the plug_gen snapshot"
				bad = 1
			}
			want = 0
			next
		}
		/plug_gen/ && /!=/ { cmp = NR }
		/mutex_lock\(&chip->lock\);/ { if (!lock) lock = NR }
		END {
			if (bad) exit 1
			if (cmp == 0 || lock == 0 || cmp < lock) {
				print "plug_gen is not compared after mutex_lock"
				exit 1
			}
		}
	' || fail "the work barrier or the plug_gen check is wrong in $1"

	ph=$(body "$1" smb5_handle_usb_plugin)
	[[ -n $ph ]] || fail "smb5_handle_usb_plugin not found in $1"
	[[ $ph == *'chip->plug_gen++'* ]] || fail "the plug handler does not bump plug_gen"
	[[ $ph == *'icl_ua = UINT_MAX'* ]] || fail "the plug handler does not reset the cached icl_ua"
	[[ $ph == *'smb5_write_icl('* ]] || fail "the plug handler does not write the 500 mA limit"
	[[ $ph == *'smb5_set_bc12(chip, true)'* ]] || fail "the plug handler does not re-enable bc12"
	[[ $ph == *'msecs_to_jiffies(1500)'* ]] || fail "the plug handler does not delay the first pass by 1500 ms"

	awk '
		/^[A-Za-z_][A-Za-z0-9_][A-Za-z0-9_ *]*[ *][A-Za-z_][A-Za-z0-9_]*\(/ && !/;[[:space:]]*$/ {
			n = $0
			sub(/\(.*/, "", n)
			sub(/.*[ *]/, "", n)
			name = n
			next
		}
		/HZ[[:space:]]*<</ && name != "smb5_rerun_step" {
			printf "HZ << outside smb5_rerun_step in %s\n", name
			bad = 1
		}
		END { exit bad ? 1 : 0 }
	' "$1" || fail "the rerun schedule escapes smb5_rerun_step in $1"
}

check_selection() {
	local dir hz

	dir=$(mktemp -d)
	{
		grep -E '^#define (SDP|CDP|DCP)_CURRENT_UA|^#define CURRENT_MAX_UA' "$1"
		awk '/^struct smb5_port_state \{/ { on = 1 } on { print } on && /^};/ { on = 0 }' "$1"
		awk '/^struct smb5_pick \{/ { on = 1 } on { print } on && /^};/ { on = 0 }' "$1"
		body "$1" smb5_pick
	} > "$dir/pick_gen.inc"
	{
		grep -E '^#define APSD_RERUNS' "$1"
		awk '/^struct smb5_rerun \{/ { on = 1 } on { print } on && /^};/ { on = 0 }' "$1"
		body "$1" smb5_rerun_step
	} > "$dir/rerun_gen.inc"

	if ! grep -q 'smb5_rerun_step(unsigned long' "$dir/rerun_gen.inc"; then
		rm -rf "$dir"
		fail "smb5_rerun_step does not extract from $1"
	fi

	cp "$cases/smb5_stub.h" "$cases/pick.c" "$cases/rerun.c" "$dir/"

	gcc -std=gnu11 -Wall -Werror -DHZ=100 -I"$dir" -o "$dir/pick" "$dir/pick.c" \
		|| { rm -rf "$dir"; fail "pick.c does not build"; }
	"$dir/pick" || { rm -rf "$dir"; fail "the selection table does not match smb5_pick"; }

	for hz in 100 250 1000; do
		gcc -std=gnu11 -Wall -Werror -DHZ="$hz" -I"$dir" -o "$dir/rerun" "$dir/rerun.c" \
			|| { rm -rf "$dir"; fail "rerun.c does not build at HZ $hz"; }
		"$dir/rerun" >/dev/null || { rm -rf "$dir"; fail "the rerun schedule is wrong at HZ $hz"; }
	done

	rm -rf "$dir"
}

src_checks() {
	check_structure "$1"
	check_lock "$1"
	check_selection "$1"
}

mutate() {
	awk -v n="$2" '
		function funcname(l) {
			s = l
			sub(/\(.*/, "", s)
			sub(/.*[ *]/, "", s)
			return s
		}
		function where(want) {
			for (k = 1; k <= nlines; k++)
				if (fname[k] == want)
					return k
			return 0
		}
		function findline(from, pat,   k) {
			for (k = from; k <= nlines; k++)
				if (line[k] ~ pat)
					return k
			return 0
		}
		{ line[NR] = $0 }
		END {
			nlines = NR
			for (k = 1; k <= nlines; k++) {
				if (line[k] ~ /^[A-Za-z_][A-Za-z0-9_][A-Za-z0-9_ *]*[ *][A-Za-z_][A-Za-z0-9_]*\(/ && line[k] !~ /;[[:space:]]*$/) {
					cur = funcname(line[k])
					last = k
					while (last <= nlines && line[last] !~ /^}/)
						last++
				}
				fname[k] = cur
			}

			if (n == 1 || n == 2) {
				if (n == 1) {
					f = "smb5_handle_usb_plugin"
					pat = "smb5_write_icl\\(chip, SDP_CURRENT_UA\\);"
				} else {
					f = "smb5_status_change_work"
					pat = "smb5_set_bc12\\(chip, !pick.want_bc12_off\\);"
				}
				base = where(f)
				if (!base) exit 1
				call = findline(base, pat)
				if (!call) exit 1
				unlock = findline(call, "^[[:space:]]*mutex_unlock\\(&chip->lock\\);")
				if (!unlock) exit 1
				keep = line[call]
				for (k = call; k < nlines; k++)
					line[k] = line[k + 1]
				nlines--
				unlock--
				for (k = nlines + 1; k > unlock + 1; k--)
					line[k] = line[k - 1]
				line[unlock + 1] = keep
				nlines++
			} else if (n == 3) {
				base = where("smb5_write_icl")
				if (!base) exit 1
				k = findline(base, "^[[:space:]]*lockdep_assert_held\\(&chip->lock\\);")
				if (!k || fname[k] != "smb5_write_icl") exit 1
				for (j = k; j < nlines; j++)
					line[j] = line[j + 1]
				nlines--
			} else if (n == 4) {
				base = where("smb5_status_change_work")
				if (!base) exit 1
				k = findline(base, "^[[:space:]]*mutex_lock\\(&chip->lock\\);")
				if (!k || fname[k] != "smb5_status_change_work") exit 1
				for (j = nlines + 1; j > k + 1; j--)
					line[j] = line[j - 1]
				line[k + 1] = "\tregmap_read(chip->regmap, 0, &v);"
				nlines++
			} else if (n == 5) {
				base = where("smb5_status_change_work")
				if (!base) exit 1
				k = findline(base, "gen != chip->plug_gen")
				if (!k || fname[k] != "smb5_status_change_work") exit 1
				for (j = k; j < nlines; j++)
					line[j] = line[j + 1]
				nlines--
			} else if (n == 6) {
				base = where("smb5_status_change_work")
				if (!base) exit 1
				k = findline(base, "^[[:space:]]*rmb\\(\\);[[:space:]]*$")
				if (!k || fname[k] != "smb5_status_change_work") exit 1
				for (j = k; j < nlines; j++)
					line[j] = line[j + 1]
				nlines--
			} else if (n == 7) {
				base = where("smb5_handle_usb_plugin")
				if (!base) exit 1
				k = findline(base, "^[[:space:]]*mutex_lock\\(&chip->lock\\);")
				if (!k || fname[k] != "smb5_handle_usb_plugin") exit 1
				u = findline(k, "^[[:space:]]*mutex_unlock\\(&chip->lock\\);")
				if (!u || fname[u] != "smb5_handle_usb_plugin") exit 1
				line[k] = "\tguard(mutex)(&chip->lock);"
				for (j = u; j < nlines; j++)
					line[j] = line[j + 1]
				nlines--
			} else {
				exit 1
			}

			for (k = 1; k <= nlines; k++)
				print line[k]
		}
	' "$1" > "$3" || return 1

	cmp -s "$1" "$3" && return 1
	return 0
}

check_mutations() {
	local dir n

	dir=$(mktemp -d)

	for n in 1 2 3 4 5 6 7; do
		mutate "$c" "$n" "$dir/m.c" || fail "mutation $n did not apply"
		if ( src_checks "$dir/m.c" ) >/dev/null 2>&1; then
			rm -rf "$dir"
			fail "mutation $n passed the checks"
		fi
		echo "smb5-pd: mutation $n caught" >&2
	done

	rm -rf "$dir"
}

check_dtb
src_checks "$c"
check_mutations
echo "smb5-pd: charger ok"
