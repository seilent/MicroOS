#include <stdio.h>
#include <stdbool.h>

#include "smb5_stub.h"
#include "pick_gen.inc"

static int failures;

static void check(int line, const struct smb5_port_state *st, unsigned int ua,
		  int type, bool want_bc12_off, bool rerun_allowed)
{
	struct smb5_pick p = smb5_pick(st);

	if (p.ua != ua || p.type != type || p.want_bc12_off != want_bc12_off ||
	    p.rerun_allowed != rerun_allowed) {
		printf("line %d: got ua %u type %d bc12 off %d rerun %d, want ua %u type %d bc12 off %d rerun %d\n",
		       line, p.ua, p.type, p.want_bc12_off, p.rerun_allowed, ua,
		       type, want_bc12_off, rerun_allowed);
		failures++;
	}
}

static struct smb5_port_state base(void)
{
	return (struct smb5_port_state) {
		.usbin = true,
		.apsd_done = true,
		.apsd_result = POWER_SUPPLY_USB_TYPE_SDP,
	};
}

int main(void)
{
	struct smb5_port_state st;

	st = base();
	st.otg = true;
	st.tcpm_online = true;
	st.tcpm_type = POWER_SUPPLY_USB_TYPE_PD;
	st.tcpm_ua = 3000000;
	st.bc12_off = true;
	check(__LINE__, &st, 500000, POWER_SUPPLY_USB_TYPE_UNKNOWN, true, false);

	st = base();
	st.usbin = false;
	st.tcpm_online = true;
	st.tcpm_type = POWER_SUPPLY_USB_TYPE_PD;
	st.tcpm_ua = 3000000;
	check(__LINE__, &st, 500000, POWER_SUPPLY_USB_TYPE_UNKNOWN, false, false);

	st = base();
	st.tcpm_online = true;
	st.tcpm_type = POWER_SUPPLY_USB_TYPE_PD;
	st.tcpm_ua = 3000000;
	check(__LINE__, &st, 3000000, POWER_SUPPLY_USB_TYPE_PD, true, false);

	st = base();
	st.tcpm_online = true;
	st.tcpm_type = POWER_SUPPLY_USB_TYPE_PD;
	st.tcpm_ua = 5000000;
	check(__LINE__, &st, 3000000, POWER_SUPPLY_USB_TYPE_PD, true, false);

	st = base();
	st.tcpm_online = true;
	st.tcpm_type = POWER_SUPPLY_USB_TYPE_PD_PPS;
	st.tcpm_ua = 3000000;
	check(__LINE__, &st, 3000000, POWER_SUPPLY_USB_TYPE_PD_PPS, true, false);

	st = base();
	st.tcpm_online = true;
	st.tcpm_type = POWER_SUPPLY_USB_TYPE_PD_SPR_AVS;
	st.tcpm_ua = 3000000;
	check(__LINE__, &st, 3000000, POWER_SUPPLY_USB_TYPE_PD_SPR_AVS, true,
	      false);

	st = base();
	st.tcpm_online = true;
	st.tcpm_type = POWER_SUPPLY_USB_TYPE_PD_PPS_SPR_AVS;
	st.tcpm_ua = 3000000;
	check(__LINE__, &st, 3000000, POWER_SUPPLY_USB_TYPE_PD_PPS_SPR_AVS, true,
	      false);

	st = base();
	st.tcpm_online = true;
	st.tcpm_type = POWER_SUPPLY_USB_TYPE_PD;
	st.tcpm_ua = 1500000;
	check(__LINE__, &st, 1500000, POWER_SUPPLY_USB_TYPE_PD, true, false);

	st = base();
	st.tcpm_online = true;
	st.tcpm_type = POWER_SUPPLY_USB_TYPE_C;
	st.tcpm_ua = 1500000;
	st.apsd_result = POWER_SUPPLY_USB_TYPE_DCP;
	check(__LINE__, &st, 1500000, POWER_SUPPLY_USB_TYPE_C, false, false);

	st = base();
	st.tcpm_online = true;
	st.tcpm_type = POWER_SUPPLY_USB_TYPE_C;
	st.tcpm_ua = 3000000;
	check(__LINE__, &st, 3000000, POWER_SUPPLY_USB_TYPE_C, false, false);

	st = base();
	st.tcpm_online = true;
	st.tcpm_type = POWER_SUPPLY_USB_TYPE_PD;
	st.tcpm_ua = 0;
	st.bc12_off = true;
	check(__LINE__, &st, 500000, POWER_SUPPLY_USB_TYPE_PD, true, false);

	st = base();
	st.tcpm_online = true;
	st.tcpm_type = POWER_SUPPLY_USB_TYPE_PD;
	st.tcpm_ua = 0;
	check(__LINE__, &st, 500000, POWER_SUPPLY_USB_TYPE_SDP, false, false);

	st = base();
	st.bc12_off = true;
	st.apsd_done = false;
	st.apsd_result = POWER_SUPPLY_USB_TYPE_UNKNOWN;
	check(__LINE__, &st, 500000, POWER_SUPPLY_USB_TYPE_UNKNOWN, true, false);

	st = base();
	st.tcpm_err = true;
	st.tcpm_type = POWER_SUPPLY_USB_TYPE_PD;
	st.tcpm_ua = 3000000;
	st.apsd_result = POWER_SUPPLY_USB_TYPE_DCP;
	check(__LINE__, &st, 3000000, POWER_SUPPLY_USB_TYPE_DCP, false, false);

	st = base();
	st.apsd_result = POWER_SUPPLY_USB_TYPE_CDP;
	check(__LINE__, &st, 1500000, POWER_SUPPLY_USB_TYPE_CDP, false, false);

	st = base();
	check(__LINE__, &st, 500000, POWER_SUPPLY_USB_TYPE_SDP, false, false);

	st = base();
	st.apsd_done = false;
	st.apsd_result = POWER_SUPPLY_USB_TYPE_UNKNOWN;
	check(__LINE__, &st, 500000, POWER_SUPPLY_USB_TYPE_UNKNOWN, false, true);

	st = base();
	st.tcpm_online = true;
	st.tcpm_type = POWER_SUPPLY_USB_TYPE_UNKNOWN;
	st.tcpm_ua = 0;
	st.apsd_done = false;
	st.apsd_result = POWER_SUPPLY_USB_TYPE_UNKNOWN;
	check(__LINE__, &st, 500000, POWER_SUPPLY_USB_TYPE_UNKNOWN, false, true);

	if (failures)
		return 1;

	printf("pick ok\n");
	return 0;
}
