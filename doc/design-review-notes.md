# LTC-3N Design Review Notes

## FIXED

The following issues have been addressed:

| # | File | Issue | Resolution |
|---|------|-------|-------------|
| 1 | `sha256_pipelined.sv:108-115` | state_in OOB indexing (`31*N` → `32*N`) | Fixed: changed stride to 32 |
| 2 | `sha256_pipelined.sv:188` | W[16..31] never computed (`r >= 16` guard) | Fixed: removed guard; W computed from r=0 |
| 3 | `scrypt_core.sv:64` | FSM encoding 4 bits for 18 states | Fixed: widened to `logic [4:0]` (31 states used) |
| 4 | `scrypt_core.sv` | SHA-256 multi-block chaining broken | Fixed: FSM rewritten to wait for `sha_done` between blocks |
| 5 | `scrypt_core.sv` | Final PBKDF2 missing outer HMAC | Fixed: full inner+outer HMAC for final PBKDF2 |
| 6 | `scrypt_core.sv` | Nonce iteration skips prehash | Fixed: NEXT_NONCE → FSM_PRE_B0 to recompute K' |
| 7 | `romix.sv:60-61` | integerify extracted from wrong half (B[0] vs B[1]) | Fixed: changed to `x_val[9:0]` (B[1] low 10 bits) |
| 8 | `scrypt_core.sv` | Malformed SHA-256 padding | Fixed: corrected all pad bit counts and length fields |
| 11 | `scratchpad_dpram.sv` | Named "dpram" but single-port | Fixed: renamed to `scratchpad_spram.sv` |
| 16 | `pll.sv:33-35` | `localparam real` outside `ifdef SIMULATION` | Fixed: moved inside `ifdef` block |
| — | `scrypt_core.sv` | HMAC key padding swapped (key in wrong half of ipad/opad block) | Fixed: `{sha_hash ^ ipad, ipad}` ordering corrected |
| — | `scrypt_core.sv` | Syntax: `64'd(144*8)` → `64'(144*8)` | Fixed: expression literal syntax |
| — | `sha256_pipelined.sv:144` | Missing `genvar r` declaration | Fixed: added `genvar r` |

---

## UNRESOLVED

### Design

### 9. SHA-256 blocks processed serially, not pipelined — `rtl/scrypt_core.sv`

The FSM waits for `sha_done` before submitting each subsequent SHA-256 block. With a 65-cycle pipeline, each block takes ~65 cycles instead of being submitted back-to-back. A 3-block inner hash takes ~195 cycles instead of ~67. 

The serial approach is functionally correct. Full pipelining would require the SHA-256 module to internally capture and chain intermediate state, eliminating the need for the caller to provide `state_in`.

### 10. SDC clock constraints inconsistent — `constraints/top_constraints.sdc:8`

`create_clock` on `xtal_in` with 0.833ns period, but xtal_in is 25 MHz (40ns period). Lines 11 and 15 correctly use `-multiply_by` from xtal_in for generated clocks, so the root clock period is still wrong.

### 12. FIFO backpressure not enforced at top level — `rtl/sync_fifo.sv`

The sync_fifo itself checks `!full` before writing, but `scrypt_top.sv` does not check the `full` signal before asserting `wr_en`. Found shares can be silently dropped when the FIFO is full.

### 13. Nonce manager combinational priority arbiter — `rtl/nonce_manager.sv:49-58`

A combinational priority encoder over 4,096 request lines creates a long critical path at 1.2 GHz. Should be pipelined or split into a tree.

### 14. Salsa20 testbench lacks test vectors — `tb/salsa20_tb.sv`

Only tests all-zeros input. No real Salsa20/8 test vectors (e.g. from eSTREAM or the Bernstein reference).

### 15. Scrypt core testbench has non-discriminating target — `tb/scrypt_core_tb.sv:103`

Target set to all-ones (always found). Doesn't test hash comparison logic. (Note: C++ Verilator harness fixed this.)

### 17. SDC `set_max_area` units — `constraints/top_constraints.sdc:116`

`set_max_area 420000000` — units are tool/library-dependent, likely incorrect.

### 18. Non-standard SDC commands — `constraints/top_constraints.sdc:124-125`

`set_max_dynamic_power` and `set_max_leakage_power` are not part of standard SDC.

### Documentation

### 19. 512 MB on-chip SRAM implausible — `docs/architecture.md:14`

512 MB of SRAM on a single 420 mm² die is impractical at 3nm (yield, density). The largest TSMC N3 SRAM implementations are in the tens of MB range.

### 20. Power estimates appear too low — `docs/architecture.md:103-111`

Estimated ~25W for 512 MB of SRAM at 1.2 GHz is 1-2 orders of magnitude too low. A typical 128 KB SRAM macro at 1.2 GHz consumes ~2-5 mW, so 4,096 instances would be ~8-20W — but the power numbers for Salsa20 and SHA-256 pipelines (8.2W and 3.3W for 4,096 cores) also appear optimistic. Realistic total power is likely 50-150W.
