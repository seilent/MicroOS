/* Copyright (c) 2013 The Chromium OS Authors. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
 */

/* Copyright (C) 2010 Google Inc. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE.WEBKIT file.
 */

#include <math.h>

#define DEFAULT_Q 0.707106781186548

enum { PEAK, LOWSHELF, HIGHSHELF, BANDPASS, LOWPASS, HIGHPASS, ALLPASS };

static void set(double *c, double b0, double b1, double b2, double a0, double a1, double a2)
{
	double inv = 1 / a0;
	c[0] = b0 * inv;
	c[1] = b1 * inv;
	c[2] = b2 * inv;
	c[3] = a1 * inv;
	c[4] = a2 * inv;
}

static void lowpass(double *c, double cutoff, double q)
{
	cutoff = fmax(0.0, fmin(cutoff, 1.0));
	if (cutoff == 1 || cutoff == 0) {
		set(c, cutoff, 0, 0, 1, 0, 0);
		return;
	}
	if (q <= 0)
		q = DEFAULT_Q;
	double w0 = M_PI * cutoff, alpha = sin(w0) / (2 * q), k = cos(w0);
	set(c, (1 - k) / 2, 1 - k, (1 - k) / 2, 1 + alpha, -2 * k, 1 - alpha);
}

static void highpass(double *c, double cutoff, double q)
{
	cutoff = fmax(0.0, fmin(cutoff, 1.0));
	if (cutoff == 1 || cutoff == 0) {
		set(c, 1 - cutoff, 0, 0, 1, 0, 0);
		return;
	}
	if (q <= 0)
		q = DEFAULT_Q;
	double w0 = M_PI * cutoff, alpha = sin(w0) / (2 * q), k = cos(w0);
	set(c, (1 + k) / 2, -(1 + k), (1 + k) / 2, 1 + alpha, -2 * k, 1 - alpha);
}

static void bandpass(double *c, double freq, double q)
{
	freq = fmax(0.0, freq);
	q = fmax(0.0, q);
	if (freq <= 0 || freq >= 1) {
		set(c, 0, 0, 0, 1, 0, 0);
		return;
	}
	if (q <= 0) {
		set(c, 1, 0, 0, 1, 0, 0);
		return;
	}
	double w0 = M_PI * freq, alpha = sin(w0) / (2 * q), k = cos(w0);
	set(c, alpha, 0, -alpha, 1 + alpha, -2 * k, 1 - alpha);
}

static void lowshelf(double *c, double freq, double q, double gain)
{
	freq = fmax(0.0, fmin(freq, 1.0));
	double a = pow(10.0, gain / 40);
	if (freq == 1) {
		set(c, a * a, 0, 0, 1, 0, 0);
		return;
	}
	if (freq <= 0) {
		set(c, 1, 0, 0, 1, 0, 0);
		return;
	}
	if (q <= 0)
		q = DEFAULT_Q;
	double w0 = M_PI * freq, alpha = sin(w0) / (2 * q), k = cos(w0);
	double k2 = 2 * sqrt(a) * alpha, ap = a + 1, am = a - 1;
	set(c, a * (ap - am * k + k2), 2 * a * (am - ap * k), a * (ap - am * k - k2),
	    ap + am * k + k2, -2 * (am + ap * k), ap + am * k - k2);
}

static void highshelf(double *c, double freq, double q, double gain)
{
	freq = fmax(0.0, fmin(freq, 1.0));
	double a = pow(10.0, gain / 40);
	if (freq == 1) {
		set(c, 1, 0, 0, 1, 0, 0);
		return;
	}
	if (freq <= 0) {
		set(c, a * a, 0, 0, 1, 0, 0);
		return;
	}
	if (q <= 0)
		q = DEFAULT_Q;
	double w0 = M_PI * freq, alpha = sin(w0) / (2 * q), k = cos(w0);
	double k2 = 2 * sqrt(a) * alpha, ap = a + 1, am = a - 1;
	set(c, a * (ap + am * k + k2), -2 * a * (am + ap * k), a * (ap + am * k - k2),
	    ap - am * k + k2, 2 * (am - ap * k), ap - am * k - k2);
}

static void peaking(double *c, double freq, double q, double gain)
{
	freq = fmax(0.0, fmin(freq, 1.0));
	q = fmax(0.0, q);
	double a = pow(10.0, gain / 40);
	if (freq <= 0 || freq >= 1) {
		set(c, 1, 0, 0, 1, 0, 0);
		return;
	}
	if (q <= 0) {
		set(c, a * a, 0, 0, 1, 0, 0);
		return;
	}
	double w0 = M_PI * freq, alpha = sin(w0) / (2 * q), k = cos(w0);
	set(c, 1 + alpha * a, -2 * k, 1 - alpha * a, 1 + alpha / a, -2 * k, 1 - alpha / a);
}

static void allpass(double *c, double freq, double q)
{
	freq = fmax(0.0, fmin(freq, 1.0));
	q = fmax(0.0, q);
	if (freq <= 0 || freq >= 1) {
		set(c, 1, 0, 0, 1, 0, 0);
		return;
	}
	if (q <= 0) {
		set(c, -1, 0, 0, 1, 0, 0);
		return;
	}
	double w0 = M_PI * freq, alpha = sin(w0) / (2 * q), k = cos(w0);
	set(c, 1 - alpha, -2 * k, 1 + alpha, 1 + alpha, -2 * k, 1 - alpha);
}

void microos_eq_rbj(int type, double freq, double gain, double q, double rate, double c[5])
{
	double f = freq * 2 / rate;
	switch (type) {
	case PEAK:
		peaking(c, f, q, gain);
		break;
	case LOWSHELF:
		lowshelf(c, f, q, gain);
		break;
	case HIGHSHELF:
		highshelf(c, f, q, gain);
		break;
	case BANDPASS:
		bandpass(c, f, q);
		break;
	case LOWPASS:
		lowpass(c, f, q);
		break;
	case HIGHPASS:
		highpass(c, f, q);
		break;
	case ALLPASS:
		allpass(c, f, q);
		break;
	default:
		set(c, 1, 0, 0, 1, 0, 0);
		break;
	}
}
