// Scrypt core C++ test harness for Verilator
// Submits a job and waits for result completion

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <memory>

#include "Vscrypt_core.h"
#include "verilated.h"

static constexpr int kTimeoutCycles = 1000000;

static uint64_t sim_time = 0;

static void tick(Vscrypt_core& top) {
    top.clk = 0;
    top.eval();
    top.clk = 1;
    top.eval();
    sim_time++;
}

static void reset(Vscrypt_core& top, int cycles) {
    top.rst_n = 0;
    for (int i = 0; i < cycles; i++)
        tick(top);
    top.rst_n = 1;
    tick(top);
}

static void set_header(Vscrypt_core& top, uint64_t lo, uint64_t hi) {
    for (int i = 0; i < 20; i++)
        top.header[i] = 0;
    top.header[0] = static_cast<uint32_t>(lo & 0xFFFFFFFFULL);
    top.header[1] = static_cast<uint32_t>((lo >> 32) & 0xFFFFFFFFULL);
    top.header[2] = static_cast<uint32_t>(hi & 0xFFFFFFFFULL);
    top.header[3] = static_cast<uint32_t>((hi >> 32) & 0xFFFFFFFFULL);
}

static void set_target(Vscrypt_core& top, uint64_t lo, uint64_t hi) {
    for (int i = 0; i < 8; i++)
        top.target[i] = 0xFFFFFFFF;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    auto top = std::make_unique<Vscrypt_core>();

    top->job_valid   = 0;
    top->nonce_base  = 0;
    top->nonce_range = 0;
    set_header(*top, 0, 0);
    set_target(*top, 0, 0);

    reset(*top, 10);

    printf("=== Scrypt Core Simulation ===\n");
    printf("ROMix N=1024, 2x PBKDF2 wrappers, SHA-256 pipeline\n");
    printf("\n");

    set_header(*top, 0x20000000ULL, 0);
    set_target(*top, 0xFFFFFFFFFFFFFFFFULL, 0xFFFFFFFFFFFFFFFFULL);
    top->nonce_base  = 0;
    top->nonce_range = 1;
    top->job_valid   = 1;
    tick(*top);
    top->job_valid   = 0;

    int cycles = 0;
    while (!top->found_valid && cycles < kTimeoutCycles) {
        tick(*top);
        cycles++;
        if (cycles % 10000 == 0)
            printf("  ... %d cycles elapsed, busy=%d\n", cycles, top->busy);
    }

    if (top->found_valid) {
        printf("\n[PASS] Nonce found at cycle %d\n", cycles);
        printf("  Nonce: 0x%08x\n", top->found_nonce);
    } else {
        printf("\n[FAIL] Timed out after %d cycles\n", kTimeoutCycles);
        printf("  Last busy = %d, found_valid = %d\n", top->busy, top->found_valid);
    }

    printf("Total sim cycles: %llu\n", static_cast<unsigned long long>(sim_time));

    top->final();
    return top->found_valid ? 0 : 1;
}
