#include "Biquad.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <string>

using microdap::BiquadType;

int main(int argc, char **argv)
{
    if (argc < 3 || (argc - 3) % 4 != 0) {
        std::fprintf(stderr, "usage: biquad-ref <rate> <preamp dB> [<type> <Hz> <dB> <Q>]... < freqs\n");
        return 2;
    }
    const std::map<std::string, BiquadType> types = {
        {"peak", BiquadType::Peak},         {"lowshelf", BiquadType::LowShelf}, {"highshelf", BiquadType::HighShelf},
        {"bandpass", BiquadType::BandPass}, {"lowpass", BiquadType::LowPass},   {"highpass", BiquadType::HighPass},
        {"allpass", BiquadType::AllPass},
    };
    const double rate = std::atof(argv[1]);
    const double preamp = std::atof(argv[2]);
    double f;
    while (std::scanf("%lf", &f) == 1) {
        double db = preamp;
        for (int i = 3; i < argc; i += 4) {
            const auto type = types.find(argv[i]);
            if (type == types.end()) {
                std::fprintf(stderr, "biquad-ref: unknown type %s\n", argv[i]);
                return 2;
            }
            const auto coeffs = microdap::biquadFor(type->second, std::atof(argv[i + 1]), std::atof(argv[i + 2]),
                                                    std::atof(argv[i + 3]), rate);
            db += 20.0 * std::log10(microdap::biquadMagnitude(coeffs, f, rate));
        }
        std::printf("%g %.4f\n", f, db);
    }
    return 0;
}
