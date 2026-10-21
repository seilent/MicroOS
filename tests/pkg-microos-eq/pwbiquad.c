#include <math.h>
#define float double
#include "biquad.c"
#undef float

static const enum biquad_type types[] = {
	BQ_PEAKING, BQ_LOWSHELF, BQ_HIGHSHELF, BQ_BANDPASS, BQ_LOWPASS, BQ_HIGHPASS, BQ_ALLPASS,
};

void pw_design(int type, double freq, double gain, double q, double rate, double c[5])
{
	struct biquad bq;
	biquad_set(&bq, types[type], freq * 2 / rate, q, gain);
	c[0] = bq.b0;
	c[1] = bq.b1;
	c[2] = bq.b2;
	c[3] = bq.a1;
	c[4] = bq.a2;
}
