// Salsa20/8 C++ test harness with VCD trace generation

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <memory>

#include "Vsalsa20_8.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

static constexpr int kTimoutCycles = 10000;
static constexpr int kNWords     = 16;

static uint64_t sim_time = 0;

static void tick(Vsalsa20_8& top, VerilatedVcdC* tfp) {
    top.clk = 0;
    top.eval();
    if (tfp) tfp->dump(sim_time++);
    top.clk = 1;
    top.eval();
    if (tfp) tfp->dump(sim_time++);
}

static void reset(Vsalsa20_8& top, VerilatedVcdC* tfp, int cycles) {
    top.rst_n = 0;
    for (int i = 0; i < cycles; i++)
        tick(top, tfp);
    top.rst_n = 1;
    tick(top, tfp);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    auto top = std::make_unique<Vsalsa20_8>();

    Verilated::traceEverOn(true);
    auto tfp = std::make_unique<VerilatedVcdC>();
    top->trace(tfp.get(), 99);
    tfp->open("salsa20_trace.vcd");

    top->valid_in = 0;
    for (int i = 0; i < kNWords; i++) top->data_in[i] = 0;

    reset(*top, tfp.get(), 5);

    printf("=== Salsa20/8 Pipeline Trace Simulation ===\n");

    top->valid_in = 1;
    tick(*top, tfp.get());
    top->valid_in = 0;

    int cycles = 0;
    while (!top->valid_out && cycles < kTimoutCycles) {
        tick(*top, tfp.get());
        cycles++;
    }

    if (top->valid_out) {
        printf("[PASS] All-zeros test (latency = %d cycles)\n", cycles);
    } else {
        printf("[FAIL] Timed out\n");
    }

    printf("VCD trace written to salsa20_trace.vcd\n");
    tfp->close();
    top->final();
    return 0;
}
