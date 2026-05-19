# LTC-3N Design Review Notes

## FIXED

The following issues have been addressed:

| #  | File | Issue | Resolution |
|----|------|-------|-------------|
| 1  | `sha256_pipelined.sv:108-115` | state_in OOB indexing (`31*N` -> `32*N`) | Fixed: changed stride to 32 |
| 2  | `sha256_pipelined.sv:188` | W[16..31] never computed (`r >= 16` guard) | Fixed: removed guard; W computed from r=0 |
| 3  | `scrypt_core.sv:64` | FSM encoding 4 bits for 18 states | Fixed: widened to `logic [4:0]` (31 states used) |
| 4  | `scrypt_core.sv` | SHA-256 multi-block chaining broken | Fixed: FSM rewritten to wait for `sha_done` between blocks |
| 5  | `scrypt_core.sv` | Final PBKDF2 missing outer HMAC | Fixed: full inner+outer HMAC for final PBKDF2 |
| 6  | `scrypt_core.sv` | Nonce iteration skips prehash | Fixed: NEXT_NONCE -> FSM_PRE_B0 to recompute K' |
| 7  | `romix.sv:60-61` | integerify extracted from wrong half (B[0] vs B[1]) | Re-fixed: see #21 below; correct bits depend on byte order convention |
| 8  | `scrypt_core.sv` | Malformed SHA-256 padding | Partial: see #22 below for the remaining FSM_IN_B1_W misplacement |
| 11 | `scratchpad_dpram.sv` | Named "dpram" but single-port | Fixed: renamed to `scratchpad_spram.sv` |
| 16 | `pll.sv:33-35` | `localparam real` outside `ifdef SIMULATION` | Fixed: moved inside `ifdef` block |
| 21 | `scrypt_core.sv`, `blockmix.sv`, `romix.sv` | PBKDF2 storage order incompatible with BlockMix half-assignment (chip computed non-standard scrypt) | Fixed: pbkdf2_B / romix_in / romix_out now use salsa20-native byte order; SHA<->salsa conversion done at PBKDF2 boundaries; BlockMix swapped to use LOW=B[0], HIGH=B[1]; integerify now reads x_val[521:512] |
| 22 | `scrypt_core.sv:204-210` | SHA-256 padding bit misplaced in FSM_IN_B1_W (pad byte at byte 55 instead of byte 20) | Fixed: swapped `287'd0` and `1'b1` ordering |
| 23 | `romix.sv` (phase 2) | SRAM read race: bmix_in consumed stale sram_rdata one cycle before SRAM produced new data; caused `sim-scrypt-core` to hang | Fixed: inserted `ST_P2_READ` wait state between read issue and BlockMix start. Adds 1 cycle per phase-2 iteration (~2% slowdown). |
| 24 | `pll.sv:7`, `scrypt_top.sv:53` | `parameter VCO_FREQ = 4_800_000_000` overflowed 32-bit literal default (silently truncated to 505,032,704) | Fixed: declared as `parameter longint`, instantiated with `64'd` literals |
| -- | `scrypt_core.sv` | HMAC key padding swapped (key in wrong half of ipad/opad block) | Fixed: `{sha_hash ^ ipad, ipad}` ordering corrected |
| -- | `scrypt_core.sv` | Syntax: `64'd(144*8)` -> `64'(144*8)` | Fixed: expression literal syntax |
| -- | `sha256_pipelined.sv:144` | Missing `genvar r` declaration | Fixed: added `genvar r` |

---

## UNRESOLVED

### Verification

### 25. Reference scrypt vector verification not done

The fixes for issues 21-23 chose a particular byte-order convention
(salsa20-native inside `pbkdf2_B` / `romix_*`, with `{<<8{...}}`
conversion at the PBKDF2 boundaries) that is *internally consistent*
and matches the layout used by typical software scrypt
implementations (e.g. `libscrypt`, cgminer's `scrypt.c`). But the
chip's output has not been compared end-to-end against a known
reference for any input. The C++ harness still runs with an
all-ones target, so it only checks that the FSM terminates - not
that the hash is correct.

Recommended next step: take a known Litecoin block (header + nonce
+ expected hash) and feed it through `sim-scrypt-core`, comparing
`found_hash` to the reference value. Suggested vectors:

- Litecoin genesis block (block 0): a well-known fixed input.
- Any cgminer `--debug` output: pool work + winning nonce + hash.

If the chip's hash matches after a host-side byteswap (see #26),
the convention choice is correct. If not, the most likely
remaining issue is the within-word endian conversion at the
PBKDF2 boundaries.

### 26. Hash-vs-target comparison endianness not handled in RTL -- `rtl/scrypt_core.sv:99`

The chip computes `hash_below_target = (sha_hash < target_reg)`
as a 256-bit big-endian compare (bit 255 of `sha_hash` is the
SHA-256 output's first byte, MSB-first). The Bitcoin/Litecoin
protocol convention is to interpret both hash and target as
little-endian integers when checking `hash < target`.

Current workaround: the host must pre-reverse the byte order of
the target before submitting it (and re-reverse `found_hash`
after receiving it). This is non-obvious and would not match what
a standard pool stratum library produces.

Better long-term: byte-reverse `sha_hash` inside the chip before
the compare, and either byte-reverse the target on input or
require the host to supply target in BE form.

### Communication

### 27. UART module ignores `baud_clk` -- `rtl/uart.sv:34,110`

Both TX and RX `always_ff` blocks are clocked by `clk` (=
`sys_clk` = 100 MHz). The `baud_clk` input is declared but never
referenced. The 16-cycle threshold means the UART transmits at
`sys_clk / 16` ~= 6.25 Mbaud, not 115200. Until this is fixed
the chip cannot communicate with any standard host even if every
other UART bug is corrected.

Fix: either (a) clock the UART FSM directly on `baud_clk` with
proper CDC handshakes to `sys_clk`, or (b) keep the FSM on `clk`
but gate the counter advance with a `baud_clk` rising-edge
detector synchronised into the `clk` domain.

### 28. UART RX checksum check broken by operator precedence -- `rtl/scrypt_top.sv:160`

```
if (packet_cksum ^ uart_rx_data == 8'h00) begin
```

SystemVerilog parses `==` tighter than binary `^`, so this is
`packet_cksum ^ (uart_rx_data == 8'h00)`. Valid packets are
rejected; certain invalid ones are accepted. Fix:

```
if ((packet_cksum ^ uart_rx_data) == 8'h00) begin
```

or equivalently `if (packet_cksum == uart_rx_data)`.

### 29. UART TX uses wrong bit indices for hash and nonce -- `rtl/scrypt_top.sv:385,388`

`result_cdc_rdata = {nm_result_hash[255:0], nm_result_nonce[31:0]}`
is 288 bits with hash at `[287:32]` and nonce at `[31:0]`. The TX
code reads:

```
uart_tx_data <= result_cdc_rdata[255 - tx_byte_cnt*8 -: 8];      // hash
uart_tx_data <= result_cdc_rdata[287 - (tx_byte_cnt-32)*8 -: 8]; // "nonce"
```

The hash slice starts at bit 255 (= hash byte 4), dropping the
first four bytes. The "nonce" slice starts at bit 287 (= hash
byte 0), so the bytes transmitted as the nonce are actually the
hash MSBs. Even if mining were correct, no pool could verify a
share. Correct indices:

```
uart_tx_data <= result_cdc_rdata[287 - tx_byte_cnt*8 -: 8];        // hash
uart_tx_data <= result_cdc_rdata[31 - (tx_byte_cnt-32)*8 -: 8];    // nonce
```

### 30. UART TX duplicate byte at end of payload -- `rtl/scrypt_top.sv:380-395`

In `TX_PAYLOAD`, the top of the case unconditionally sets
`uart_tx_valid <= 1'b1` when `uart_tx_ready`. When `tx_byte_cnt`
reaches 36, neither the `<32` nor the `<36` branch updates
`uart_tx_data`, but `uart_tx_valid` still asserts and the FSM
transitions to `TX_CHECKSUM`. The UART transmits a duplicate of
the last nonce byte before the checksum. Suppress
`uart_tx_valid` in the transition cycle, or move it inside the
`<36` branch.

### 31. TX checksum is a placeholder -- `rtl/scrypt_top.sv:400`

`uart_tx_data <= tx_byte_cnt; // placeholder cksum`. The byte
transmitted is whatever `tx_byte_cnt` happens to be (zero, after
the reset in `TX_PAYLOAD`'s else branch). The protocol spec calls
for a real XOR-of-bytes checksum. The host cannot validate any
response until this is implemented.

### Robustness / CDC

### 9. SHA-256 blocks processed serially, not pipelined -- `rtl/scrypt_core.sv`

The FSM waits for `sha_done` before submitting each subsequent
SHA-256 block. With a 65-cycle pipeline, each block takes ~65
cycles instead of being submitted back-to-back. A 3-block inner
hash takes ~195 cycles instead of ~67. The serial approach is
functionally correct. Full pipelining would require the SHA-256
module to internally capture and chain intermediate state,
eliminating the need for the caller to provide `state_in`.

### 32. SHA-256 `first_block` not pipelined -- `rtl/sha256_pipelined.sv:224-231`

The final addition (IV vs chain-state) reads the *current*
`first_block` port value rather than a value latched 65 cycles
ago when the hash entered the pipeline. The scrypt_core FSM
serialises SHA invocations so `sha_first` is stable across the
pipeline depth and the bug is masked today. Pipeline
`first_block` through 65 stages alongside `chain_state_pipe` to
make this robust for any future pipelining (e.g. issue #9).

### 33. `nonce_range == 0` mines 65,536 nonces -- `rtl/scrypt_core.sv:352`

`FSM_NEXT` checks `nonce_left == 16'd1`. With `nonce_range == 0`
`nonce_left` starts at 0, decrements with 16-bit wraparound to
0xFFFF, and the chip mines 64K nonces before stopping. Either
gate the `IDLE -> PRE_B0` transition on `nonce_range != 0` or
test the post-decrement value.

### 34. `core_found` results can be silently dropped -- `rtl/nonce_manager.sv:60-73`

`core_found[c]` is a one-cycle pulse. If two cores assert it on
the same cycle, the combinational priority encoder only captures
the lowest-index one; the other is lost. Latch found events
per-core with a handshake, or feed results through a per-core
FIFO before the arbiter.

### 12. FIFO backpressure not enforced at top level -- `rtl/sync_fifo.sv`

The sync_fifo itself checks `!full` before writing, but
`scrypt_top.sv` does not check the `full` signal before asserting
`wr_en`. Found shares can be silently dropped when the FIFO is
full.

### 35. CDC for header/target relies on coincidental timing -- `rtl/scrypt_top.sv:201-208`

`header_core`/`target_core` are written in `sys_clk` but read
combinationally on the `core_clk` side. There is no formal
handshake; the design works in practice only because the 2-FF
sync of `new_job_pulse` adds latency during which `header_core`
is stable. Use a proper req/ack handshake with full multi-bit CDC,
or a 1-deep async FIFO.

### 36. Reset synchronisers are 1-FF deep -- `rtl/scrypt_top.sv:66-78`

`core_rst_n` and `sys_rst_n` are each generated by a single FF
with `pll_lock` as async clear. Standard practice is a 2- or
3-FF synchroniser on the reset-deassert edge.

### 13. Nonce manager combinational priority arbiter -- `rtl/nonce_manager.sv:49-58`

A combinational priority encoder over 4,096 request lines creates
a long critical path at 1.2 GHz. Should be pipelined or split
into a tree.

### Testbench

### 14. Salsa20 testbench lacks test vectors -- `tb/salsa20_tb.sv`

Only tests all-zeros input. No real Salsa20/8 test vectors (e.g.
from eSTREAM or the Bernstein reference).

### 15. Scrypt core testbench has non-discriminating target -- `tb/scrypt_core_tb.sv:103`

Target set to all-ones (always found). Doesn't test hash
comparison logic. (Note: C++ Verilator harness fixed this.) The
C++ harness still uses an all-ones target as well -- so it does
not exercise the compare either; it only verifies FSM
termination.

### Cleanup

### 37. Top-level ports unused -- `rtl/scrypt_top.sv`

`temp_out`, `vcore_sel`, `jtag_tck`, `jtag_tms`, `jtag_tdi`,
`jtag_tdo` are declared in the port list but never driven or
read inside the module. `temp_out` is an `output logic` that no
process assigns; it synthesises to a constant. The "Temperature
sensor" and "JTAG" blocks shown in the floorplan have no RTL
behind them.

### 38. Per-core statistics not aggregated -- `rtl/scrypt_top.sv:297-298`

`scrypt_core` exposes `nonces_done` and `cycle_count` outputs;
the top-level connects both to `()`. The chip cannot report
total cycle counts or completion stats. The `nonce_manager`'s
`total_hashes` and `shares_found` outputs are similarly tied
off.

### 39. Unused / unreachable FSM states -- `rtl/scrypt_core.sv:62-80`

The state enum declares 31 states; transitions skip the
non-`_W` "submit" states for blocks 2..N of multi-block hashes
(the next block is submitted from inside the previous `_W`
state). About a dozen enum values are unreachable, inflating the
state register and obscuring control flow.

### Constraints

### 10. SDC clock constraints inconsistent -- `constraints/top_constraints.sdc:8`

`create_clock` on `xtal_in` with 0.833 ns period, but `xtal_in`
is 25 MHz (40 ns period). Lines 11 and 15 correctly use
`-multiply_by` from `xtal_in` for the generated clocks, so the
root clock period is still wrong.

### 17. SDC `set_max_area` units -- `constraints/top_constraints.sdc:116`

`set_max_area 420000000` -- units are tool/library-dependent,
likely incorrect for the intended ~420 mm^2 die.

### 18. Non-standard SDC commands -- `constraints/top_constraints.sdc:124-125`

`set_max_dynamic_power` and `set_max_leakage_power` are not part
of standard SDC. Use the appropriate tool-specific power
constraint format (UPF/CPF or vendor-specific commands).

### 40. SDC false_path uses fragile cell glob -- `constraints/top_constraints.sdc:50-51`

`get_cells {u_result_fifo/*sync*}` depends on the synchroniser
register names being preserved through synthesis. Better to
false-path explicit register names, or use `set_max_delay
-datapath_only` between the two clock domains.

### Documentation

### 19. 512 MB on-chip SRAM implausible -- `docs/architecture.md:14`

512 MB of SRAM on a single 420 mm^2 die is impractical at 3nm
(yield, density). The largest TSMC N3 SRAM implementations are
in the tens of MB range.

### 20. Power estimates appear too low -- `docs/architecture.md:103-111`

Estimated ~25 W for 512 MB of SRAM at 1.2 GHz is 1-2 orders of
magnitude too low. A typical 128 KB SRAM macro at 1.2 GHz
consumes ~2-5 mW, so 4,096 instances would be ~8-20 W -- but the
power numbers for Salsa20 and SHA-256 pipelines (8.2 W and 3.3 W
for 4,096 cores) also appear optimistic. Realistic total power
is likely 50-150 W. The corrected hashrate (~92 MH/s; see issue
#19 in the main review) makes the J/GH efficiency calculation
sensitive to this estimate -- the design is only attractive on
efficiency if 25 W is achievable, which is doubtful.
