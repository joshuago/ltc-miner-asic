// Simple UART (TX only)
// Configurable baud rate via baud_clk input (16x baud rate)
// 8 data bits, no parity, 1 stop bit (8N1)

module uart (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        baud_clk,       // 16x baud rate

    input  logic        rx,
    output logic        tx,

    output logic        rx_valid,
    output logic [7:0]  rx_data,

    input  logic        tx_ready,
    input  logic        tx_valid,
    input  logic [7:0]  tx_data
);

    // ─── TX ───
    typedef enum logic [1:0] {
        TX_IDLE,
        TX_START,
        TX_DATA,
        TX_STOP
    } tx_state_t;

    tx_state_t tx_state;
    logic [3:0] tx_bit_cnt;
    logic [3:0] tx_clk_cnt;
    logic [7:0] tx_shift;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_state   <= TX_IDLE;
            tx_bit_cnt <= '0;
            tx_clk_cnt <= '0;
            tx_shift   <= '0;
            tx         <= 1'b1;
        end else begin
            tx_clk_cnt <= tx_clk_cnt + 4'd1;

            case (tx_state)
                TX_IDLE: begin
                    tx <= 1'b1;
                    if (tx_valid && tx_ready) begin
                        tx_shift   <= tx_data;
                        tx_bit_cnt <= '0;
                        tx_clk_cnt <= '0;
                        tx_state   <= TX_START;
                    end
                end

                TX_START: begin
                    tx <= 1'b0;  // start bit
                    if (tx_clk_cnt == 4'd15) begin
                        tx_clk_cnt <= '0;
                        tx_bit_cnt <= '0;
                        tx_state   <= TX_DATA;
                    end
                end

                TX_DATA: begin
                    tx <= tx_shift[tx_bit_cnt];
                    if (tx_clk_cnt == 4'd15) begin
                        tx_clk_cnt <= '0;
                        if (tx_bit_cnt == 4'd7) begin
                            tx_state <= TX_STOP;
                        end else begin
                            tx_bit_cnt <= tx_bit_cnt + 4'd1;
                        end
                    end
                end

                TX_STOP: begin
                    tx <= 1'b1;  // stop bit
                    if (tx_clk_cnt == 4'd15) begin
                        tx_state <= TX_IDLE;
                    end
                end

                default: tx_state <= TX_IDLE;
            endcase
        end
    end

    assign tx_ready = (tx_state == TX_IDLE);

    // ─── RX ───
    typedef enum logic [1:0] {
        RX_IDLE,
        RX_START,
        RX_DATA,
        RX_STOP
    } rx_state_t;

    rx_state_t rx_state;
    logic [3:0] rx_bit_cnt;
    logic [3:0] rx_clk_cnt;
    logic [7:0] rx_shift;
    logic       rx_sync1, rx_sync2;

    // Synchronize rx
    always_ff @(posedge clk) begin
        rx_sync1 <= rx;
        rx_sync2 <= rx_sync1;
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
                    if (!rx_sync2) begin  // start bit detected
                        rx_state   <= RX_START;
                        rx_clk_cnt <= 4'd8;  // sample in middle of start bit
                    end
                end

                RX_START: begin
                    rx_clk_cnt <= rx_clk_cnt + 4'd1;
                    if (rx_clk_cnt == 4'd15) begin
                        rx_clk_cnt <= '0;
                        rx_bit_cnt <= '0;
                        rx_state   <= RX_DATA;
                    end
                end

                RX_DATA: begin
                    rx_clk_cnt <= rx_clk_cnt + 4'd1;
                    // Sample at mid-bit (count = 8)
                    if (rx_clk_cnt == 4'd8)
                        rx_shift[rx_bit_cnt] <= rx_sync2;
                    if (rx_clk_cnt == 4'd15) begin
                        rx_clk_cnt <= '0;
                        if (rx_bit_cnt == 4'd7) begin
                            rx_state <= RX_STOP;
                        end else begin
                            rx_bit_cnt <= rx_bit_cnt + 4'd1;
                        end
                    end
                end

                RX_STOP: begin
                    rx_clk_cnt <= rx_clk_cnt + 4'd1;
                    if (rx_clk_cnt == 4'd15) begin
                        rx_valid <= 1'b1;
                        rx_data  <= rx_shift;
                        rx_state <= RX_IDLE;
                    end
                end

                default: rx_state <= RX_IDLE;
            endcase
        end
    end

endmodule
