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

    // Result output
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

    // Result arbiter: find lowest-index core with found
    logic                 any_found;
    logic [CORE_ID_W-1:0] found_core;

    always_comb begin
        any_found  = 1'b0;
        found_core = '0;
        for (int i = 0; i < N_CORES; i++) begin
            if (core_found[i] && !any_found) begin
                any_found  = 1'b1;
                found_core = CORE_ID_W'(i);
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            nonce_next    <= 32'd0;
            hash_count    <= '0;
            share_count   <= '0;
            job_valid     <= 1'b0;
            job_core_id   <= '0;
            job_header    <= '0;
            job_target    <= '0;
            job_nonce_base <= '0;
            result_valid  <= 1'b0;
            result_nonce  <= '0;
            result_hash   <= '0;
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

            // Report found results
            if (any_found) begin
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
