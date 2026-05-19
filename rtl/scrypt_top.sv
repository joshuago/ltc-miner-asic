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
        .REF_FREQ     (25_000_000),
        .VCO_FREQ     (4_800_000_000),
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
    logic [639:0] job_header;
    logic [255:0] job_target;
    logic [7:0]  parser_state;
    logic [10:0] byte_cnt;
    logic [7:0]  packet_buf [0:113];
    logic [7:0]  packet_cksum;

    always_ff @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            parser_state <= '0;
            byte_cnt     <= '0;
            new_job      <= 1'b0;
            job_header   <= '0;
            job_target   <= '0;
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
                            // Verify checksum
                            if (packet_cksum ^ uart_rx_data == 8'h00) begin
                                // Assemble header and target
                                for (int i = 0; i < 80; i++)
                                    job_header[(79-i)*8 +: 8] <= packet_buf[1 + i];
                                for (int i = 0; i < 32; i++)
                                    job_target[(31-i)*8 +: 8] <= packet_buf[81 + i];
                                new_job <= 1'b1;
                            end
                            parser_state <= 0;
                        end else begin
                            byte_cnt <= byte_cnt + 11'd1;
                        end
                    end
                end

                default: parser_state <= 0;
            endcase
        end
    end

    // ─── Job Synchronization (sys_clk → core_clk) ───

    logic        new_job_core;
    logic [639:0] header_core;
    logic [255:0] target_core;

    // CDC: sys_clk domain → core_clk domain
    // Simple 2-FF synchronizer for single-bit, gray-coded approach for multi-bit
    // For header/target: use dual-clock FIFO or synchronized handshake

    logic        new_job_sync1, new_job_sync2;
    logic        new_job_pulse;

    always_ff @(posedge core_clk) begin
        new_job_sync1 <= new_job;
        new_job_sync2 <= new_job_sync1;
        new_job_pulse <= new_job_sync1 && !new_job_sync2;
    end

    // Register header/target on new_job assertion in sys_clk domain,
    // then use them after the pulse is detected in core_clk domain
    always_ff @(posedge sys_clk) begin
        if (new_job) begin
            header_core <= job_header;
            target_core <= job_target;
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
        .clk            (core_clk),
        .rst_n          (core_rst_n),
        .new_job        (new_job_core),
        .header         (header_core),
        .target         (target_core),
        .job_valid      (nm_job_valid),
        .job_core_id    (nm_core_id),
        .job_header     (nm_header),
        .job_target     (nm_target),
        .job_nonce_base (nm_nonce_base),
        .core_idle      (core_idle),
        .core_found     (core_found),
        .core_found_nonce (core_found_nonce),
        .core_found_hash  (core_found_hash),
        .result_valid   (nm_result_valid),
        .result_nonce   (nm_result_nonce),
        .result_hash    (nm_result_hash),
        .total_hashes   (),
        .shares_found   ()
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

    // Simple sync FIFO (2-port, async clocks)
    sync_fifo #(
        .DWIDTH(288),
        .DEPTH (16)
    ) u_result_fifo (
        .wr_clk   (core_clk),
        .wr_rst_n (core_rst_n),
        .wr_en    (nm_result_valid),
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

    tx_state_t tx_state;
    logic [5:0] tx_byte_cnt;

    always_ff @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            tx_state     <= TX_IDLE;
            tx_byte_cnt  <= '0;
            uart_tx_valid <= 1'b0;
            uart_tx_data  <= '0;
        end else begin
            uart_tx_valid <= 1'b0;

            case (tx_state)
                TX_IDLE: begin
                    if (!result_cdc_empty && uart_tx_ready) begin
                        tx_state    <= TX_PREAMBLE;
                        tx_byte_cnt <= 6'd1;
                    end
                end

                TX_PREAMBLE: begin
                    if (uart_tx_ready) begin
                        uart_tx_valid <= 1'b1;
                        case (tx_byte_cnt)
                            6'd1: uart_tx_data <= 8'h5A;     // magic
                            6'd2: uart_tx_data <= 8'h01;     // cmd: found share
                            default: begin
                                tx_state    <= TX_PAYLOAD;
                                tx_byte_cnt <= 6'd0;
                            end
                        endcase
                        if (tx_byte_cnt < 6'd3)
                            tx_byte_cnt <= tx_byte_cnt + 6'd1;
                    end
                end

                TX_PAYLOAD: begin
                    if (uart_tx_ready) begin
                        uart_tx_valid <= 1'b1;
                        // Send hash (32 bytes) + nonce (4 bytes) = 36 bytes
                        if (tx_byte_cnt < 32) begin
                            uart_tx_data <= result_cdc_rdata[255 - tx_byte_cnt*8 -: 8];
                            tx_byte_cnt  <= tx_byte_cnt + 6'd1;
                        end else if (tx_byte_cnt < 36) begin
                            uart_tx_data <= result_cdc_rdata[287 - (tx_byte_cnt-32)*8 -: 8];
                            tx_byte_cnt  <= tx_byte_cnt + 6'd1;
                        end else begin
                            tx_state    <= TX_CHECKSUM;
                            tx_byte_cnt <= 6'd0;
                        end
                    end
                end

                TX_CHECKSUM: begin
                    if (uart_tx_ready) begin
                        uart_tx_valid <= 1'b1;
                        uart_tx_data  <= tx_byte_cnt; // placeholder cksum
                        tx_state      <= TX_IDLE;
                    end
                end
            endcase
        end
    end

    // ─── Status monitoring ───

    assign led_green = pll_lock;
    assign led_red   = !pll_lock;

endmodule
