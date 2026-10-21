#include "Biquad.h"

#include <cmath>
#include <complex>
#include <numbers>
#include <utility>

namespace microdap {

namespace {

constexpr double guardRatio = 0.49;
constexpr double unityGainDb = 1e-9;

bool usesGain(BiquadType type)
{
    return type == BiquadType::Peak || type == BiquadType::LowShelf || type == BiquadType::HighShelf;
}

BiquadCoeffs normalized(std::vector<double> b, std::vector<double> a)
{
    const double a0 = a[0];
    for (double &v : b)
        v /= a0;
    for (double &v : a)
        v /= a0;
    return {std::move(b), std::move(a), false};
}

}

BiquadCoeffs biquadUnity()
{
    return {{1.0}, {1.0}, false};
}

BiquadCoeffs biquadMute()
{
    return {{0.0}, {1.0}, false};
}

bool biquadIsUnity(BiquadType type, double gainDb)
{
    return usesGain(type) && std::abs(gainDb) < unityGainDb;
}

BiquadCoeffs biquadFor(BiquadType type, double f0, double gainDb, double q, double rate)
{
    if (biquadIsUnity(type, gainDb))
        return biquadUnity();
    if (f0 >= guardRatio * rate) {
        const bool mutes = type == BiquadType::HighPass || type == BiquadType::BandPass;
        BiquadCoeffs guarded = mutes ? biquadMute() : biquadUnity();
        guarded.guarded = true;
        return guarded;
    }
    const double amp = std::pow(10.0, gainDb / 40.0);
    const double w = 2.0 * std::numbers::pi * f0 / rate;
    const double c = std::cos(w);
    const double alpha = std::sin(w) / (2.0 * q);
    const double plus = amp + 1.0;
    const double minus = amp - 1.0;
    const double r = 2.0 * std::sqrt(amp) * alpha;
    switch (type) {
    case BiquadType::Peak:
        return normalized({1.0 + alpha * amp, -2.0 * c, 1.0 - alpha * amp},
                          {1.0 + alpha / amp, -2.0 * c, 1.0 - alpha / amp});
    case BiquadType::LowShelf:
        return normalized({amp * (plus - minus * c + r), 2.0 * amp * (minus - plus * c), amp * (plus - minus * c - r)},
                          {plus + minus * c + r, -2.0 * (minus + plus * c), plus + minus * c - r});
    case BiquadType::HighShelf:
        return normalized({amp * (plus + minus * c + r), -2.0 * amp * (minus + plus * c), amp * (plus + minus * c - r)},
                          {plus - minus * c + r, 2.0 * (minus - plus * c), plus - minus * c - r});
    case BiquadType::BandPass:
        return normalized({alpha, 0.0, -alpha}, {1.0 + alpha, -2.0 * c, 1.0 - alpha});
    case BiquadType::LowPass:
        return normalized({(1.0 - c) / 2.0, 1.0 - c, (1.0 - c) / 2.0}, {1.0 + alpha, -2.0 * c, 1.0 - alpha});
    case BiquadType::HighPass:
        return normalized({(1.0 + c) / 2.0, -(1.0 + c), (1.0 + c) / 2.0}, {1.0 + alpha, -2.0 * c, 1.0 - alpha});
    case BiquadType::AllPass:
        return normalized({1.0 - alpha, -2.0 * c, 1.0 + alpha}, {1.0 + alpha, -2.0 * c, 1.0 - alpha});
    }
    return biquadUnity();
}

double biquadMagnitude(const BiquadCoeffs &coeffs, double f, double rate)
{
    const double w = 2.0 * std::numbers::pi * f / rate;
    const std::complex<double> zInv = std::polar(1.0, -w);
    auto eval = [&zInv](const std::vector<double> &p) {
        std::complex<double> sum = 0.0;
        std::complex<double> power = 1.0;
        for (double v : p) {
            sum += v * power;
            power *= zInv;
        }
        return sum;
    };
    return std::abs(eval(coeffs.b) / eval(coeffs.a));
}

}
