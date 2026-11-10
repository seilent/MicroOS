#ifndef SMB5_STUB_H
#define SMB5_STUB_H

#include <stdio.h>
#include <stdbool.h>
#include <stdint.h>

#define min(a, b)	((a) < (b) ? (a) : (b))

static inline unsigned long msecs_to_jiffies(unsigned int m)
{
	return ((unsigned long)m * HZ + 999) / 1000;
}

static inline unsigned int jiffies_to_msecs(unsigned long j)
{
	return (unsigned int)((j * 1000) / HZ);
}

#define time_after(a, b)	((long)((b) - (a)) < 0)
#define time_before(a, b)	time_after(b, a)
#define time_after_eq(a, b)	((long)((a) - (b)) >= 0)
#define time_before_eq(a, b)	time_after_eq(b, a)

enum power_supply_usb_type {
	POWER_SUPPLY_USB_TYPE_UNKNOWN = 0,
	POWER_SUPPLY_USB_TYPE_SDP,
	POWER_SUPPLY_USB_TYPE_DCP,
	POWER_SUPPLY_USB_TYPE_CDP,
	POWER_SUPPLY_USB_TYPE_ACA,
	POWER_SUPPLY_USB_TYPE_C,
	POWER_SUPPLY_USB_TYPE_PD,
	POWER_SUPPLY_USB_TYPE_PD_DRP,
	POWER_SUPPLY_USB_TYPE_PD_PPS,
	POWER_SUPPLY_USB_TYPE_PD_SPR_AVS,
	POWER_SUPPLY_USB_TYPE_PD_PPS_SPR_AVS,
	POWER_SUPPLY_USB_TYPE_APPLE_BRICK_ID,
};

#endif
