#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
hooks=$tree/usr/lib/systemd/system-sleep
tmp=$(mktemp -d)
trap 'rm -rf "${tmp:?}"' EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

r=$tmp/root
export MICROOS_SLEEP_ROOT=$r MICROOS_RUNDIR=$tmp/run MICROOS_STATEDIR=$tmp/state PATH=$tmp/bin:$PATH
export MICROOS_IRQ_LIB=$tree/usr/libexec/microos/microos-irq
mkdir -p "$tmp/bin" "$r/proc" "$r/sys/power" "$r/sys/class/power_supply/battmgr" "$r/sys/class/power_supply/usb"
cat > "$tmp/bin/modprobe" <<'MOD'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MICROOS_STATEDIR.modprobe"
[[ -z ${MODPROBE_HANG:-} ]] || exec sleep 10
mkdir -p "$MICROOS_SLEEP_ROOT/sys/kernel/debug/qcom_stats"
MOD
chmod +x "$tmp/bin/modprobe"
cat > "$r/proc/interrupts" <<'IRQ'
           CPU0       CPU1
 167:          4          0  GICv3 627 Level     qcom_geni_serial_uart
 251:          5          1  pmic_arb 101318657 Edge      pm8xxx_rtc_alarm
IPI0:        10         12       Rescheduling interrupts
IRQ
echo Battery > "$r/sys/class/power_supply/battmgr/type"
echo USB > "$r/sys/class/power_supply/usb/type"
echo 999 > "$r/sys/class/power_supply/usb/charge_counter"
stats() {
  local f n=$1
  for f in cxsd aosd ddr; do
    printf 'Count: %s\nLast Entered At: 0\nLast Exited At: 0\nAccumulated Duration: %s\n' "$n" "$(( n * 1000 ))" \
      > "$r/sys/kernel/debug/qcom_stats/$f"
    n=$(( n + 1 ))
  done
}

wr() { "$hooks/microos-wake-reason" "$@"; }
[[ -z $(wr pre suspend) ]] || fail "wake reason printed on pre"
[[ $(wr post suspend) == 'microos-wake-reason: no wakeup irq' ]] || fail "no irq: $(wr post suspend)"
echo 251 > "$r/sys/power/pm_wakeup_irq"
[[ $(wr post suspend) == 'microos-wake-reason: irq 251 pmic_arb 101318657 Edge pm8xxx_rtc_alarm' ]] || fail "rtc irq: $(wr post suspend)"
echo 9 > "$r/sys/power/pm_wakeup_irq"
[[ $(wr post suspend) == 'microos-wake-reason: irq 9 unknown' ]] || fail "unknown irq: $(wr post suspend)"

sl() { "$hooks/microos-sleep-log" "$@"; }
echo '100.50 300.00' > "$r/proc/uptime"
echo 4000000 > "$r/sys/class/power_supply/battmgr/charge_counter"
sl pre suspend || fail "pre exit $?"
[[ $(cat "$MICROOS_STATEDIR.modprobe" 2> /dev/null) == '-q qcom_stats' ]] || fail "qcom_stats not loaded"
[[ $(< "$tmp/run/sleep-pre") == '100.50 4000000 - - - - - -' ]] || fail "pre without stats: $(< "$tmp/run/sleep-pre")"
stats 2
echo 167 > "$r/sys/power/pm_wakeup_irq"
echo '160.25 300.10' > "$r/proc/uptime"
echo 3990000 > "$r/sys/class/power_supply/battmgr/charge_counter"
sl post suspend || fail "post exit $?"
[[ ! -e $tmp/run/sleep-pre ]] || fail "sleep-pre left after post"
head=$'in\tout\tcharge_in\tcharge_out\tcxsd\tcxsd_time\taosd\taosd_time\tddr\tddr_time\twake_irq\twake_name'
row1=$'100.50\t160.25\t4000000\t3990000\t-\t-\t-\t-\t-\t-\t167\tGICv3 627 Level qcom_geni_serial_uart'
[[ $(< "$tmp/state/sleep.tsv") == "$head"$'\n'"$row1" ]] || fail "first row: $(cat -A "$tmp/state/sleep.tsv")"

rm -f "$MICROOS_STATEDIR.modprobe"
sl pre suspend
[[ ! -e $MICROOS_STATEDIR.modprobe ]] || fail "qcom_stats loaded again"
stats 7
echo 251 > "$r/sys/power/pm_wakeup_irq"
echo '190.00 300.20' > "$r/proc/uptime"
rm -f "$r/sys/class/power_supply/battmgr/charge_counter"
sl post suspend
row2=$'160.25\t190.00\t3990000\t-\t5\t5000\t5\t5000\t5\t5000\t251\tpmic_arb 101318657 Edge pm8xxx_rtc_alarm'
[[ $(< "$tmp/state/sleep.tsv") == "$head"$'\n'"$row1"$'\n'"$row2" ]] || fail "second row: $(tail -1 "$tmp/state/sleep.tsv" | cat -A)"

sl post suspend
[[ $(grep -c . "$tmp/state/sleep.tsv") == 3 ]] || fail "post without pre wrote a row"
rm -f "$r/sys/power/pm_wakeup_irq"
sl pre suspend
sl post suspend
[[ $(tail -1 "$tmp/state/sleep.tsv" | cut -f11,12) == $'-\t-' ]] || fail "row without a wake irq: $(tail -1 "$tmp/state/sleep.tsv")"

: > "$tmp/run/sleep-pre"
sl post suspend || fail "post after an empty pre: exit $?"
[[ $(tail -1 "$tmp/state/sleep.tsv" | cut -f1,3,5) == $'-\t-\t-' ]] || fail "row after an empty pre: $(tail -1 "$tmp/state/sleep.tsv")"
echo '150.00' > "$tmp/run/sleep-pre"
sl post suspend || fail "post after a short pre: exit $?"
[[ $(tail -1 "$tmp/state/sleep.tsv" | cut -f1-3) == $'150.00\t190.00\t-' ]] || fail "row after a short pre: $(tail -1 "$tmp/state/sleep.tsv")"

rm -rf "${r:?}/sys/kernel/debug"
rm -f "$MICROOS_STATEDIR.modprobe"
t0=$SECONDS
MODPROBE_HANG=1 sl pre suspend || fail "pre with a hanging modprobe: exit $?"
(( SECONDS - t0 <= 4 )) || fail "pre waited $(( SECONDS - t0 )) s for modprobe"
[[ -s $tmp/run/sleep-pre ]] || fail "no pre snapshot after a hanging modprobe"

{ head -n 1 "$tmp/state/sleep.tsv"; for ((i = 0; i < 20000; i++)); do printf 'old%d\n' "$i"; done; } > "$tmp/big"
mv "$tmp/big" "$tmp/state/sleep.tsv"
sl post suspend
[[ $(wc -l < "$tmp/state/sleep.tsv") == 10001 && $(head -1 "$tmp/state/sleep.tsv") == "$head" ]] || fail "cap: $(wc -l < "$tmp/state/sleep.tsv") lines"
[[ $(sed -n 2p "$tmp/state/sleep.tsv") == old10001 && $(tail -1 "$tmp/state/sleep.tsv") == $'190.00\t'* ]] \
  || fail "cap kept the wrong rows: $(sed -n 2p "$tmp/state/sleep.tsv") / $(tail -1 "$tmp/state/sleep.tsv")"
[[ ! -e $tmp/state/sleep.tsv.tmp ]] || fail "cap left sleep.tsv.tmp"

if (( rc == 0 )); then
  echo "sleep-hooks: ok"
fi
exit "$rc"
