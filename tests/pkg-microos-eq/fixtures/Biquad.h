#pragma once

#include <vector>

namespace microdap {

enum class BiquadType {
    Peak = 0,
    LowShelf = 1,
    HighShelf = 2,
    BandPass = 3,
    LowPass = 4,
    HighPass = 5,
    AllPass = 6,
};

struct BiquadCoeffs
{
    std::vector<double> b;
    std::vector<double> a;
    bool guarded = false;
};

BiquadCoeffs biquadFor(BiquadType type, double f0, double gainDb, double q, double rate);
BiquadCoeffs biquadUnity();
BiquadCoeffs biquadMute();
bool biquadIsUnity(BiquadType type, double gainDb);
double biquadMagnitude(const BiquadCoeffs &coeffs, double f, double rate);

}
