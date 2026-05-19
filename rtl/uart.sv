// Simple UART (8N1)
//
// Clocking:
//   - The entire FSM runs on `clk` (system clock).
//   - `baud_clk` is the 16x-oversample tick (e.g. 16 * 115200 = 1.8432 MHz)
//     produced by the PLL. It is synchronised into the `clk` domain and a
//     1-clk rising-edge pulse (`baud_tick`) is used to advance the bit-time
//     counters. This avoids needing to clock the FSM directly on baud_clk
//     (and the resulting CDC for the data path).
//
// Bit timing:
//   - 16 baud_ticks per bit.
//   - RX samples each data bit at the midpoint (8th tick after the start of
//     the bit). After detecting the start-bit falling edge the receiver
//     waits one full bit period (16 ticks) before entering data sampling,
//     so the first data sample lands ~24 ticks after the edge -- which is
//     mid-bit-0 of the incoming character. The original implementation
//     ignored baud_clk entirely (running counters on `clk`) and sampled
//     ~9 ticks too early; both are fixed here.

module uart (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        baud_clk,       // 16x baud rate

    input  logic        rx,
    output logic        tx,

    output logic        rx_valid,
    output logic [7:0]  rx_data,

    output logic        tx_ready,
    input  logic        tx_valid,
    input  logic [7:0]  tx_data
);

    // ---- baud_clk -> clk edge detector ----
    //
    // Three-FF synchroniser plus rising-edge detect. With sys_clk = 100 MHz
    // and baud_clk ~= 1.84 MHz, baud_tick fires once per ~54 sys_clk cycles.
    logic baud_s1, baud_s2, baud_s3;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            baud_s1 <= 1'b0;
            baud_s2 <= 1'b0;
            baud_s3 <= 1'b0;
        end else begin
            baud_s1 <= baud_clk;
            baud_s2 <= baud_s1;
            baud_s3 <= baud_s2;
        end
    end
    wire baud_tick = baud_s2 && !baud_s3;

    // ---- TX ----
    typedef enum logic [1:0] {
        TX_IDLE,
        TX_START,
        TX_DATA,
        TX_STOP
    } tx_state_t;

    tx_state_t  tx_state;
    logic [2:0] tx_bit_cnt;
    logic [3:0] tx_clk_cnt;
    logic [7:0] tx_shift;

    assign tx_ready = (tx_state == TX_IDLE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_state   <= TX_IDLE;
            tx_bit_cnt <= '0;
            tx_clk_cnt <= '0;
            tx_shift   <= '0;
            tx         <= 1'b1;
        end else begin
            case (tx_state)
                TX_IDLE: begin
                    tx <= 1'b1;
                    if (tx_valid) begin
                        tx_shift   <= tx_data;
                        tx_bit_cnt <= '0;
                        tx_clk_cnt <= '0;
                        tx_state   <= TX_START;
                    end
                end

                TX_START: begin
                    tx <= 1'b0;  // start bit
                    if (baud_tick) begin
                        if (tx_clk_cnt == 4'd15) begin
                            tx_clk_cnt <= '0;
                            tx_state   <= TX_DATA;
                        end else begin
                            tx_clk_cnt <= tx_clk_cnt + 4'd1;
                        end
                    end
                end

                TX_DATA: begin
                    tx <= tx_shift[tx_bit_cnt];  // LSB first
                    if (baud_tick) begin
                        if (tx_clk_cnt == 4'd15) begin
                            tx_clk_cnt <= '0;
                            if (tx_bit_cnt == 3'd7) begin
                                tx_state <= TX_STOP;
                            end else begin
                                tx_bit_cnt <= tx_bit_cnt + 3'd1;
                            end
                        end else begin
                            tx_clk_cnt <= tx_clk_cnt + 4'd1;
                        end
                    end
                end

                TX_STOP: begin
                    tx <= 1'b1;  // stop bit
                    if (baud_tick) begin
                        if (tx_clk_cnt == 4'd15) begin
                            tx_clk_cnt <= '0;
                            tx_state   <= TX_IDLE;
                        end else begin
                            tx_clk_cnt <= tx_clk_cnt + 4'd1;
                        end
                    end
                end

                default: tx_state <= TX_IDLE;
            endcase
        end
    end

    // ---- RX ----
    typedef enum logic [1:0] {
        RX_IDLE,
        RX_START,
        RX_DATA,
        RX_STOP
    } rx_state_t;

    rx_state_t  rx_state;
    logic [2:0] rx_bit_cnt;
    logic [3:0] rx_clk_cnt;
    logic [7:0] rx_shift;
    logic       rx_s1, rx_s2;

    // Synchronise rx into clk domain
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_s1 <= 1'b1;
            rx_s2 <= 1'b1;
        end else begin
            rx_s1 <= rx;
            rx_s2 <= rx_s1;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_state   <= RX_IDLE;
            rx_bit_cnt <= '0;
            rx_clk_cnt <= '0;
            rx_shift   <= '0;
            rx_valid   <= 1'b0;
            rx_data    <= '0;
        end else begin
            rx_valid <= 1'b0;

            case (rx_state)
                RX_IDLE: begin
                    // Falling edge of rx (rx_s2 low) marks the start of the
                    // start bit. Drop straight into RX_START with the
                    // counter at zero so the full 16-tick start bit is
                    // waited out before we enter data sampling.
                    if (!rx_s2) begin
                        rx_state   <= RX_START;
                        rx_clk_cnt <= '0;
                    end
                end

                RX_START: begin
                    // Wait one full bit period (16 baud_ticks). At the end
                    // we are aligned to the start of bit 0.
                    if (baud_tick) begin
                        if (rx_clk_cnt == 4'd15) begin
                            rx_clk_cnt <= '0;
                            rx_bit_cnt <= '0;
                            rx_state   <= RX_DATA;
                        end else begin
                            rx_clk_cnt <= rx_clk_cnt + 4'd1;
                        end
                    end
                end

                RX_DATA: begin
                    // 16 baud_ticks per data bit. Sample at the midpoint
                    // (when rx_clk_cnt transitions to 7, the FF captures
                    // the value at the next baud_tick which is rx_clk_cnt=8
                    // i.e. 9 ticks into the bit -- close enough to centre).
                    if (baud_tick) begin
                        if (rx_clk_cnt == 4'd7) begin
                            rx_shift[rx_bit_cnt] <= rx_s2;  // LSB first
                        end
                        if (rx_clk_cnt == 4'd15) begin
                            rx_clk_cnt <= '0;
                            if (rx_bit_cnt == 3'd7) begin
                                rx_state <= RX_STOP;
                            end else begin
                                rx_bit_cnt <= rx_bit_cnt + 3'd1;
                            end
                        end else begin
                            rx_clk_cnt <= rx_clk_cnt + 4'd1;
                        end
                    end
                end

                RX_STOP: begin
                    // Wait through the stop bit. Could also check rx_s2 == 1
                    // at the midpoint for framing errors; not done here.
                    if (baud_tick) begin
                        if (rx_clk_cnt == 4'd15) begin
                            rx_valid <= 1'b1;
                            rx_data  <= rx_shift;
                            rx_state <= RX_IDLE;
                        end else begin
                            rx_clk_cnt <= rx_clk_cnt + 4'd1;
                        end
                    end
                end

                default: rx_state <= RX_IDLE;
            endcase
        end
    end

endmodule
