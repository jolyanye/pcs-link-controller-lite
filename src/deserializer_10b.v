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
    reg [1:0] lock_count; 
    reg comma_det;

    reg [3:0] run_length;
    reg last_bit;

    localparam COMMA_N = 10'b0101111100; // RD- Comma LSB-first
    localparam COMMA_P = 10'b1010000011; // RD+ Comma LSB-first

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
            run_length <= 4'd0;
            last_bit <= 1'b0;
        end else begin
            shift_reg <= current_word;
            comma_det <= 1'b0;
            wr_en <= 1'b0;

            // Track Consecutive Identical Bits
            if (serial_in == last_bit) begin
                if (run_length < 4'd15) run_length <= run_length + 1'b1;
            end else begin
                run_length <= 4'd1;
                last_bit <= serial_in;
            end

            if (!link_lock) begin
                // HUNT MODE
                if (is_comma) begin
                    comma_det <= 1'b1;
                    bit_cnt <= 4'd0;

                    if (lock_count == 2'd0) begin
                        // First comma found, lock onto this alignment phase
                        lock_count <= 2'd1;
                    end else if (bit_cnt == 4'd9) begin
                        if (lock_count == 2'd3) begin
                            link_lock <= 1'b1; // 4th aligned comma - LOCKED
                        end else begin
                            lock_count <= lock_count + 1'b1; 
                        end
                    end else begin
                        // Unaligned comma found - lost the previous alignment
                        // Restart the hunt
                        lock_count <= 2'd1;
                    end
                end else begin
                    if (bit_cnt == 4'd9) begin
                        bit_cnt <= 4'd0;
                        lock_count <= 2'd0; 
                    end else begin
                        bit_cnt <= bit_cnt + 1'b1;
                    end
                end
            end else begin
                // LOCKED MODE + Loss of Lock Detection
                if ((is_comma && bit_cnt != 4'd9) || (run_length > 4'd6)) begin
                    link_lock <= 1'b0;
                    lock_count <= 2'd0;
                    bit_cnt <= 4'd0;
                end else if (bit_cnt == 4'd9) begin
                    bit_cnt <= 4'd0;
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