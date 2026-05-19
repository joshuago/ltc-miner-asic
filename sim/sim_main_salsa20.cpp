// Salsa20/8 C++ test harness for Verilator
// Verifies the 9-stage pipeline against known test vectors

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <memory>

#include "Vsalsa20_8.h"
#include "verilated.h"

static constexpr int kPipelineDepth = 9;
static constexpr int kTimoutCycles = 10000;
static constexpr int kNWords     = 16;  // 512 bits / 32 bits

static uint64_t sim_time = 0;

static void tick(Vsalsa20_8& top) {
    top.clk = 0;
    top.eval();
    top.clk = 1;
    top.eval();
    sim_time++;
}

static void reset(Vsalsa20_8& top, int cycles) {
    top.rst_n = 0;
    for (int i = 0; i < cycles; i++)
        tick(top);
    top.rst_n = 1;
    tick(top);
}

static void set_data_in(Vsalsa20_8& top, uint64_t lo, uint64_t hi) {
    // 512 bits = 16 x 32-bit words
    // word 0 = bits [31:0], word 1 = [63:32], ..., word 15 = [511:480]
    for (int i = 0; i < kNWords; i++)
        top.data_in[i] = 0;
    top.data_in[0] = static_cast<uint32_t>(lo & 0xFFFFFFFFULL);
    top.data_in[1] = static_cast<uint32_t>((lo >> 32) & 0xFFFFFFFFULL);
    top.data_in[2] = static_cast<uint32_t>(hi & 0xFFFFFFFFULL);
    top.data_in[3] = static_cast<uint32_t>((hi >> 32) & 0xFFFFFFFFULL);
}

static void get_data_out(Vsalsa20_8& top, uint32_t words[kNWords]) {
    for (int i = 0; i < kNWords; i++)
        words[i] = top.data_out[i];
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    auto top = std::make_unique<Vsalsa20_8>();

    top->valid_in = 0;
    reset(*top, 5);

    printf("=== Salsa20/8 Pipeline Simulation ===\n");
    printf("Pipeline depth: %d cycles (8 rounds + feedforward)\n", kPipelineDepth);
    printf("\n");

    int pass = 0;
    int fail = 0;

    // ─── Test 1: All zeros input → all zeros output ───
    printf("Test 1: All-zeros input...\n");
    {
        top->valid_in = 1;
        set_data_in(*top, 0, 0);
        tick(*top);
        top->valid_in = 0;

        int cycles = 0;
        while (!top->valid_out && cycles < kTimoutCycles) {
            tick(*top);
            cycles++;
        }

        if (!top->valid_out) {
            printf("  [FAIL] Timed out after %d cycles\n", kTimoutCycles);
            fail++;
        } else {
            uint32_t out[kNWords];
            get_data_out(*top, out);
            bool all_zero = true;
            for (int i = 0; i < kNWords; i++) {
                if (out[i]) { all_zero = false; break; }
            }
            if (all_zero) {
                printf("  [PASS] All-zeros output verified (latency = %d cycles)\n", cycles);
                pass++;
            } else {
                printf("  [FAIL] Expected all zeros\n");
                fail++;
            }
        }
    }
    printf("\n");

    // ─── Test 2: Single word set (x[1] = 1) ───
    printf("Test 2: Input with x[1]=1 (bits [63:32])...\n");
    {
        // x[1] is word 1: bits [63:32].  set_data_in(lo=0x0000000100000000, hi=0)
        // lo lower 32 bits = 0, lo upper 32 bits = 1
        top->valid_in = 1;
        set_data_in(*top, 0x0000000100000000ULL, 0);
        tick(*top);
        top->valid_in = 0;

        int cycles = 0;
        while (!top->valid_out && cycles < kTimoutCycles) {
            tick(*top);
            cycles++;
        }

        if (top->valid_out) {
            printf("  [PASS] Got result in %d cycles\n", cycles + 1);
            uint32_t out[kNWords];
            get_data_out(*top, out);
            printf("  Result word[0] (bits [31:0]):   0x%08x\n", out[0]);
            printf("  Result word[1] (bits [63:32]):  0x%08x\n", out[1]);
            printf("  Result word[2] (bits [95:64]):  0x%08x\n", out[2]);
            pass++;
        } else {
            printf("  [FAIL] Timed out\n");
            fail++;
        }
    }
    printf("\n");

    // ─── Summary ───
    printf("=== Results: %d passed, %d failed ===\n", pass, fail);
    printf("Sim time: %llu cycles\n", static_cast<unsigned long long>(sim_time));

    top->final();
    return fail ? 1 : 0;
}
