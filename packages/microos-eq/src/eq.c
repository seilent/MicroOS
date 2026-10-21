#include <ladspa.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#define EXPORT __attribute__((visibility("default")))

enum { BANDS = 10, CONTROLS = 2 + 4 * BANDS, PORTS = 2 + CONTROLS };
enum { IN, OUT, PREAMP };
enum { PEAK, LOWSHELF, HIGHSHELF, BANDPASS, LOWPASS, HIGHPASS, ALLPASS, MATCHEDPEAK, TYPES };

void microos_eq_rbj(int type, double freq, double gain, double q, double rate, double c[5]);

#ifdef MICROOS_EQ_TEST
EXPORT void (*microos_eq_test_mid)(void *);
EXPORT void *microos_eq_test_arg;
EXPORT int microos_eq_test_r_on;
EXPORT double microos_eq_test_r;
#endif

struct section {
	double b0, b1, b2, a1, a2;
	double x1, x2, y1, y2;
};

struct chain {
	double gain;
	int n;
	struct section s[BANDS];
};

struct eq {
	double rate;
	LADSPA_Data *port[PORTS];
	struct chain chain[2];
	int cur, have, swapping, queued;
	long warm, fade, pos;
	float applied[CONTROLS], target[CONTROLS], pending[CONTROLS], prev[CONTROLS];
#ifdef MICROOS_EQ_TEST
	int chains;
	unsigned long sections, swaps;
#endif
};

static int matched_peak(double freq, double gain, double q, double rate, double c[5])
{
	if (gain == 0 || freq >= 0.49 * rate || q <= 0)
		return 0;
	double A = pow(10.0, gain / 40.0);
	double w0 = 2 * M_PI * freq / rate;
	double g = A * A, z = 1 / (2 * q * A);
	double r = z <= 1 ? cos(sqrt(1 - z * z) * w0) : cosh(sqrt(z * z - 1) * w0);
	double a1 = -2 * exp(-z * w0) * r;
	double a2 = exp(-2 * z * w0);
	double A0 = (1 + a1 + a2) * (1 + a1 + a2), A1 = (1 - a1 + a2) * (1 - a1 + a2), A2 = -4 * a2;
	double p1 = sin(w0 / 2) * sin(w0 / 2), p0 = 1 - p1, p2 = 4 * p0 * p1;
	double R1 = (A0 * p0 + A1 * p1 + A2 * p2) * g * g, R2 = (-A0 + A1 + 4 * (p0 - p1) * A2) * g * g;
	double B0 = A0, B2 = (R1 - R2 * p1 - B0) / (4 * p1 * p1), B1 = R2 + B0 + 4 * (p1 - p0) * B2;
	double W = (sqrt(B0) + sqrt(fmax(B1, 0.0))) / 2;
	if (B1 < 0 || W * W + B2 < 0)
		return 0;
	double b0 = (W + sqrt(W * W + B2)) / 2;
	c[0] = b0;
	c[1] = (sqrt(B0) - sqrt(B1)) / 2;
	c[2] = -B2 / (4 * b0);
	c[3] = a1;
	c[4] = a2;
	return 1;
}

EXPORT int microos_eq_design(int type, double freq, double gain, double q, double rate, double c[5])
{
	c[0] = 1;
	c[1] = c[2] = c[3] = c[4] = 0;
	if (type == MATCHEDPEAK)
		return matched_peak(freq, gain, q, rate, c);
	if (type < 0 || type >= MATCHEDPEAK || ((type == PEAK || type == LOWSHELF || type == HIGHSHELF) && gain == 0))
		return 0;
	microos_eq_rbj(type, freq, gain, q, rate, c);
	return 1;
}

static double clampd(double v, double lo, double hi)
{
	if (!(v >= lo))
		return lo;
	return v > hi ? hi : v;
}

static void build(struct chain *ch, const float *v, double rate)
{
	int count = (int)lrint(clampd(v[1], 0, BANDS));
	ch->gain = pow(10.0, clampd(v[0], -24, 0) / 20.0);
	ch->n = 0;
	for (int i = 0; i < count; i++) {
		const float *b = v + 2 + 4 * i;
		double c[5];
		if (!microos_eq_design((int)lrint(clampd(b[0], 0, TYPES - 1)), clampd(b[1], 20, 20000),
				       clampd(b[2], -24, 12), clampd(b[3], 0.1, 10), rate, c))
			continue;
		ch->s[ch->n++] = (struct section){ c[0], c[1], c[2], c[3], c[4], 0, 0, 0, 0 };
	}
#ifdef MICROOS_EQ_V0
	while (ch->n < BANDS)
		ch->s[ch->n++] = (struct section){ 1, 0, 0, 0, 0, 0, 0, 0, 0 };
#endif
}

static void zero(struct chain *ch)
{
	for (int i = 0; i < BANDS; i++)
		ch->s[i].x1 = ch->s[i].x2 = ch->s[i].y1 = ch->s[i].y2 = 0;
}

static double radius(double a1, double a2)
{
	double disc = a1 * a1 - 4 * a2;
	return disc < 0 ? sqrt(a2) : (fabs(a1) + sqrt(disc)) / 2;
}

static long warm(const struct chain *ch, double rate)
{
	double tau = 0;
	for (int i = 0; i < ch->n; i++) {
		double r = radius(ch->s[i].a1, ch->s[i].a2), t;
#ifdef MICROOS_EQ_TEST
		if (i == 0 && microos_eq_test_r_on)
			r = microos_eq_test_r;
#endif
		if (r <= 0)
			t = 0;
		else if (!(r < 1))
			t = INFINITY;
		else
			t = -1 / (rate * log(r));
		if (!(t <= tau))
			tau = t;
	}
	double w = 4 * tau;
	if (!(w < 1.0))
		w = 1.0;
	if (w < 0.020)
		w = 0.020;
	return lround(rate * w);
}

static inline double step(struct chain *ch, float x)
{
	double v = ch->gain * x;
	for (int i = 0; i < ch->n; i++) {
		struct section *s = &ch->s[i];
		double y = s->b0 * v + s->b1 * s->x1 + s->b2 * s->x2 - s->a1 * s->y1 - s->a2 * s->y2;
		s->x2 = s->x1;
		s->x1 = v;
		s->y2 = s->y1;
		s->y1 = y;
		v = y;
	}
	return v;
}

static void flush(struct eq *e)
{
	for (int c = 0; c < 2; c++)
		for (int i = 0; i < BANDS; i++) {
			struct section *s = &e->chain[c].s[i];
			if (!isnormal(s->x1))
				s->x1 = 0;
			if (!isnormal(s->x2))
				s->x2 = 0;
			if (!isnormal(s->y1))
				s->y1 = 0;
			if (!isnormal(s->y2))
				s->y2 = 0;
		}
}

static void snapshot(const struct eq *e, float *v)
{
	for (int i = 0; i < CONTROLS; i++)
		v[i] = *e->port[PREAMP + i];
}

static int same(const float *a, const float *b)
{
	return !memcmp(a, b, CONTROLS * sizeof(float));
}

static void start(struct eq *e, const float *v)
{
	struct chain *next = &e->chain[!e->cur];
	build(next, v, e->rate);
	memcpy(e->target, v, sizeof(e->target));
	e->warm = warm(next, e->rate);
	e->pos = 0;
	e->swapping = 1;
#ifdef MICROOS_EQ_TEST
	e->swaps++;
#endif
}

#if defined(MICROOS_EQ_V0) || defined(MICROOS_EQ_V1)
static void instant(struct eq *e, const float *v)
{
	struct chain *c = &e->chain[e->cur], *t = &e->chain[!e->cur];
	build(t, v, e->rate);
	c->gain = t->gain;
	for (int i = 0; i < t->n; i++) {
		struct section *s = &c->s[i];
#ifdef MICROOS_EQ_V0
		double x1 = i < c->n ? s->x1 : 0, x2 = i < c->n ? s->x2 : 0, y1 = i < c->n ? s->y1 : 0,
		       y2 = i < c->n ? s->y2 : 0;
#else
		double x1 = 0, x2 = 0, y1 = 0, y2 = 0;
#endif
		*s = t->s[i];
		s->x1 = x1;
		s->x2 = x2;
		s->y1 = y1;
		s->y2 = y2;
	}
	c->n = t->n;
	memcpy(e->applied, v, sizeof(e->applied));
}
#endif

static void offer(struct eq *e, const float *v)
{
	if (e->swapping) {
		e->queued = !same(v, e->target);
		if (e->queued)
			memcpy(e->pending, v, sizeof(e->pending));
	} else if (!same(v, e->applied)) {
#if defined(MICROOS_EQ_V0) || defined(MICROOS_EQ_V1)
		instant(e, v);
#else
		start(e, v);
#endif
	}
}

static void finish(struct eq *e)
{
	e->cur = !e->cur;
	memcpy(e->applied, e->target, sizeof(e->applied));
	e->swapping = 0;
	if (e->queued) {
		e->queued = 0;
		if (!same(e->pending, e->applied))
			start(e, e->pending);
	}
}

static void process(struct eq *e, const float *in, float *out, unsigned long n)
{
	unsigned long i = 0;
	while (i < n) {
		struct chain *c = &e->chain[e->cur];
		if (!e->swapping) {
			for (; i < n; i++) {
				out[i] = (float)step(c, in[i]);
#ifdef MICROOS_EQ_TEST
				e->sections += c->n;
#endif
			}
			break;
		}
		struct chain *t = &e->chain[!e->cur];
		long end = e->warm + e->fade;
#ifdef MICROOS_EQ_TEST
		if (1 + e->swapping > e->chains)
			e->chains = 1 + e->swapping;
#endif
		for (; i < n && e->pos < end; i++, e->pos++) {
			float x = in[i];
			double yc = step(c, x), yt = step(t, x);
#ifdef MICROOS_EQ_TEST
			e->sections += c->n + t->n;
#endif
			if (e->pos < e->warm) {
				out[i] = (float)yc;
			} else {
				double a = (double)(e->pos - e->warm) / e->fade;
				out[i] = (float)((1 - a) * yc + a * yt);
			}
		}
		if (e->pos >= end)
			finish(e);
	}
}

static void fresh(struct eq *e, const float *top, unsigned long n)
{
	struct chain *c = &e->chain[e->cur];
	float end[CONTROLS];
	build(c, top, e->rate);
	process(e, e->port[IN], e->port[OUT], n);
#ifdef MICROOS_EQ_TEST
	if (microos_eq_test_mid)
		microos_eq_test_mid(microos_eq_test_arg);
#endif
	snapshot(e, end);
	memcpy(e->prev, end, sizeof(e->prev));
	if (same(top, end)) {
		memcpy(e->applied, top, sizeof(e->applied));
		e->have = 1;
	} else {
		memset(e->port[OUT], 0, n * sizeof(float));
		zero(c);
	}
}

static void run(LADSPA_Handle h, unsigned long n)
{
	struct eq *e = h;
	float top[CONTROLS];
	snapshot(e, top);
	if (!e->have) {
		fresh(e, top, n);
	} else {
#ifdef MICROOS_EQ_NOGATE
		int confirmed = 1;
#else
		int confirmed = same(top, e->prev);
#endif
		memcpy(e->prev, top, sizeof(e->prev));
		if (confirmed)
			offer(e, top);
		process(e, e->port[IN], e->port[OUT], n);
	}
	flush(e);
}

static LADSPA_Handle instantiate(const LADSPA_Descriptor *d, unsigned long rate)
{
	(void)d;
	struct eq *e = calloc(1, sizeof(*e));
	if (!e)
		return NULL;
	e->rate = (double)rate;
	e->fade = lround(0.050 * e->rate);
#ifdef MICROOS_EQ_TEST
	e->chains = 1;
#endif
	return e;
}

static void connect_port(LADSPA_Handle h, unsigned long p, LADSPA_Data *data)
{
	if (p < PORTS)
		((struct eq *)h)->port[p] = data;
}

static void activate(LADSPA_Handle h)
{
	struct eq *e = h;
	if (e->swapping) {
		e->cur = !e->cur;
		memcpy(e->applied, e->target, sizeof(e->applied));
		e->swapping = 0;
	}
	e->queued = 0;
	zero(&e->chain[0]);
	zero(&e->chain[1]);
}

static void cleanup(LADSPA_Handle h)
{
	free(h);
}

#ifdef MICROOS_EQ_TEST
EXPORT long microos_eq_test_warm(LADSPA_Handle h)
{
	return ((struct eq *)h)->warm;
}

EXPORT int microos_eq_test_chains(LADSPA_Handle h)
{
	return ((struct eq *)h)->chains;
}

EXPORT unsigned long microos_eq_test_sections(LADSPA_Handle h)
{
	return ((struct eq *)h)->sections;
}

EXPORT unsigned long microos_eq_test_swaps(LADSPA_Handle h)
{
	return ((struct eq *)h)->swaps;
}
#endif

#define CONTROL LADSPA_PORT_INPUT | LADSPA_PORT_CONTROL
#define BOUNDED LADSPA_HINT_BOUNDED_BELOW | LADSPA_HINT_BOUNDED_ABOVE
#define BAND_PORTS CONTROL, CONTROL, CONTROL, CONTROL
#define BAND_NAMES(n) "Type" #n, "Freq" #n, "Gain" #n, "Q" #n
#define BAND_HINTS                                                                    \
	{ BOUNDED | LADSPA_HINT_INTEGER | LADSPA_HINT_DEFAULT_0, 0, TYPES - 1 },       \
	{ BOUNDED | LADSPA_HINT_DEFAULT_440, 20, 20000 },                             \
	{ BOUNDED | LADSPA_HINT_DEFAULT_0, -24, 12 },                                 \
	{ BOUNDED | LADSPA_HINT_DEFAULT_1, 0.1f, 10 }

static const LADSPA_PortDescriptor ports[PORTS] = {
	LADSPA_PORT_INPUT | LADSPA_PORT_AUDIO,
	LADSPA_PORT_OUTPUT | LADSPA_PORT_AUDIO,
	CONTROL,
	CONTROL,
	BAND_PORTS, BAND_PORTS, BAND_PORTS, BAND_PORTS, BAND_PORTS,
	BAND_PORTS, BAND_PORTS, BAND_PORTS, BAND_PORTS, BAND_PORTS,
};

static const char *const names[PORTS] = {
	"In", "Out", "Preamp", "Count",
	BAND_NAMES(1), BAND_NAMES(2), BAND_NAMES(3), BAND_NAMES(4), BAND_NAMES(5),
	BAND_NAMES(6), BAND_NAMES(7), BAND_NAMES(8), BAND_NAMES(9), BAND_NAMES(10),
};

static const LADSPA_PortRangeHint hints[PORTS] = {
	{ 0, 0, 0 },
	{ 0, 0, 0 },
	{ BOUNDED | LADSPA_HINT_DEFAULT_0, -24, 0 },
	{ BOUNDED | LADSPA_HINT_INTEGER | LADSPA_HINT_DEFAULT_0, 0, BANDS },
	BAND_HINTS, BAND_HINTS, BAND_HINTS, BAND_HINTS, BAND_HINTS,
	BAND_HINTS, BAND_HINTS, BAND_HINTS, BAND_HINTS, BAND_HINTS,
};

static const LADSPA_Descriptor eq_descriptor = {
	.UniqueID = 6330,
	.Label = "eq",
	.Properties = LADSPA_PROPERTY_HARD_RT_CAPABLE,
	.Name = "MicroOS EQ",
	.Maker = "MicroOS",
	.Copyright = "GPL-2.0-or-later AND BSD-3-Clause",
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

EXPORT const LADSPA_Descriptor *ladspa_descriptor(unsigned long index)
{
	return index == 0 ? &eq_descriptor : NULL;
}
