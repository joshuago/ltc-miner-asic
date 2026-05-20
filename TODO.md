# LTC-3N Outstanding TODO

Consolidated view of work not yet done. Item numbers match
`doc/design-review-notes.md` UNRESOLVED entries; see that file for the
original review wording and any earlier discussion.

Status legend:
  - **blocking** -- chip's correctness claim depends on this
  - **latent**   -- works today by accident or under restricted use
  - **chore**    -- cleanup, doesn't affect behaviour today
  - **PD**       -- needed for physical design / tape-out, not for sim

---

## Verification

### #14  Salsa20/8 testbench has no real vectors -- *latent*

`tb/salsa20_tb.sv` and `sim/sim_main_salsa20.cpp` only check the trivial
all-zeros case (and for the C++ harness, print a single non-zero result
without comparing it). Replace with eSTREAM or Bernstein-reference
vectors so the pipeline can fail loudly if the quarter-round, the
round-permutation tables, or the feedforward addition regress.

The scrypt_core conformance harness (#25, FIXED) is a useful pattern
to mirror here: drive a known input, compare byte-for-byte against a
reference computed offline, dump a hex diff on mismatch.

---

## Latent correctness bugs

### #32  Pipeline `first_block` in SHA-256 -- *latent*

`rtl/sha256_pipelined.sv:224-231` reads `first_block` combinationally at
the output stage instead of the value latched 65 cycles ago. Today
`scrypt_core` serialises SHA invocations (issue #9), so `sha_first` is
stable across the pipeline depth and this masks the bug. The moment
anyone pipelines back-to-back SHA calls with different `first_block`
values -- including the obvious fix for #9 -- the wrong constant gets
added at the tail.

Fix: pipeline `first_block` through 65 stages alongside
`chain_state_pipe`.

### #36  Reset synchronisers are 1-FF deep -- *PD, latent*

`rtl/scrypt_top.sv:66-78` generates `core_rst_n` and `sys_rst_n` with a
single FF each, using `pll_lock` as the async clear. The reset-deassert
edge needs at least a 2-FF (preferably 3-FF) synchroniser in each
domain to avoid metastability. Should also gate `pll_lock`'s use as an
async reset through its own synchroniser per destination clock.

---

## Performance

### #9  SHA-256 blocks processed serially -- *latent (perf only)*

`rtl/scrypt_core.sv` waits for `sha_done` between each SHA-256 block.
With the 65-cycle pipeline this turns a 3-block inner hash into ~195
cycles instead of ~67. Total scrypt is dominated by ROMix (~41K cycles
out of ~54K), so the speedup from fixing this is modest -- maybe 15-20%
overall -- but it is real.

Fix: extend `sha256_pipelined` to capture and chain its own intermediate
state across back-to-back blocks (so the caller no longer drives
`state_in`). Must also fix #32 first, or do it as part of the same
change.

---

## Physical design / timing closure

### #13  Nonce manager has a 4096-input combinational priority encoder -- *PD*

`rtl/nonce_manager.sv:49-58` (the original idle-core arbiter; the
found-event arbiter at lines 60-73 has the same shape -- both
arbitrate over 4096 inputs combinationally). At 1.2 GHz (833 ps
period), this critical path will not close. Pipeline or tree it: e.g.,
arbitrate over 64 groups of 64 in stage 1, then 64 -> 1 in stage 2,
with one cycle of latency.

### #10  SDC root clock period is wrong -- *PD*

`constraints/top_constraints.sdc:8` declares `xtal_in` with a 0.833 ns
period, but `xtal_in` is 25 MHz (40 ns). The generated-clock lines do
use `-multiply_by` from `xtal_in`, so the *ratios* are correct, but the
absolute periods derived from `xtal_in` are off by 48x. Fix to
`create_clock -period 40.0 [get_ports {xtal_in}]`.

### #17  SDC `set_max_area` units -- *PD*

`set_max_area 420000000` at line 116 is tool/library-dependent. For a
420 mm^2 target the value in um^2 is 4.2e8, but most Synopsys flows
expect grid units from the library. Confirm against the actual N3
library and add a unit-bearing comment.

### #18  Non-standard SDC commands -- *PD*

`set_max_dynamic_power` and `set_max_leakage_power` at lines 124-125
are not standard SDC. Use UPF/CPF for power intent or the
vendor-specific dialect of whichever tool will read these constraints.

### #40  SDC false_path uses a fragile cell glob -- *PD*

`get_cells {u_result_fifo/*sync*}` (lines 50-51) depends on the
synchroniser register names being preserved through synthesis. Either
false-path the explicit register names, or replace with
`set_max_delay -datapath_only <core_clk_period>` between the two clock
domains.

---

## Cleanup

### #37  Top-level ports declared but unused -- *chore*

`rtl/scrypt_top.sv`: `temp_out`, `vcore_sel`, `jtag_tck`, `jtag_tms`,
`jtag_tdi`, `jtag_tdo` are in the port list but neither driven nor
read. `temp_out` synthesises to a constant. The "Temperature sensor"
and "JTAG" blocks shown in the architecture floorplan have no RTL
behind them. Either implement the modules they imply (a real ring
oscillator / TDC temperature sensor and a JTAG TAP), or remove the
ports.

### #38  Per-core statistics not aggregated -- *chore*

`scrypt_core` exposes `nonces_done` and `cycle_count`; both are tied
to `()` at `rtl/scrypt_top.sv:297-298`. Same for `nonce_manager`'s
`total_hashes` and `shares_found`. Aggregate into a counters block and
expose via a status response packet over UART (extend the protocol).

### #39  Unreachable FSM states in `scrypt_core` -- *chore*

`rtl/scrypt_core.sv:62-80` declares 31 states; transitions for blocks
2..N of multi-block SHA hashes go straight from one `_W` state to the
next, never visiting the corresponding non-`_W` "submit" state. About
a dozen enum values are unreachable. Remove them (will narrow the FSM
register) and rename the remaining `_W` states for clarity.

---

## Documentation

### #19  512 MB on-chip SRAM is implausible -- *chore*

`doc/architecture.md` claims 4,096 cores x 128 KB = 512 MB on a single
420 mm^2 die at N3. The largest published N3 SRAM implementations are
in the tens of MB. Either reduce the per-core scratchpad (which breaks
scrypt's N=1024 r=1 assumption), use stacked SRAM dies, or reduce the
core count substantially. Update the doc once a feasible number is
chosen.

### #20  Power estimates are too low -- *chore*

`doc/architecture.md` puts total chip power at ~25 W. A 128 KB SRAM
macro at 1.2 GHz typically consumes 5-50 mW (depending on activity);
with ROMix accessing the scratchpad on essentially every cycle the
upper end applies, giving 20-200 W from SRAM alone for 4,096 cores.
Logic, clock tree, and leakage add more. Realistic total is more like
50-150 W -- in which case the J/GH efficiency claim collapses (see
discussion of corrected hashrate in `doc/architecture.md`).

Recommendation: redo the power breakdown with realistic per-macro
numbers, and re-rank the design honestly against the L9 and L7.

---

## Out of scope (won't fix)

The combinational unroll error at `make lint-top` (4096-core generate
loop exceeding Verilator's default `--unroll-count`) is a tool limit,
not a design bug; bump `--unroll-count 5000` in the Makefile if you
ever want a clean `lint-top`. Not on the critical path because the
default `make lint` already covers everything else.
