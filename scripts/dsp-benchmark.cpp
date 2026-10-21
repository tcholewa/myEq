#include "CDSP.h"
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <vector>

int main() {
    constexpr unsigned frames = 256, blocks = 12000;
    for (double rate : {44100., 48000., 96000., 192000.}) {
        std::array<MEQBand, 8> bands;
        for (int i = 0; i < 8; ++i) bands[i] = {0, true, 60. * pow(2., i), i % 2 ? -6. : 6., .15};
        auto *dsp = meq_create();
        if (!meq_prepare(dsp, rate, bands.data(), 8, -12)) return 1;
        std::array<float, frames * 2> samples;
        std::vector<double> timings;
        timings.reserve(blocks);
        for (unsigned block = 0; block < blocks; ++block) {
            for (unsigned i = 0; i < frames; ++i) {
                samples[i * 2] = float(.1 * sin(2 * 3.141592653589793 * 997 * (block * frames + i) / rate));
                samples[i * 2 + 1] = samples[i * 2] * .7f;
            }
            if (block % 16 == 0) {
                bands[2].gain = (block / 16) % 2 ? 12 : -12;
                meq_submit(dsp, bands.data(), 8, -12);
            }
            const auto start = std::chrono::steady_clock::now();
            meq_process(dsp, samples.data(), frames);
            const auto elapsed = std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - start).count();
            timings.push_back(elapsed);
            for (auto sample : samples) if (!std::isfinite(sample) || std::abs(sample) > 1) return 2;
        }
        std::sort(timings.begin(), timings.end());
        const auto meter = meq_meter(dsp);
        std::printf("{\"sample_rate\":%.0f,\"frames_per_block\":%u,\"blocks\":%u,\"median_us\":%.2f,\"p99_us\":%.2f,\"max_us\":%.2f,\"p99_budget_percent\":%.2f,\"faults\":%llu}\n",
                    rate, frames, blocks, timings[blocks / 2], timings[blocks * 99 / 100], timings.back(), timings[blocks * 99 / 100] / (frames / rate * 1e6) * 100., (unsigned long long)meter.faults);
        meq_destroy(dsp);
        if (meter.faults) return 3;
    }
}
