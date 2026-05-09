module deserializer_10b (
    input wire clk,  // Link clock
    input wire rst_n,
    input wire serial_in,
    input wire fifo_full,
    output reg [9:0] data_out,
    output reg wr_en,
    output reg link_lock
);

    reg [9:0] shift_reg;
    reg [3:0] bit_cnt;
    reg [1:0] lock_count; // ensure stable comma detection before locking
    reg comma_det;

    localparam COMMA_N = 10'b0101111100; // RD- Comma LSB-first
    localparam COMMA_P = 10'b1010000011; // RD+ Comma LSB-first

    // Combinational look-ahead
    wire [9:0] current_word = {serial_in, shift_reg[9:1]};
    wire is_comma = (current_word == COMMA_P) || (current_word == COMMA_N);

    wire _unused = &{shift_reg, 1'b0};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shift_reg <= 10'b0;
            bit_cnt <= 4'd0;
            data_out <= 10'b0;
            wr_en <= 1'b0;
            comma_det <= 1'b0;
            link_lock <= 1'b0;
            lock_count <= 2'd0;
        end else begin
            shift_reg <= current_word;
            comma_det <= 1'b0;
            wr_en <= 1'b0;

            if (!link_lock) begin
                // HUNT MODE
                if (is_comma) begin
                    bit_cnt <= 4'd0;
                    comma_det <= 1'b1;

                    if (lock_count == 2'd3) begin
                        link_lock <= 1'b1;
                    end else begin
                        lock_count <= lock_count + 1'b1;
                    end
                end else begin
                    if (bit_cnt == 4'd9) begin
                        // 10-bit boundary reached without a comma
                        bit_cnt <= 4'd0;
                        lock_count <= 2'd0;
                    end else begin
                        bit_cnt <= bit_cnt + 1'b1;
                    end
                end
                
            end else begin
                // LOCKED MODE
                if (bit_cnt == 4'd9) begin
                    bit_cnt <= 4'd0;
                    
                    // Only write to FIFO if it's locked, not full, and not an idle comma
                    if (is_comma) begin
                        comma_det <= 1'b1;
                    end else if (!fifo_full) begin
                        wr_en <= 1'b1;
                        data_out <= current_word;
                    end
                end else begin
                    bit_cnt <= bit_cnt + 1'b1;
                end
            end
        end
    end

endmodule