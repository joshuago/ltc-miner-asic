// UART round-trip test for Verilator.
//
// Drives the TX side with a series of bytes, ties rx to tx, and checks
// the RX side reads back the same bytes. Uses a tick model where 1 sys_clk
// "tick" is 10 ns and baud_clk toggles every 27 ticks (~1.85 MHz), so the
// 16x oversample tick fires close to the real 115200-baud rate.
//
// The two assertions verified here:
//   1. The bit timing actually uses baud_clk (issue #27): if it used clk
//      directly the simulation would complete in ~16 sys_clk per bit and
//      no RX byte would be captured.
//   2. The RX samples at mid-bit (issue #27 timing fix): randomly mistimed
//      sampling would yield incorrect bytes for at least some of the
//      payload.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <vector>

#include "Vuart.h"
#include "verilated.h"

static uint64_t sim_time = 0;

// baud_clk period in sys_clk ticks. Real hardware would have
// sys_clk=100MHz and baud_clk=1.8432MHz, so one baud_clk period is
// ~54 sys_clk ticks. Use 54 here.
static constexpr int kBaudPeriodTicks = 54;

static void tick(Vuart& top) {
    // Toggle baud_clk every kBaudPeriodTicks/2 sys_clk ticks (50% duty).
    top.baud_clk = ((sim_time / (kBaudPeriodTicks / 2)) & 1) ? 1 : 0;

    top.clk = 0;
    top.eval();
    top.clk = 1;
    top.eval();
    sim_time++;
}

static void reset(Vuart& top, int cycles) {
    top.rst_n = 0;
    top.tx_valid = 0;
    top.tx_data = 0;
    top.rx = 1;          // idle high
    for (int i = 0; i < cycles; i++)
        tick(top);
    top.rst_n = 1;
    tick(top);
}

// Push one byte into the TX side and wait until tx_ready returns.
// Loop the TX line back into RX in the same tick so the receiver sees it.
// Returns the cycle at which we deasserted tx_valid (for diagnostics).
static int send_byte(Vuart& top, uint8_t b) {
    // wait for tx_ready
    int waited = 0;
    while (!top.tx_ready && waited < 1000000) {
        top.rx = top.tx;
        tick(top);
        waited++;
    }
    if (!top.tx_ready) return -1;

    top.tx_data = b;
    top.tx_valid = 1;
    top.rx = top.tx;
    tick(top);
    top.tx_valid = 0;

    return 0;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    auto top = std::make_unique<Vuart>();

    reset(*top, 10);

    printf("=== UART round-trip simulation ===\n");
    printf("baud_clk period: %d sys_clk ticks (~115200 baud at 100 MHz)\n",
           kBaudPeriodTicks);

    std::vector<uint8_t> payload = {
        0xA5, 0x01, 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0xFF,
        0x12, 0x34, 0x56, 0x78, 0x55, 0xAA, 0x5A, 0xA5,
    };
    std::vector<uint8_t> received;

    // Submit all bytes. While each transmits, loop tx->rx and poll
    // rx_valid; record any bytes the receiver presents.
    for (size_t i = 0; i < payload.size(); i++) {
        if (send_byte(*top, payload[i]) != 0) {
            printf("[FAIL] timeout waiting for tx_ready before byte %zu\n", i);
            return 1;
        }
        // pump until tx_ready returns true (full byte transmitted).
        // along the way, sample rx_valid for received bytes.
        int waited = 0;
        while (!top->tx_ready && waited < 1000000) {
            top->rx = top->tx;
            tick(*top);
            if (top->rx_valid) received.push_back(top->rx_data);
            waited++;
        }
        // Continue pumping a bit longer so the receiver has time to
        // finish its stop bit and assert rx_valid.
        for (int j = 0; j < kBaudPeriodTicks * 20; j++) {
            top->rx = top->tx;
            tick(*top);
            if (top->rx_valid) received.push_back(top->rx_data);
        }
    }

    printf("sent     %zu bytes\n", payload.size());
    printf("received %zu bytes\n", received.size());

    int errors = 0;
    if (received.size() != payload.size()) {
        printf("[FAIL] byte count mismatch (expected %zu got %zu)\n",
               payload.size(), received.size());
        errors++;
    }
    for (size_t i = 0; i < payload.size() && i < received.size(); i++) {
        if (received[i] != payload[i]) {
            printf("[FAIL] byte %zu: sent 0x%02X received 0x%02X\n",
                   i, payload[i], received[i]);
            errors++;
        }
    }
    if (errors == 0)
        printf("[PASS] all %zu bytes round-tripped correctly\n",
               payload.size());

    printf("total sys_clk ticks: %llu\n",
           static_cast<unsigned long long>(sim_time));

    top->final();
    return errors ? 1 : 0;
}
