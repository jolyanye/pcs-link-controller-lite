module serializer_10b (
    input wire clk,
    input wire rst_n,
    input wire [9:0] data_in,
    input wire fifo_empty,
    output wire rd_en,
    output wire serial_out
);

    reg [9:0] shift_reg;
    reg [3:0] bit_cnt;

    localparam COMMA_K28_5 = 10'b0101111100; // Standard RD- Comma LSB-first

    assign serial_out = shift_reg[0];
    assign rd_en = (bit_cnt == 4'd9) && !fifo_empty;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shift_reg <= COMMA_K28_5;
            bit_cnt <= 4'd0;
        end else begin
            if (bit_cnt == 4'd8) begin
                bit_cnt <= bit_cnt + 1;
                shift_reg <= {1'b0, shift_reg[9:1]};
            end else if (bit_cnt == 4'd9) begin
                bit_cnt <= 4'd0;
                if (!fifo_empty)
                    shift_reg <= data_in;
                else
                    shift_reg <= COMMA_K28_5;
            end else begin
                shift_reg <= {1'b0, shift_reg[9:1]};
                bit_cnt <= bit_cnt + 1;
            end
        end
    end

endmodule