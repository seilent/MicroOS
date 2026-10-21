#include <ladspa.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#define EXPORT __attribute__((visibility("default")))

enum { IN_L, IN_R, OUT_L, OUT_R, ON, FC, LEVEL, PORTS };
enum { CONTROLS = 3 };

#ifdef MICROOS_EQ_TEST
extern void (*microos_eq_test_mid)(void *);
extern void *microos_eq_test_arg;
#endif

struct xfeed {
	double rate;
	LADSPA_Data *port[PORTS];
	long n, k;
	int have, on, change;
	float applied[CONTROLS], wanted[CONTROLS], prev[CONTROLS];
	double lo_b0, lo_a1, hi_b0, hi_b1, hi_a1;
	double lo[2], hi[2], in[2];
#ifdef MICROOS_EQ_TEST
	unsigned long resets;
	long reset_k;
#endif
};

EXPORT void microos_eq_xfeed_design(double fc, double level, double rate, double lo[5], double hi[5])
{
	double gb_lo = level * -5.0 / 6.0 - 3.0, gb_hi = level / 6.0 - 3.0;
	double g_lo = pow(10, gb_lo / 20.0);
	double g_hi = 1.0 - pow(10, gb_hi / 20.0);
	double fc_hi = fc * pow(2.0, (gb_lo - 20.0 * log10(g_hi)) / 12.0);
	double gain = 1.0 / (1.0 - g_hi + g_lo);
	double xl = exp(-2 * M_PI * fc / rate), xh = exp(-2 * M_PI * fc_hi / rate);
	lo[0] = gain * g_lo * (1 - xl);
	lo[1] = lo[2] = lo[4] = 0;
	lo[3] = -xl;
	hi[0] = gain * (1 - g_hi * (1 - xh));
	hi[1] = (1.0 - lo[0] / (1 - xl)) * (1 - xh) - hi[0];
	hi[2] = hi[4] = 0;
	hi[3] = -xh;
}

static double clampd(double v, double lo, double hi)
{
	if (!(v >= lo))
		return lo;
	return v > hi ? hi : v;
}

static void snapshot(const struct xfeed *x, float *v)
{
	for (int i = 0; i < CONTROLS; i++)
		v[i] = *x->port[ON + i];
}

static int same(const float *a, const float *b)
{
	return !memcmp(a, b, CONTROLS * sizeof(float));
}

static void reset(struct xfeed *x)
{
	x->lo[0] = x->lo[1] = x->hi[0] = x->hi[1] = x->in[0] = x->in[1] = 0;
}

static void apply(struct xfeed *x, const float *v)
{
	double lo[5], hi[5];
	memcpy(x->applied, v, sizeof(x->applied));
	memcpy(x->wanted, v, sizeof(x->wanted));
	x->change = 0;
	x->on = v[0] > 0;
	microos_eq_xfeed_design(clampd(v[1], 300, 2000), clampd(v[2], 1, 15), x->rate, lo, hi);
	x->lo_b0 = lo[0];
	x->lo_a1 = lo[3];
	x->hi_b0 = hi[0];
	x->hi_b1 = hi[1];
	x->hi_a1 = hi[3];
	reset(x);
}

static void process(struct xfeed *x, unsigned long n)
{
	const float *il = x->port[IN_L], *ir = x->port[IN_R];
	float *ol = x->port[OUT_L], *orr = x->port[OUT_R];
	for (unsigned long i = 0; i < n; i++) {
		if (x->change && x->k == 0) {
#ifdef MICROOS_EQ_TEST
			x->resets++;
			x->reset_k = x->k;
#endif
			apply(x, x->wanted);
		}
		float l = il[i], r = ir[i];
		if (!x->on && x->k == 0) {
			ol[i] = l;
			orr[i] = r;
		} else {
			double lo_l = x->lo_b0 * l - x->lo_a1 * x->lo[0];
			double lo_r = x->lo_b0 * r - x->lo_a1 * x->lo[1];
			double hi_l = x->hi_b0 * l + x->hi_b1 * x->in[0] - x->hi_a1 * x->hi[0];
			double hi_r = x->hi_b0 * r + x->hi_b1 * x->in[1] - x->hi_a1 * x->hi[1];
			x->lo[0] = lo_l;
			x->lo[1] = lo_r;
			x->hi[0] = hi_l;
			x->hi[1] = hi_r;
			x->in[0] = l;
			x->in[1] = r;
			double s = (double)x->k / x->n;
			ol[i] = (float)((1 - s) * l + s * (hi_l + lo_r));
			orr[i] = (float)((1 - s) * r + s * (hi_r + lo_l));
		}
		if (!x->change && x->on) {
			if (x->k < x->n)
				x->k++;
		} else if (x->k > 0) {
			x->k--;
		}
	}
}

static void flush(struct xfeed *x)
{
	double *v[] = { &x->lo[0], &x->lo[1], &x->hi[0], &x->hi[1], &x->in[0], &x->in[1] };
	for (int i = 0; i < 6; i++)
		if (!isnormal(*v[i]))
			*v[i] = 0;
}

static void fresh(struct xfeed *x, const float *top, unsigned long n)
{
	float end[CONTROLS];
	apply(x, top);
	x->k = x->on ? x->n : 0;
	process(x, n);
#ifdef MICROOS_EQ_TEST
	if (microos_eq_test_mid)
		microos_eq_test_mid(microos_eq_test_arg);
#endif
	snapshot(x, end);
	memcpy(x->prev, end, sizeof(x->prev));
	if (same(top, end)) {
		x->have = 1;
	} else {
		memset(x->port[OUT_L], 0, n * sizeof(float));
		memset(x->port[OUT_R], 0, n * sizeof(float));
		reset(x);
	}
}

static void run(LADSPA_Handle h, unsigned long n)
{
	struct xfeed *x = h;
	float top[CONTROLS];
	snapshot(x, top);
	if (!x->have) {
		fresh(x, top, n);
	} else {
		int confirmed = same(top, x->prev);
		memcpy(x->prev, top, sizeof(x->prev));
		if (confirmed) {
			memcpy(x->wanted, top, sizeof(x->wanted));
			x->change = !same(x->wanted, x->applied);
		}
		process(x, n);
	}
	flush(x);
}

static LADSPA_Handle instantiate(const LADSPA_Descriptor *d, unsigned long rate)
{
	(void)d;
	struct xfeed *x = calloc(1, sizeof(*x));
	if (!x)
		return NULL;
	x->rate = (double)rate;
	x->n = lround(0.050 * x->rate);
	if (x->n < 1)
		x->n = 1;
	return x;
}

static void connect_port(LADSPA_Handle h, unsigned long p, LADSPA_Data *data)
{
	if (p < PORTS)
		((struct xfeed *)h)->port[p] = data;
}

static void activate(LADSPA_Handle h)
{
	struct xfeed *x = h;
	if (x->have) {
		apply(x, x->wanted);
		x->k = x->on ? x->n : 0;
	}
	reset(x);
}

static void cleanup(LADSPA_Handle h)
{
	free(h);
}

#ifdef MICROOS_EQ_TEST
EXPORT double microos_eq_test_share(LADSPA_Handle h)
{
	struct xfeed *x = h;
	return (double)x->k / x->n;
}

EXPORT unsigned long microos_eq_test_resets(LADSPA_Handle h)
{
	return ((struct xfeed *)h)->resets;
}

EXPORT long microos_eq_test_reset_share(LADSPA_Handle h)
{
	return ((struct xfeed *)h)->reset_k;
}
#endif

#define CONTROL LADSPA_PORT_INPUT | LADSPA_PORT_CONTROL
#define BOUNDED LADSPA_HINT_BOUNDED_BELOW | LADSPA_HINT_BOUNDED_ABOVE

static const LADSPA_PortDescriptor ports[PORTS] = {
	LADSPA_PORT_INPUT | LADSPA_PORT_AUDIO,
	LADSPA_PORT_INPUT | LADSPA_PORT_AUDIO,
	LADSPA_PORT_OUTPUT | LADSPA_PORT_AUDIO,
	LADSPA_PORT_OUTPUT | LADSPA_PORT_AUDIO,
	CONTROL,
	CONTROL,
	CONTROL,
};

static const char *const names[PORTS] = { "InL", "InR", "OutL", "OutR", "On", "Fc", "Level" };

static const LADSPA_PortRangeHint hints[PORTS] = {
	{ 0, 0, 0 },
	{ 0, 0, 0 },
	{ 0, 0, 0 },
	{ 0, 0, 0 },
	{ LADSPA_HINT_TOGGLED | LADSPA_HINT_DEFAULT_0, 0, 0 },
	{ BOUNDED | LADSPA_HINT_DEFAULT_LOW, 300, 2000 },
	{ BOUNDED | LADSPA_HINT_DEFAULT_LOW, 1, 15 },
};

static const LADSPA_Descriptor crossfeed_descriptor = {
	.UniqueID = 6331,
	.Label = "crossfeed",
	.Properties = LADSPA_PROPERTY_HARD_RT_CAPABLE,
	.Name = "MicroOS crossfeed",
	.Maker = "MicroOS",
	.Copyright = "GPL-2.0-or-later",
	.PortCount = PORTS,
	.PortDescriptors = ports,
	.PortNames = names,
	.PortRangeHints = hints,
	.instantiate = instantiate,
	.connect_port = connect_port,
	.activate = activate,
	.run = run,
	.cleanup = cleanup,
};

const LADSPA_Descriptor *microos_eq_crossfeed(void)
{
	return &crossfeed_descriptor;
}
