#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>

struct BiquadCoef {
    double b0, b1, b2, a1, a2;
};

static bool matched_peak(double freq, double gain, double q, double rate, BiquadCoef& c)
{
    if (gain == 0 || freq >= 0.49 * rate || q <= 0)
        return false;
    const double pi = 3.14159265358979323846;
    double A = pow(10.0, gain / 40.0);
    double w0 = 2 * pi * freq / rate;
    double g = A * A, z = 1 / (2 * q * A);
    double r = z <= 1 ? cos(sqrt(1 - z * z) * w0) : cosh(sqrt(z * z - 1) * w0);
    double a1 = -2 * exp(-z * w0) * r;
    double a2 = exp(-2 * z * w0);
    double A0 = (1 + a1 + a2) * (1 + a1 + a2), A1 = (1 - a1 + a2) * (1 - a1 + a2), A2 = -4 * a2;
    double p1 = sin(w0 / 2) * sin(w0 / 2), p0 = 1 - p1, p2 = 4 * p0 * p1;
    double R1 = (A0 * p0 + A1 * p1 + A2 * p2) * g * g, R2 = (-A0 + A1 + 4 * (p0 - p1) * A2) * g * g;
    double B0 = A0, B2 = (R1 - R2 * p1 - B0) / (4 * p1 * p1), B1 = R2 + B0 + 4 * (p1 - p0) * B2;
    double W = (sqrt(B0) + sqrt(std::max(B1, 0.0))) / 2;
    if (B1 < 0 || W * W + B2 < 0)
        return false;
    double b0 = (W + sqrt(W * W + B2)) / 2;
    double b1 = (sqrt(B0) - sqrt(B1)) / 2;
    double b2 = -B2 / (4 * b0);
    c = BiquadCoef{b0, b1, b2, a1, a2};
    return true;
}

static void bs2b(double fc, double level, double rate, BiquadCoef& lo, BiquadCoef& hi)
{
    const double pi = 3.14159265358979323846;
    double gb_lo = level * -5.0 / 6.0 - 3.0, gb_hi = level / 6.0 - 3.0;
    double g_lo = pow(10, gb_lo / 20.0);
    double g_hi = 1.0 - pow(10, gb_hi / 20.0);
    double fc_hi = fc * pow(2.0, (gb_lo - 20.0 * log10(g_hi)) / 12.0);
    double gain = 1.0 / (1.0 - g_hi + g_lo);
    double xl = exp(-2 * pi * fc / rate), xh = exp(-2 * pi * fc_hi / rate);
    lo = BiquadCoef{gain * g_lo * (1 - xl), 0, 0, -xl, 0};
    hi = BiquadCoef{gain * (1 - g_hi * (1 - xh)), 0, 0, -xh, 0};
    hi.b1 = (1.0 - lo.b0 / (1 - xl)) * (1 - xh) - hi.b0;
}

static double db(const BiquadCoef& c, double f, double rate)
{
    const double pi = 3.14159265358979323846;
    double w = 2 * pi * f / rate;
    double nr = c.b0 + c.b1 * cos(w) + c.b2 * cos(2 * w), ni = -c.b1 * sin(w) - c.b2 * sin(2 * w);
    double dr = 1 + c.a1 * cos(w) + c.a2 * cos(2 * w), di = -c.a1 * sin(w) - c.a2 * sin(2 * w);
    return 10 * log10((nr * nr + ni * ni) / (dr * dr + di * di));
}

static bool preset(const char* name, double& fc, double& level)
{
    if (!strcmp(name, "default"))
        fc = 700, level = 4.5;
    else if (!strcmp(name, "chuMoy"))
        fc = 700, level = 6.0;
    else if (!strcmp(name, "janMeier"))
        fc = 650, level = 9.5;
    else
        return false;
    return true;
}

int main(int argc, char** argv)
{
    if (argc == 6 && !strcmp(argv[1], "coef")) {
        BiquadCoef c{1, 0, 0, 0, 0};
        matched_peak(atof(argv[3]), atof(argv[4]), atof(argv[5]), atof(argv[2]), c);
        printf("%.17g %.17g %.17g %.17g %.17g\n", c.b0, c.b1, c.b2, c.a1, c.a2);
        return 0;
    }
    if (argc >= 4 && !strcmp(argv[1], "mag") && (argc - 4) % 3 == 0) {
        double rate = atof(argv[2]), preamp = atof(argv[3]), f;
        while (scanf("%lf", &f) == 1) {
            double sum = preamp;
            for (int i = 4; i < argc; i += 3) {
                BiquadCoef c{1, 0, 0, 0, 0};
                matched_peak(atof(argv[i]), atof(argv[i + 1]), atof(argv[i + 2]), rate, c);
                sum += db(c, f, rate);
            }
            printf("%g %.4f\n", f, sum);
        }
        return 0;
    }
    double fc, level;
    if (argc == 5 && !strcmp(argv[1], "xfeed") && preset(argv[2], fc, level)) {
        BiquadCoef lo, hi;
        double rate = atof(argv[3]), f = atof(argv[4]);
        bs2b(fc, level, rate, lo, hi);
        printf("%.4f %.4f\n", db(hi, f, rate), db(lo, f, rate));
        return 0;
    }
    if (argc == 4 && !strcmp(argv[1], "xcoef") && preset(argv[2], fc, level)) {
        BiquadCoef lo, hi;
        bs2b(fc, level, atof(argv[3]), lo, hi);
        printf("%.17g %.17g %.17g %.17g %.17g\n", lo.b0, lo.b1, lo.b2, lo.a1, lo.a2);
        printf("%.17g %.17g %.17g %.17g %.17g\n", hi.b0, hi.b1, hi.b2, hi.a1, hi.a2);
        return 0;
    }
    fprintf(stderr, "usage: flatdap-ref coef <rate> <Hz> <dB> <Q> | mag <rate> <preamp dB> [<Hz> <dB> <Q>]... < freqs"
                    " | xfeed <preset> <rate> <Hz> | xcoef <preset> <rate>\n");
    return 2;
}
