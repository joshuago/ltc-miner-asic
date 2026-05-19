// Nonce Manager - Continuous nonce distribution to N_CORES
// Each core processes NONCES_PER_CORE nonces per assignment
// New nonce ranges assigned as cores go idle

module nonce_manager #(
    parameter N_CORES         = 4096,
    parameter NONCES_PER_CORE = 32,
    parameter CORE_ID_W       = 12    // log2(N_CORES)
) (
    input  logic        clk,
    input  logic        rst_n,

    // Job input (broadcast)
    input  logic        new_job,
    input  logic [639:0] header,
    input  logic [255:0] target,

    // Per-core job output (valid + data, one per cycle)
    output logic        job_valid,
    output logic [CORE_ID_W-1:0] job_core_id,
    output logic [639:0] job_header,
    output logic [255:0] job_target,
    output logic [31:0]  job_nonce_base,

    // Core status
    input  logic [N_CORES-1:0] core_idle,
    input  logic [N_CORES-1:0] core_found,
    input  logic [31:0]        core_found_nonce [N_CORES-1:0],
    input  logic [255:0]       core_found_hash  [N_CORES-1:0],

    // Result output (to result FIFO).
    // `result_fifo_full` is the FIFO's full flag back-pressuring this
    // module: when high the arbiter holds off, leaving found events
    // latched until space is available.
    input  logic        result_fifo_full,
    output logic        result_valid,
    output logic [31:0] result_nonce,
    output logic [255:0] result_hash,

    // Statistics
    output logic [63:0] total_hashes,
    output logic [31:0] shares_found
);

    logic [31:0] nonce_next;
    logic [63:0] hash_count;
    logic [31:0] share_count;

    // Priority arbiter: find lowest-index idle core
    logic [CORE_ID_W-1:0] sel_core;
    logic                 any_idle;

    always_comb begin
        any_idle = 1'b0;
        sel_core = '0;
        for (int i = 0; i < N_CORES; i++) begin
            if (core_idle[i] && !any_idle) begin
                any_idle = 1'b1;
                sel_core = CORE_ID_W'(i);
            end
        end
    end

    // Per-core latch for found events. `core_found[i]` is only one cycle
    // wide; without a latch, two cores asserting on the same cycle would
    // collide at the combinational priority arbiter and the lower-priority
    // result would be lost. Each latch is set by `core_found[i]` and
    // cleared when the arbiter picks that core (and the FIFO has space).
    logic [N_CORES-1:0] core_found_latch;

    // Result arbiter: find lowest-index latched found.
    logic                 any_found;
    logic [CORE_ID_W-1:0] found_core;

    always_comb begin
        any_found  = 1'b0;
        found_core = '0;
        for (int i = 0; i < N_CORES; i++) begin
            if (core_found_latch[i] && !any_found) begin
                any_found  = 1'b1;
                found_core = CORE_ID_W'(i);
            end
        end
    end

    // Combinational "we're going to report this cycle" flag, used to gate
    // both the latch clear and the result_valid output. Off when the FIFO
    // is full so found events accumulate harmlessly.
    wire pop_now = any_found && !result_fifo_full;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            nonce_next       <= 32'd0;
            hash_count       <= '0;
            share_count      <= '0;
            job_valid        <= 1'b0;
            job_core_id      <= '0;
            job_header       <= '0;
            job_target       <= '0;
            job_nonce_base   <= '0;
            result_valid     <= 1'b0;
            result_nonce     <= '0;
            result_hash      <= '0;
            core_found_latch <= '0;
        end else begin
            job_valid    <= 1'b0;
            result_valid <= 1'b0;

            if (new_job) begin
                nonce_next <= 32'd0;
                hash_count <= '0;
            end

            // Assign work to an idle core
            if (any_idle && !new_job) begin
                job_valid     <= 1'b1;
                job_core_id   <= sel_core;
                job_header    <= header;
                job_target    <= target;
                job_nonce_base <= nonce_next;
                nonce_next    <= nonce_next + NONCES_PER_CORE;
                hash_count    <= hash_count + NONCES_PER_CORE;
            end

            // Update per-core found latches. Set has priority over clear so
            // a same-cycle set+clear is preserved (the arbiter will pick it
            // again next cycle).
            for (int i = 0; i < N_CORES; i++) begin
                if (core_found[i])
                    core_found_latch[i] <= 1'b1;
                else if (pop_now && (found_core == CORE_ID_W'(i)))
                    core_found_latch[i] <= 1'b0;
            end

            // Drain one latched result per cycle when the FIFO has space.
            // core_found_nonce[i] / core_found_hash[i] are registered inside
            // scrypt_core and hold their value across subsequent nonces in
            // the same range, so reading them combinationally here returns
            // the value that was captured when the core asserted found.
            if (pop_now) begin
                result_valid <= 1'b1;
                result_nonce <= core_found_nonce[found_core];
                result_hash  <= core_found_hash[found_core];
                share_count  <= share_count + 32'd1;
            end
        end
    end

    assign total_hashes = hash_count;
    assign shares_found = share_count;

endmodule
