#include <inttypes.h>
#include <signal.h>
#include <sys/mount.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <map>
#include <mutex>
#include <regex>
#include <set>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include <spdlog/spdlog.h>
#include <filesystem.h>
#include <../src/mesa/util/os_time.h>
#include "gpu_metrics_util.h"

#define private public
#include "gpu_fdinfo.h"
#undef private

#include "battery.h"
#include "file_utils.h"

static pid_t spawn(bool dumpable)
{
    int fds[2];
    if (pipe(fds) != 0)
        return -1;

    pid_t pid = fork();
    if (pid == 0) {
        prctl(PR_SET_PDEATHSIG, SIGKILL);
        if (!dumpable)
            prctl(PR_SET_DUMPABLE, 0);
        char c = 'x';
        if (write(fds[1], &c, 1) != 1)
            _exit(1);
        for (;;)
            pause();
    }

    char c;
    if (pid < 0 || read(fds[0], &c, 1) != 1)
        return -1;
    return pid;
}

static void write_fdinfo(const std::string& file, uint64_t ns)
{
    std::ofstream f(file, std::ios::trunc);
    f << "drm-driver:\tmsm\n"
      << "drm-client-id:\t7\n"
      << "drm-engine-gpu:\t" << ns << " ns\n"
      << "drm-total-memory:\t2097152 KiB\n"
      << "drm-resident-memory:\t1048576 KiB\n";
}

static GPU_fdinfo* paused_gpu()
{
    auto gpu = new GPU_fdinfo("msm_dpu", "", "renderD128");
    gpu->pause();
    gpu->metrics_mutex.lock();
    return gpu;
}

static int done(bool ok)
{
    std::fflush(stdout);
    _exit(ok ? 0 : 1);
}

int main(int argc, char** argv)
{
    if (argc < 2)
        return 2;
    const std::string what = argv[1];
    const std::string dir = argc > 2 ? argv[2] : "";

    if (what == "clock") {
        auto gpu = paused_gpu();
        int clock = gpu->get_gpu_clock();
        std::printf("clock %d\n", clock);
        return done(clock == 305);
    }

    if (what == "temp") {
        auto gpu = paused_gpu();
        gpu->get_current_hwmon_readings();
        int temp = gpu->hwmon_sensors["temp"].val / 1000;
        std::printf("temp %d\n", temp);
        return done(temp == 48);
    }

    if (what == "load") {
        const std::string fdinfo = dir + "/fdinfo";
        write_fdinfo(fdinfo + "/5", 1000);
        pid_t child = spawn(true);
        const std::string target = "/proc/" + std::to_string(child) + "/fdinfo";
        if (child < 0 || mount(fdinfo.c_str(), target.c_str(), nullptr, MS_BIND, nullptr) != 0) {
            std::printf("load setup failed\n");
            return done(false);
        }

        auto gpu = paused_gpu();
        gpu->pid = child;
        gpu->find_fd();
        gpu->previous_time = 0;
        gpu->previous_gpu_time = 0;

        gpu->gather_fdinfo_data();
        int first = gpu->get_gpu_load();
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        gpu->gather_fdinfo_data();
        int idle = gpu->get_gpu_load();
        write_fdinfo(fdinfo + "/5", 1000 + 50'000'000);
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        gpu->gather_fdinfo_data();
        int busy = gpu->get_gpu_load();

        std::printf("load fds %zu first %d idle %d busy %d\n", gpu->fdinfo.size(), first, idle, busy);
        return done(first == 0 && idle == 0 && busy > 0);
    }

    if (what == "vram") {
        const std::string fdinfo = dir + "/fdinfo";
        write_fdinfo(fdinfo + "/5", 1000);
        pid_t child = spawn(true);
        const std::string target = "/proc/" + std::to_string(child) + "/fdinfo";
        if (child < 0 || mount(fdinfo.c_str(), target.c_str(), nullptr, MS_BIND, nullptr) != 0) {
            std::printf("vram setup failed\n");
            return done(false);
        }

        auto gpu = paused_gpu();
        gpu->pid = child;
        gpu->find_fd();
        gpu->gather_fdinfo_data();
        float used = gpu->get_memory_used();
        std::printf("vram fds %zu used %.2f GiB\n", gpu->fdinfo.size(), used);
        return done(std::fabs(used - 1.0f) < 0.01f);
    }

    if (what == "battery") {
        BatteryStats battery;
        battery.numBattery();
        float percent = battery.getPercent();
        float watt = battery.getPower();
        std::printf("battery count %d percent %.1f watt %.2f\n", battery.batt_count, percent, watt);
        return done(battery.batt_count == 1 && std::lround(percent) == 57 && std::fabs(watt - 4.0f) < 0.01f);
    }

    if (what == "nd-fd") {
        pid_t child = spawn(false);
        if (child < 0)
            return done(false);
        auto gpu = paused_gpu();
        gpu->pid = child;
        gpu->find_fd();
        std::printf("nd-fd fds %zu\n", gpu->fdinfo.size());
        return done(gpu->fdinfo.empty());
    }

    if (what == "nd-lib") {
        pid_t child = spawn(false);
        if (child < 0)
            return done(false);
        bool loaded = lib_loaded("vkbasalt", child);
        std::printf("nd-lib loaded %d\n", loaded);
        return done(!loaded);
    }

    return 2;
}
