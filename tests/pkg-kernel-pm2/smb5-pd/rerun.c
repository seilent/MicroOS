#include <stdio.h>
#include <limits.h>

#include "smb5_stub.h"
#include "rerun_gen.inc"

static int failures;

static void step(int line, unsigned long now, unsigned int count,
		 unsigned long next, unsigned long t0, bool rerun,
		 unsigned int want_count, unsigned long want_requeue,
		 bool want_fallback)
{
	struct smb5_rerun s = smb5_rerun_step(now, count, next);

	if (s.rerun != rerun || s.count != want_count ||
	    s.requeue != want_requeue || s.fallback != want_fallback) {
		printf("line %d at %u ms: got rerun %d count %u requeue %lu fallback %d, want rerun %d count %u requeue %lu fallback %d\n",
		       line, jiffies_to_msecs(now - t0), s.rerun, s.count,
		       s.requeue, s.fallback, rerun, want_count, want_requeue,
		       want_fallback);
		failures++;
	}
}

static unsigned long at(unsigned long t0, unsigned int ms)
{
	return t0 + msecs_to_jiffies(ms);
}

static void schedule(unsigned long t0)
{
	unsigned int ms[5] = { 1500, 2500, 4500, 8500, 16500 };
	unsigned long now = at(t0, 1500);
	unsigned long next = at(t0, 1500);
	unsigned int count = 0;
	struct smb5_rerun s;
	int i;

	for (i = 0; i < 5; i++) {
		s = smb5_rerun_step(now, count, next);
		if (now - t0 != msecs_to_jiffies(ms[i])) {
			printf("schedule: run %d at %u ms, want %u ms\n", i,
			       jiffies_to_msecs(now - t0), ms[i]);
			failures++;
		}
		if (i < 4) {
			if (!s.rerun || s.count != i + 1 || s.fallback ||
			    !s.requeue) {
				printf("schedule: run %d rerun %d count %u requeue %lu fallback %d\n",
				       i, s.rerun, s.count, s.requeue,
				       s.fallback);
				failures++;
			}
			count = s.count;
			next = s.next;
			now += s.requeue;
			continue;
		}
		if (s.rerun || !s.fallback || s.requeue || s.count != APSD_RERUNS) {
			printf("schedule: fallback rerun %d count %u requeue %lu fallback %d\n",
			       s.rerun, s.count, s.requeue, s.fallback);
			failures++;
		}
		step(__LINE__, at(now, 60000), s.count, s.next, t0, false,
		     APSD_RERUNS, 0, true);
	}
}

int main(void)
{
	unsigned long t0 = 1000000;
	unsigned long next = at(t0, 4500);

	schedule(t0);
	schedule(ULONG_MAX - HZ);

	step(__LINE__, at(t0, 200), 0, at(t0, 1500), t0, false, 0,
	     msecs_to_jiffies(1300), false);
	step(__LINE__, at(t0, 3000), 2, next, t0, false, 2,
	     msecs_to_jiffies(1500), false);
	step(__LINE__, at(t0, 1500), 0, at(t0, 1500), t0, true, 1, HZ, false);
	step(__LINE__, at(t0, 4500), 0, at(t0, 4500), t0, true, 1, HZ, false);
	step(__LINE__, at(t0, 7500), 0, at(t0, 4500), t0, true, 1, HZ, false);
	step(__LINE__, at(t0, 3500), 4, at(t0, 3000), t0, false, 4, 0, true);
	step(__LINE__, at(t0, 9000), 4, at(t0, 3000), t0, false, 4, 0, true);

	if (failures)
		return 1;

	printf("rerun HZ %d ok\n", HZ);
	return 0;
}
