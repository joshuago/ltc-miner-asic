# LTC-3N Litecoin Miner ASIC - Simulation Makefile
# Uses Verilator for lint and C++ simulation

VERILATOR      := verilator
VERILATOR_FLAGS := --default-language 1800-2017 -Wall -Wno-fatal

# ─── Salsa20/8 module (cleanest, simplest) ───
SALSA_FILES := rtl/salsa20_quarter_round.sv \
               rtl/salsa20_8.sv

# ─── Scrypt core (full mining pipeline) ───
SCRYPT_CORE_FILES := rtl/salsa20_quarter_round.sv \
                     rtl/salsa20_8.sv \
                     rtl/blockmix.sv \
                     rtl/scratchpad_spram.sv \
                     rtl/romix.sv \
                     rtl/sha256_pipelined.sv \
                     rtl/scrypt_core.sv

# ─── Top level (UART, nonce manager, 4096 cores) ───
TOP_FILES := rtl/salsa20_quarter_round.sv \
             rtl/salsa20_8.sv \
             rtl/blockmix.sv \
             rtl/scratchpad_spram.sv \
             rtl/romix.sv \
             rtl/sha256_pipelined.sv \
             rtl/scrypt_core.sv \
             rtl/pll.sv \
             rtl/uart.sv \
             rtl/sync_fifo.sv \
             rtl/nonce_manager.sv \
             rtl/scrypt_top.sv

# ─── Default target ───
.PHONY: all help
all: lint

help:
	@echo "LTC-3N Litecoin Miner ASIC - Simulation Makefile"
	@echo ""
	@echo "Targets:"
	@echo "  make lint             - Lint all modules (default)"
	@echo "  make lint-salsa20     - Lint salsa20_8 only"
	@echo "  make lint-scrypt-core - Lint scrypt_core only"
	@echo "  make sim-salsa20      - Build + run salsa20_8 simulation"
	@echo "  make sim-scrypt-core  - Build + run scrypt_core simulation (~54K cycles per hash)"
	@echo "  make trace-salsa20    - Build + run salsa20 with VCD waveform output"
	@echo "  make clean            - Remove obj_dir and .vcd files"
	@echo ""

# ─── Lint targets ───
.PHONY: lint lint-salsa20 lint-scrypt-core lint-top

lint: lint-salsa20 lint-scrypt-core

lint-salsa20:
	$(VERILATOR) --lint-only $(VERILATOR_FLAGS) $(SALSA_FILES)

lint-scrypt-core:
	$(VERILATOR) --lint-only $(VERILATOR_FLAGS) $(SCRYPT_CORE_FILES)

lint-top:
	$(VERILATOR) --lint-only $(VERILATOR_FLAGS) $(TOP_FILES)

# ─── Simulation targets ───
.PHONY: sim-salsa20 sim-scrypt-core sim-top

sim-salsa20:
	$(VERILATOR) --cc --build -j --top-module salsa20_8 \
		$(VERILATOR_FLAGS) \
		$(SALSA_FILES) \
		--exe sim/sim_main_salsa20.cpp \
		-o sim_salsa20
	./obj_dir/sim_salsa20

sim-scrypt-core:
	$(VERILATOR) --cc --build -j --top-module scrypt_core \
		$(VERILATOR_FLAGS) \
		$(SCRYPT_CORE_FILES) \
		--exe sim/sim_main_scrypt_core.cpp \
		-o sim_scrypt_core
	./obj_dir/sim_scrypt_core

sim-top:
	$(VERILATOR) --cc --build -j --top-module scrypt_top \
		$(VERILATOR_FLAGS) \
		$(TOP_FILES) \
		--exe sim/sim_main_scrypt_top.cpp \
		-o sim_top
	./obj_dir/sim_top

# ─── Trace (VCD waveform) targets ───
.PHONY: trace-salsa20

trace-salsa20:
	$(VERILATOR) --cc --build -j --top-module salsa20_8 \
		$(VERILATOR_FLAGS) \
		--trace \
		$(SALSA_FILES) \
		--exe sim/sim_main_salsa20_trace.cpp \
		-o trace_salsa20
	./obj_dir/trace_salsa20

# ─── Cleanup ───
.PHONY: clean clean-all

clean:
	rm -rf obj_dir
	find . -name '*.vcd' -delete

clean-all: clean
	find . -name '*.o' -delete
	find . -name '*.d' -delete
