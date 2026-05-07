module ltssm_arbiter (
    input wire clk,
    input wire rst_n,
    input wire rx_req,
    input wire tx_valid,
    input wire tx_fifo_full,
    input wire rx_fifo_empty,
    output reg rx_ack,
    output reg occupied,
    output reg tx_en,
    output reg rx_rd_en,
    output reg bus_dir, // 0: TX, 1: RX
    output reg flush
);

    // **********************
    // State encoding
    // **********************
    localparam STATE_TX = 2'b00;
    localparam STATE_RX = 2'b01;
    localparam STATE_DRAIN = 2'b10; // Used when switching from RX -> TX - finish draining RX FIFO before allowing TX to take over
    localparam STATE_FLUSH = 2'b11; // TX -> Flush -> RX or RX -> Drain -> Flush -> TX, reset all components

    reg [1:0] state, next_state;

    // **********************
    // Next state logic
    // **********************
    always @(*) begin
        case (state)
            STATE_TX: begin
                if (rx_req) next_state = STATE_FLUSH;
                else next_state = STATE_TX;
            end
            STATE_RX: begin
                if (!rx_req) next_state = STATE_DRAIN;
                else next_state = STATE_RX;
            end
            STATE_DRAIN: begin
                if (rx_fifo_empty) next_state = STATE_FLUSH;
                else next_state = STATE_DRAIN;
            end
            STATE_FLUSH: begin
                if (!rx_req) next_state = STATE_TX;
                else next_state = STATE_RX;
            end
            default: next_state = STATE_TX;
        endcase
    end

    // **********************
    // State transition
    // **********************
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= STATE_TX;
        end else begin
            state <= next_state;
        end
    end

    // **********************
    // Output logic
    // **********************
    always @(*) begin
        // Default values
        tx_en = 1'b0;
        rx_rd_en = 1'b0;
        bus_dir = 1'b0; // Default to TX
        flush = 1'b0;
        rx_ack = 1'b0;
        occupied = 1'b0;

        case (state)
            STATE_TX: begin
                tx_en = !tx_fifo_full && tx_valid;
                bus_dir = 1'b0;
                rx_ack = 1'b0;
                occupied = 1'b0;
            end
            STATE_RX: begin
                rx_rd_en = !rx_fifo_empty;
                bus_dir = 1'b1;
                rx_ack = 1'b1;
                occupied = 1'b0;
            end
            STATE_DRAIN: begin
				rx_rd_en = !rx_fifo_empty;
                tx_en = 1'b0;
                bus_dir = 1'b1;
                rx_ack = 1'b0;
                occupied = 1'b1;
            end
            STATE_FLUSH: begin
                flush = 1'b1;
                occupied = 1'b1;
            end
        endcase
    end

endmodule