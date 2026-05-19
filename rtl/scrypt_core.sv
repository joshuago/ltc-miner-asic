// Scrypt Mining Core - TSMC N3 optimized
// Computes: hash = Scrypt(header||nonce, header, 1024, 1, 1, 32)
// Flags nonce as "found" if hash[255:224] < target
//
// Pipeline:
//   1. PBKDF2-HMAC-SHA256(password, salt, c=1, dkLen=128) → B (128 bytes)
//   2. ROMix(B, 1024) → B' (128 bytes)
//   3. PBKDF2-HMAC-SHA256(password, B', c=1, dkLen=32) → hash (32 bytes)
//   4. Compare hash < target
//
// SHA-256 blocks are processed serially (wait for sha_done between blocks).
// This is functionally correct at the cost of ~65 cycles per block rather
// than back-to-back submission. The pipeline has a 65-cycle feed-through
// latency; automatic chaining would require internal state feedback.

module scrypt_core (
    input  logic         clk,
    input  logic         rst_n,

    input  logic         job_valid,
    input  logic [639:0] header,
    input  logic [255:0] target,
    input  logic [31:0]  nonce_base,
    input  logic [15:0]  nonce_range,

    output logic         found_valid,
    output logic [31:0]  found_nonce,
    output logic [255:0] found_hash,

    output logic         busy,
    output logic [15:0]  nonces_done,
    output logic [63:0]  cycle_count
);

    sha256_pipelined u_sha256 (
        .clk        (clk),
        .rst_n      (rst_n),
        .valid_in   (sha_valid),
        .first_block(sha_first),
        .block_in   (sha_block),
        .state_in   (sha_state),
        .valid_out  (sha_done),
        .hash_out   (sha_hash)
    );

    romix u_romix (
        .clk      (clk),
        .rst_n    (rst_n),
        .start    (romix_start),
        .data_in  (romix_in),
        .done     (romix_done),
        .data_out (romix_out)
    );

    logic         sha_valid, sha_first, sha_done;
    logic [511:0] sha_block;
    logic [255:0] sha_state, sha_hash;

    logic         romix_start, romix_done;
    logic [1023:0] romix_in, romix_out;

    typedef enum logic [4:0] {
        FSM_IDLE,
        FSM_PRE_B0,    FSM_PRE_B0_W,
        FSM_PRE_B1,    FSM_PRE_B1_W,
        FSM_IN_B0,     FSM_IN_B0_W,
        FSM_IN_B1,     FSM_IN_B1_W,
        FSM_IN_B2,     FSM_IN_B2_W,
        FSM_OUT_B0,    FSM_OUT_B0_W,
        FSM_OUT_B1,    FSM_OUT_B1_W,
        FSM_ROMIX,     FSM_ROMIX_W,
        FSM_FIN_B0,    FSM_FIN_B0_W,
        FSM_FIN_B1,    FSM_FIN_B1_W,
        FSM_FIN_B2,    FSM_FIN_B2_W,
        FSM_FIN_B3,    FSM_FIN_B3_W,
        FSM_FOUT_B0,   FSM_FOUT_B0_W,
        FSM_FOUT_B1,   FSM_FOUT_B1_W,
        FSM_COMPARE,
        FSM_NEXT
    } fsm_t;

    fsm_t fsm;

    logic [639:0] header_reg;
    logic [255:0] target_reg;
    logic [31:0]  nonce_cur;
    logic [15:0]  nonce_left;
    logic [15:0]  nonce_done_cnt;

    logic [511:0]  ipad_k, opad_k;
    logic [1023:0] pbkdf2_B;
    logic [255:0]  inner_hash;
    logic [1:0]    pd_idx;

    localparam [255:0] IPAD_256 = {32{8'h36}};
    localparam [255:0] OPAD_256 = {32{8'h5c}};

    // Litecoin (and Bitcoin) interpret the 32-byte hash and target as
    // 256-bit little-endian integers when checking hash < target. The chip's
    // `sha_hash` is produced by SHA-256 with byte 0 at bit [255:248], i.e.
    // big-endian. Byte-reverse both operands before comparing so the result
    // matches the protocol convention. With this fix the host can send
    // `target` in its natural byte order (byte 0 of the target at
    // target[255:248]) instead of having to pre-swap it.
    wire [255:0] hash_le   = {<<8{sha_hash}};
    wire [255:0] target_le = {<<8{target_reg}};
    wire hash_below_target = (hash_le < target_le);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fsm            <= FSM_IDLE;
            header_reg     <= '0;
            target_reg     <= '0;
            nonce_cur      <= '0;
            nonce_left     <= '0;
            nonce_done_cnt <= '0;
            ipad_k         <= '0;
            opad_k         <= '0;
            pbkdf2_B       <= '0;
            inner_hash     <= '0;
            pd_idx         <= '0;
            sha_valid      <= 1'b0;
            sha_first      <= 1'b0;
            sha_block      <= '0;
            sha_state      <= '0;
            romix_start    <= 1'b0;
            romix_in       <= '0;
            found_valid    <= 1'b0;
            found_nonce    <= '0;
            found_hash     <= '0;
            cycle_count    <= '0;
            busy           <= 1'b0;
            nonces_done    <= '0;
        end else begin
            sha_valid   <= 1'b0;
            romix_start <= 1'b0;
            found_valid <= 1'b0;

            if (busy)
                cycle_count <= cycle_count + 64'd1;

            case (fsm)

                FSM_IDLE: begin
                    nonces_done <= nonce_done_cnt;
                    // Reject zero-range jobs. FSM_NEXT checks
                    // `nonce_left == 1` for completion, which would never
                    // fire after a 0 -> 0xFFFF underflow and would cause
                    // the core to mine 65,536 nonces for a 0-range job.
                    if (job_valid && nonce_range != 16'd0) begin
                        header_reg     <= header;
                        target_reg     <= target;
                        nonce_cur      <= nonce_base;
                        nonce_left     <= nonce_range;
                        nonce_done_cnt <= '0;
                        busy           <= 1'b1;
                        fsm            <= FSM_PRE_B0;
                    end
                end

                // ─── Prehash: K' = SHA256(header) ───
                FSM_PRE_B0: begin
                    sha_valid <= 1'b1;
                    sha_first <= 1'b1;
                    sha_block <= header_reg[639 -: 512];
                    fsm       <= FSM_PRE_B0_W;
                end

                FSM_PRE_B0_W: begin
                    if (sha_done) begin
                        sha_valid <= 1'b1;
                        sha_first <= 1'b0;
                        sha_state <= sha_hash;
                        sha_block <= {
                            header_reg[127:0],
                            1'b1,
                            319'd0,
                            64'd640
                        };
                        fsm <= FSM_PRE_B1_W;
                    end
                end

                FSM_PRE_B1_W: begin
                    if (sha_done) begin
                        ipad_k <= {sha_hash ^ IPAD_256, IPAD_256};
                        opad_k <= {sha_hash ^ OPAD_256, OPAD_256};
                        pd_idx <= 2'd0;
                        fsm    <= FSM_IN_B0;
                    end
                end

                // ─── Initial PBKDF2: HMAC(header, header||INT(i)) for i=1..4 ───
                FSM_IN_B0: begin
                    sha_valid <= 1'b1;
                    sha_first <= 1'b1;
                    sha_block <= ipad_k;
                    fsm       <= FSM_IN_B0_W;
                end

                FSM_IN_B0_W: begin
                    if (sha_done) begin
                        sha_valid <= 1'b1;
                        sha_first <= 1'b0;
                        sha_state <= sha_hash;
                        sha_block <= header_reg[639 -: 512];
                        fsm       <= FSM_IN_B1_W;
                    end
                end

                FSM_IN_B1_W: begin
                    if (sha_done) begin
                        sha_valid <= 1'b1;
                        sha_first <= 1'b0;
                        sha_state <= sha_hash;
                        // Block 3 of inner HMAC: 20 data bytes (header[64..79] || INT(i))
                        // + 0x80 pad byte at byte 20, zeros, then 64-bit length (1184 bits).
                        sha_block <= {
                            header_reg[127:0],
                            {30'd0, pd_idx + 2'd1},
                            1'b1,
                            287'd0,
                            64'd1184
                        };
                        fsm <= FSM_IN_B2_W;
                    end
                end

                FSM_IN_B2_W: begin
                    if (sha_done) begin
                        inner_hash <= sha_hash;
                        sha_valid  <= 1'b1;
                        sha_first  <= 1'b1;
                        sha_block  <= opad_k;
                        fsm        <= FSM_OUT_B0_W;
                    end
                end

                FSM_OUT_B0_W: begin
                    if (sha_done) begin
                        sha_valid <= 1'b1;
                        sha_first <= 1'b0;
                        sha_state <= sha_hash;
                        sha_block <= {
                            inner_hash,
                            1'b1,
                            191'd0,
                            64'd768
                        };
                        fsm <= FSM_OUT_B1_W;
                    end
                end

                FSM_OUT_B1_W: begin
                    if (sha_done) begin
                        // Store T[i] into pbkdf2_B converting from SHA byte order
                        // (byte 0 at sha_hash[255:248]) to salsa20-native byte
                        // order (byte 0 at the LSB of its 256-bit slice). This
                        // makes pbkdf2_B feedable directly to Salsa20/BlockMix.
                        pbkdf2_B[pd_idx*256 +: 256] <= {<<8{sha_hash}};
                        if (pd_idx == 2'd3) begin
                            header_reg[31:0] <= nonce_cur;
                            fsm <= FSM_ROMIX;
                        end else begin
                            pd_idx <= pd_idx + 2'd1;
                            fsm    <= FSM_IN_B0;
                        end
                    end
                end

                // ─── ROMix ───
                FSM_ROMIX: begin
                    romix_start <= 1'b1;
                    romix_in    <= pbkdf2_B;
                    fsm         <= FSM_ROMIX_W;
                end

                FSM_ROMIX_W: begin
                    if (romix_done)
                        fsm <= FSM_FIN_B0;
                end

                // ─── Final PBKDF2: HMAC(header, romix_out, 32) ───
                FSM_FIN_B0: begin
                    sha_valid <= 1'b1;
                    sha_first <= 1'b1;
                    sha_block <= ipad_k;
                    fsm       <= FSM_FIN_B0_W;
                end

                FSM_FIN_B0_W: begin
                    if (sha_done) begin
                        sha_valid <= 1'b1;
                        sha_first <= 1'b0;
                        sha_state <= sha_hash;
                        // Second block of final inner HMAC: bytes 0..63 of B'.
                        // Convert from salsa-native (byte 0 at romix_out[7:0])
                        // back to SHA byte order (byte 0 at sha_block[511:504]).
                        sha_block <= {<<8{romix_out[511:0]}};
                        fsm       <= FSM_FIN_B1_W;
                    end
                end

                FSM_FIN_B1_W: begin
                    if (sha_done) begin
                        sha_valid <= 1'b1;
                        sha_first <= 1'b0;
                        sha_state <= sha_hash;
                        // Third block of final inner HMAC: bytes 64..127 of B'.
                        sha_block <= {<<8{romix_out[1023:512]}};
                        fsm       <= FSM_FIN_B2_W;
                    end
                end

                FSM_FIN_B2_W: begin
                    if (sha_done) begin
                        sha_valid <= 1'b1;
                        sha_first <= 1'b0;
                        sha_state <= sha_hash;
                        sha_block <= {
                            32'd1,
                            1'b1,
                            415'd0,
                            64'd1568
                        };
                        fsm <= FSM_FIN_B3_W;
                    end
                end

                FSM_FIN_B3_W: begin
                    if (sha_done) begin
                        inner_hash <= sha_hash;
                        sha_valid  <= 1'b1;
                        sha_first  <= 1'b1;
                        sha_block  <= opad_k;
                        fsm        <= FSM_FOUT_B0_W;
                    end
                end

                FSM_FOUT_B0_W: begin
                    if (sha_done) begin
                        sha_valid <= 1'b1;
                        sha_first <= 1'b0;
                        sha_state <= sha_hash;
                        sha_block <= {
                            inner_hash,
                            1'b1,
                            191'd0,
                            64'd768
                        };
                        fsm <= FSM_FOUT_B1_W;
                    end
                end

                FSM_FOUT_B1_W: begin
                    if (sha_done) begin
                        fsm <= FSM_COMPARE;
                    end
                end

                // ─── Compare ───
                FSM_COMPARE: begin
                    if (hash_below_target) begin
                        found_valid <= 1'b1;
                        found_nonce <= nonce_cur;
                        found_hash  <= sha_hash;
                    end
                    fsm <= FSM_NEXT;
                end

                // ─── Next Nonce ───
                FSM_NEXT: begin
                    nonce_done_cnt <= nonce_done_cnt + 16'd1;
                    if (nonce_left == 16'd1) begin
                        busy        <= 1'b0;
                        nonces_done <= nonce_done_cnt + 16'd1;
                        fsm         <= FSM_IDLE;
                    end else begin
                        nonce_cur     <= nonce_cur + 32'd1;
                        nonce_left    <= nonce_left - 16'd1;
                        header_reg[31:0] <= nonce_cur + 32'd1;
                        fsm <= FSM_PRE_B0;
                    end
                end

                default: fsm <= FSM_IDLE;
            endcase
        end
    end

endmodule
