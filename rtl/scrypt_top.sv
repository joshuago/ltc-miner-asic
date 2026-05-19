// LTC-3N Top-Level - 3nm Litecoin Miner ASIC
// 4096 Scrypt cores, ~200-300 GH/s target
// TSMC N3 process, 1.2 GHz core clock
//
// Interface: UART (115200 baud, 8N1) for job/report communication
// Clock: external 25 MHz crystal → internal PLL → 1.2 GHz
// Power: ~25W estimated at 0.7V VDD

module scrypt_top (
    // Clock / Reset
    input  logic        xtal_in,           // 25 MHz crystal
    input  logic        rst_ext_n,         // external reset

    // UART interface (host communication)
    input  logic        uart_rx,
    output logic        uart_tx,

    // Status LEDs
    output logic        led_green,         // hashing active
    output logic        led_red,           // error

    // JTAG (test/debug)
    input  logic        jtag_tck,
    input  logic        jtag_tms,
    input  logic        jtag_tdi,
    output logic        jtag_tdo,

    // Temperature sensor (internal)
    output logic [7:0]  temp_out,

    // Power management
    input  logic [3:0]  vcore_sel,         // voltage select: 0000=0.65V ... 1111=0.9V
    output logic        pll_lock
);

    localparam N_CORES         = 4096;
    localparam NONCES_PER_CORE = 32;
    localparam CORE_ID_W       = 12;

    // ─── Clocks and Resets ───

    logic core_clk;          // 1.2 GHz (PLL output)
    logic sys_clk;           // 100 MHz (divided)
    logic uart_clk;          // 1.8432 MHz (115200*16 baud)
    logic core_rst_n;
    logic sys_rst_n;

    // PLL instantiation (TSMC N3 PLL hard macro)
    // In actual design: TSMC N3 PLL_LVT macro
    // Parameters: Fref=25MHz, Fvco=4.8GHz, Fout=1.2GHz (divide by 4)
    pll #(
        .REF_FREQ     (64'd25_000_000),
        .VCO_FREQ     (64'd4_800_000_000),
        .OUT_DIV      (4),
        .SYS_DIV      (48),
        .UART_DIV     (2600)
    ) u_pll (
        .clk_ref     (xtal_in),
        .rst_n       (rst_ext_n),
        .core_clk    (core_clk),
        .sys_clk     (sys_clk),
        .uart_clk    (uart_clk),
        .locked      (pll_lock)
    );

    always_ff @(posedge core_clk or negedge pll_lock) begin
        if (!pll_lock)
            core_rst_n <= 1'b0;
        else
            core_rst_n <= 1'b1;
    end

    always_ff @(posedge sys_clk or negedge pll_lock) begin
        if (!pll_lock)
            sys_rst_n <= 1'b0;
        else
            sys_rst_n <= 1'b1;
    end

    // ─── UART Interface ───

    logic        uart_rx_valid;
    logic [7:0]  uart_rx_data;
    logic        uart_tx_ready;
    logic        uart_tx_valid;
    logic [7:0]  uart_tx_data;

    uart u_uart (
        .clk        (sys_clk),
        .rst_n      (sys_rst_n),
        .baud_clk   (uart_clk),
        .rx         (uart_rx),
        .tx         (uart_tx),
        .rx_valid   (uart_rx_valid),
        .rx_data    (uart_rx_data),
        .tx_ready   (uart_tx_ready),
        .tx_valid   (uart_tx_valid),
        .tx_data    (uart_tx_data)
    );

    // ─── Protocol Parser ───

    // UART protocol for job submission:
    //   Byte 0:      0xA5 (magic)
    //   Byte 1:      0x01 (cmd: job) / 0x02 (cmd: status req)
    //   Bytes 2-81:  header (80 bytes)
    //   Bytes 82-113: target (32 bytes)
    //   Byte 114:     checksum (XOR of all preceding)
    //
    // Response protocol:
    //   Byte 0:      0x5A (magic)
    //   Byte 1:      0x01 (found share) / 0x02 (status)
    //   Bytes 2-33:  hash (32 bytes)
    //   Bytes 34-37: nonce (4 bytes)
    //   Byte 38:     checksum

    logic        new_job;
    logic [639:0] header_sys;
    logic [255:0] target_sys;
    logic [7:0]  parser_state;
    logic [10:0] byte_cnt;
    logic [7:0]  packet_buf [0:113];
    logic [7:0]  packet_cksum;

    // Parser FSM, sys_clk domain.
    //
    // CDC discipline:
    //   1. State 2 (last byte of payload): if checksum passes, write
    //      header_sys/target_sys directly from packet_buf and advance to
    //      state 3. new_job stays low.
    //   2. State 3: header_sys/target_sys have now been stable for one
    //      sys_clk cycle. Pulse new_job high for one sys_clk cycle.
    //   3. The core_clk side runs a 2-FF synchroniser on new_job and
    //      samples header_sys/target_sys into core_clk registers on the
    //      synchronised rising edge. Because header_sys was already stable
    //      one sys_clk cycle before new_job rose, it has been stable for
    //      ~1 sys_clk + a few core_clk cycles by the time the sample
    //      happens -- well above any FF setup time.
    always_ff @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            parser_state <= '0;
            byte_cnt     <= '0;
            new_job      <= 1'b0;
            header_sys   <= '0;
            target_sys   <= '0;
            packet_cksum <= '0;
        end else begin
            new_job <= 1'b0;

            case (parser_state)
                0: begin  // wait for magic 0xA5
                    if (uart_rx_valid && uart_rx_data == 8'hA5) begin
                        parser_state <= 1;
                        byte_cnt     <= 0;
                        packet_cksum <= 8'hA5;
                    end
                end

                1: begin  // read command byte
                    if (uart_rx_valid) begin
                        packet_buf[0] <= uart_rx_data;
                        packet_cksum  <= packet_cksum ^ uart_rx_data;
                        byte_cnt      <= 1;
                        parser_state  <= (uart_rx_data == 8'h01) ? 2 : 0;
                    end
                end

                2: begin  // read payload (header + target)
                    if (uart_rx_valid) begin
                        packet_buf[byte_cnt] <= uart_rx_data;
                        packet_cksum <= packet_cksum ^ uart_rx_data;
                        if (byte_cnt == 113) begin
                            // Verify checksum. Parenthesise the XOR explicitly:
                            // SystemVerilog `==` binds tighter than binary `^`,
                            // so without the parens this would parse as
                            // `packet_cksum ^ (uart_rx_data == 8'h00)` and
                            // accept/reject the wrong packets.
                            if ((packet_cksum ^ uart_rx_data) == 8'h00) begin
                                // Write header/target directly. new_job is
                                // NOT asserted here; we delay one cycle so
                                // header_sys/target_sys are stable before
                                // the sync'd rising edge reaches core_clk.
                                for (int i = 0; i < 80; i++)
                                    header_sys[(79-i)*8 +: 8] <= packet_buf[1 + i];
                                for (int i = 0; i < 32; i++)
                                    target_sys[(31-i)*8 +: 8] <= packet_buf[81 + i];
                                parser_state <= 3;
                            end else begin
                                parser_state <= 0;
                            end
                        end else begin
                            byte_cnt <= byte_cnt + 11'd1;
                        end
                    end
                end

                3: begin  // header_sys/target_sys stable for one sys_clk
                    new_job      <= 1'b1;
                    parser_state <= 0;
                end

                default: parser_state <= 0;
            endcase
        end
    end

    // ─── Job Synchronization (sys_clk → core_clk) ───

    logic         new_job_core;
    logic [639:0] header_core;
    logic [255:0] target_core;

    logic         new_job_sync1, new_job_sync2;
    logic         new_job_pulse;

    always_ff @(posedge core_clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            new_job_sync1 <= 1'b0;
            new_job_sync2 <= 1'b0;
            new_job_pulse <= 1'b0;
        end else begin
            new_job_sync1 <= new_job;
            new_job_sync2 <= new_job_sync1;
            new_job_pulse <= new_job_sync1 && !new_job_sync2;
        end
    end

    // Sample header_sys/target_sys into core_clk registers when the
    // synchroniser fires. The sys_clk parser FSM guarantees these signals
    // are stable for >= 1 sys_clk cycle before new_job rises, so by the
    // time the synchroniser asserts new_job_pulse they have been stable
    // for many core_clk cycles.
    always_ff @(posedge core_clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            header_core <= '0;
            target_core <= '0;
        end else if (new_job_pulse) begin
            header_core <= header_sys;
            target_core <= target_sys;
        end
    end

    assign new_job_core = new_job_pulse;

    // ─── Core Array ───

    // Nonce manager
    logic        nm_job_valid;
    logic [CORE_ID_W-1:0] nm_core_id;
    logic [639:0] nm_header;
    logic [255:0] nm_target;
    logic [31:0]  nm_nonce_base;

    logic [N_CORES-1:0]  core_idle;
    logic [N_CORES-1:0]  core_found;
    logic [31:0]         core_found_nonce [N_CORES-1:0];
    logic [255:0]        core_found_hash  [N_CORES-1:0];

    logic        nm_result_valid;
    logic [31:0] nm_result_nonce;
    logic [255:0] nm_result_hash;

    nonce_manager #(
        .N_CORES(N_CORES),
        .NONCES_PER_CORE(NONCES_PER_CORE),
        .CORE_ID_W(CORE_ID_W)
    ) u_nonce_mgr (
        .clk              (core_clk),
        .rst_n            (core_rst_n),
        .new_job          (new_job_core),
        .header           (header_core),
        .target           (target_core),
        .job_valid        (nm_job_valid),
        .job_core_id      (nm_core_id),
        .job_header       (nm_header),
        .job_target       (nm_target),
        .job_nonce_base   (nm_nonce_base),
        .core_idle        (core_idle),
        .core_found       (core_found),
        .core_found_nonce (core_found_nonce),
        .core_found_hash  (core_found_hash),
        .result_fifo_full (result_cdc_full),
        .result_valid     (nm_result_valid),
        .result_nonce     (nm_result_nonce),
        .result_hash      (nm_result_hash),
        .total_hashes     (),
        .shares_found     ()
    );

    // ─── Scrypt Core Instances ───
    // In synthesis: use generate loop, but with 4096 instances this creates
    // huge elaboration overhead. For a production design, cores are instantiated
    // via a tiling script or array binding.
    //
    // Each core interface:
    //   core_clk, core_rst_n
    //   job_valid, header, target, nonce_base
    //   busy (idle = ~busy)
    //   found_valid, found_nonce, found_hash

    // Job distribution demux
    logic [N_CORES-1:0]        core_job_valid;
    logic [N_CORES-1:0][31:0]  core_nonce;
    logic [N_CORES-1:0]        core_busy;

    genvar c;
    generate
        for (c = 0; c < N_CORES; c++) begin : gen_cores
            logic        local_job_valid;
            logic [31:0] local_nonce;

            // Demux valid signal to target core
            assign local_job_valid = nm_job_valid && (nm_core_id == CORE_ID_W'(c));

            // Latch nonce and target for the core when assigned
            always_ff @(posedge core_clk) begin
                if (local_job_valid)
                    core_nonce[c] <= nm_nonce_base;
            end

            scrypt_core u_core (
                .clk          (core_clk),
                .rst_n        (core_rst_n),
                .job_valid    (local_job_valid),
                .header       (nm_header),
                .target       (nm_target),
                .nonce_base   (core_nonce[c]),
                .nonce_range  (NONCES_PER_CORE),
                .found_valid  (core_found[c]),
                .found_nonce  (core_found_nonce[c]),
                .found_hash   (core_found_hash[c]),
                .busy         (core_busy[c]),
                .nonces_done  (),
                .cycle_count  ()
            );

            assign core_idle[c] = !core_busy[c] && !local_job_valid;
        end
    endgenerate

    // ─── Result CDC (core_clk → sys_clk) ───

    // CDC FIFO for found results
    // Write: core_clk domain, Read: sys_clk domain
    // Depth: 16 entries (sufficient for any burst of found shares)

    logic        result_cdc_wr, result_cdc_rd;
    logic [287:0] result_cdc_wdata, result_cdc_rdata;  // {hash[255:0], nonce[31:0]}
    logic        result_cdc_empty, result_cdc_full;

    // Simple sync FIFO (2-port, async clocks).
    //
    // Belt-and-braces: the nonce_manager already gates `nm_result_valid`
    // on !result_cdc_full, but we AND it again here so that even if the
    // back-pressure path inside nonce_manager regressed in the future, a
    // full FIFO can never accept a write (and silently drop a share).
    sync_fifo #(
        .DWIDTH(288),
        .DEPTH (16)
    ) u_result_fifo (
        .wr_clk   (core_clk),
        .wr_rst_n (core_rst_n),
        .wr_en    (nm_result_valid && !result_cdc_full),
        .wr_data  ({nm_result_hash, nm_result_nonce}),
        .full     (result_cdc_full),

        .rd_clk   (sys_clk),
        .rd_rst_n (sys_rst_n),
        .rd_en    (result_cdc_rd),
        .rd_data  (result_cdc_rdata),
        .empty    (result_cdc_empty)
    );

    assign result_cdc_rd = !result_cdc_empty && uart_tx_ready;

    // ─── Response Transmitter ───

    typedef enum logic [1:0] {
        TX_IDLE,
        TX_PREAMBLE,
        TX_PAYLOAD,
        TX_CHECKSUM
    } tx_state_t;

    tx_state_t  tx_state;
    logic [5:0] tx_byte_cnt;
    logic [7:0] tx_cksum;        // Running XOR checksum across the response packet.

    // Response framing (sent on each share found):
    //   Byte 0:     0x5A           (magic)
    //   Byte 1:     0x01           (cmd: found share)
    //   Bytes 2-33: hash (32 bytes, byte 0 first)
    //   Bytes 34-37: nonce (4 bytes, little-endian: LSB first)
    //   Byte 38:    XOR checksum of bytes 0..37

    always_ff @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            tx_state      <= TX_IDLE;
            tx_byte_cnt   <= '0;
            tx_cksum      <= '0;
            uart_tx_valid <= 1'b0;
            uart_tx_data  <= '0;
        end else begin
            uart_tx_valid <= 1'b0;

            case (tx_state)
                TX_IDLE: begin
                    if (!result_cdc_empty && uart_tx_ready) begin
                        tx_state    <= TX_PREAMBLE;
                        tx_byte_cnt <= 6'd1;
                        tx_cksum    <= 8'h00;
                    end
                end

                TX_PREAMBLE: begin
                    if (uart_tx_ready) begin
                        // Only assert tx_valid in the branches that actually
                        // produce a byte; the transition branch leaves
                        // uart_tx_valid at its default of 0 so the UART
                        // does not see a phantom byte (issue #30).
                        case (tx_byte_cnt)
                            6'd1: begin
                                uart_tx_valid <= 1'b1;
                                uart_tx_data  <= 8'h5A;
                                tx_cksum      <= tx_cksum ^ 8'h5A;
                                tx_byte_cnt   <= 6'd2;
                            end
                            6'd2: begin
                                uart_tx_valid <= 1'b1;
                                uart_tx_data  <= 8'h01;
                                tx_cksum      <= tx_cksum ^ 8'h01;
                                tx_byte_cnt   <= 6'd3;
                            end
                            default: begin
                                tx_state    <= TX_PAYLOAD;
                                tx_byte_cnt <= 6'd0;
                            end
                        endcase
                    end
                end

                TX_PAYLOAD: begin
                    if (uart_tx_ready) begin
                        // Hash bytes 0..31: result_cdc_rdata holds
                        // {hash[255:0], nonce[31:0]}, so byte 0 of the hash
                        // (= hash[255:248]) is at result_cdc_rdata[287:280].
                        // Indexing from bit 287 walks down through the hash.
                        if (tx_byte_cnt < 32) begin
                            uart_tx_valid <= 1'b1;
                            uart_tx_data  <= result_cdc_rdata[287 - tx_byte_cnt*8 -: 8];
                            tx_cksum      <= tx_cksum ^ result_cdc_rdata[287 - tx_byte_cnt*8 -: 8];
                            tx_byte_cnt   <= tx_byte_cnt + 6'd1;
                        // Nonce bytes (LE): byte 0 = nonce[7:0] = result_cdc_rdata[7:0],
                        // byte 3 = nonce[31:24] = result_cdc_rdata[31:24].
                        end else if (tx_byte_cnt < 36) begin
                            uart_tx_valid <= 1'b1;
                            uart_tx_data  <= result_cdc_rdata[(tx_byte_cnt-32)*8 +: 8];
                            tx_cksum      <= tx_cksum ^ result_cdc_rdata[(tx_byte_cnt-32)*8 +: 8];
                            tx_byte_cnt   <= tx_byte_cnt + 6'd1;
                        end else begin
                            // Transition only; no byte to send this cycle.
                            tx_state    <= TX_CHECKSUM;
                            tx_byte_cnt <= 6'd0;
                        end
                    end
                end

                TX_CHECKSUM: begin
                    if (uart_tx_ready) begin
                        uart_tx_valid <= 1'b1;
                        uart_tx_data  <= tx_cksum;
                        tx_state      <= TX_IDLE;
                    end
                end

                default: tx_state <= TX_IDLE;
            endcase
        end
    end

    // ─── Status monitoring ───

    assign led_green = pll_lock;
    assign led_red   = !pll_lock;

endmodule
