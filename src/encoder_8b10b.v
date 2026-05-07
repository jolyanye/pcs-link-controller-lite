module encoder_8b10b (
    input wire clk,
    input wire rst_n,
    input wire tx_en,
    input wire [7:0] data_in,
    input wire k_select,  // 1 = k-code, 0 = d-code
    output reg [9:0] data_out
);

    // Intermediate values
    reg rd; // 0 for negative, 1 for positive
    wire [4:0] data_5b = data_in[4:0];
    wire [2:0] data_3b = data_in[7:5];
    reg [5:0] data_6b;
    reg [3:0] data_4b;
    reg unbalanced_6b;  // 0 = balanced, 1 = unbalanced
    reg unbalanced_4b;
    
    // Determine intermediate RD for the second half of the byte
    wire rd_mid = unbalanced_6b ? ~rd : rd;

    // **********************
    // 5b/6b conversion LUT
    // **********************
    always @(*) begin
        unbalanced_6b = 1'b1; 
        case (data_5b)
            5'd0:  data_6b = (rd == 0) ? 6'b100111 : 6'b011000;
            5'd1:  data_6b = (rd == 0) ? 6'b011101 : 6'b100010;
            5'd2:  data_6b = (rd == 0) ? 6'b101101 : 6'b010010;
            5'd3:  begin data_6b = 6'b110001; unbalanced_6b = 1'b0; end
            5'd4:  data_6b = (rd == 0) ? 6'b110101 : 6'b001010;
            5'd5:  begin data_6b = 6'b101001; unbalanced_6b = 1'b0; end
            5'd6:  begin data_6b = 6'b011001; unbalanced_6b = 1'b0; end
            5'd7:  data_6b = (rd == 0) ? 6'b111000 : 6'b000111;
            5'd8:  data_6b = (rd == 0) ? 6'b111001 : 6'b000110;
            5'd9:  begin data_6b = 6'b100101; unbalanced_6b = 1'b0; end
            5'd10: begin data_6b = 6'b010101; unbalanced_6b = 1'b0; end
            5'd11: begin data_6b = 6'b110100; unbalanced_6b = 1'b0; end
            5'd12: begin data_6b = 6'b001101; unbalanced_6b = 1'b0; end
            5'd13: begin data_6b = 6'b101100; unbalanced_6b = 1'b0; end
            5'd14: begin data_6b = 6'b011100; unbalanced_6b = 1'b0; end
            5'd15: data_6b = (rd == 0) ? 6'b010111 : 6'b101000;
            5'd16: data_6b = (rd == 0) ? 6'b011011 : 6'b100100;
            5'd17: begin data_6b = 6'b100011; unbalanced_6b = 1'b0; end
            5'd18: begin data_6b = 6'b010011; unbalanced_6b = 1'b0; end
            5'd19: begin data_6b = 6'b110010; unbalanced_6b = 1'b0; end
            5'd20: begin data_6b = 6'b001011; unbalanced_6b = 1'b0; end
            5'd21: begin data_6b = 6'b101010; unbalanced_6b = 1'b0; end
            5'd22: begin data_6b = 6'b011010; unbalanced_6b = 1'b0; end
            5'd23: data_6b = (rd == 0) ? 6'b111010 : 6'b000101;
            5'd24: data_6b = (rd == 0) ? 6'b110011 : 6'b001100;
            5'd25: begin data_6b = 6'b100110; unbalanced_6b = 1'b0; end
            5'd26: begin data_6b = 6'b010110; unbalanced_6b = 1'b0; end
            5'd27: data_6b = (rd == 0) ? 6'b110110 : 6'b001001;
            5'd28: begin data_6b = 6'b001110; unbalanced_6b = 1'b0; end
            5'd29: data_6b = (rd == 0) ? 6'b101110 : 6'b010001;
            5'd30: data_6b = (rd == 0) ? 6'b011110 : 6'b100001;
            5'd31: data_6b = (rd == 0) ? 6'b101011 : 6'b010100;
            default: begin data_6b = 6'b000000; unbalanced_6b = 1'b0; end
        endcase

        // K28.5 (Comma) override
        if (k_select && data_5b == 5'd28) begin
            data_6b = (rd == 0) ? 6'b001111 : 6'b110000;
            unbalanced_6b = 1'b1;
        end
    end

    // **********************
    // 3b/4b conversion LUT
    // **********************
    always @(*) begin
        unbalanced_4b = 1'b1;
        case (data_3b)
            3'd0: data_4b = (rd_mid == 0) ? 4'b1011 : 4'b0100;
            3'd1: begin data_4b = 4'b1001; unbalanced_4b = 1'b0; end
            3'd2: begin data_4b = 4'b0101; unbalanced_4b = 1'b0; end
            3'd3: data_4b = (rd_mid == 0) ? 4'b1100 : 4'b0011;
            3'd4: data_4b = (rd_mid == 0) ? 4'b1101 : 4'b0010;
            3'd5: begin data_4b = 4'b1010; unbalanced_4b = 1'b0; end
            3'd6: begin data_4b = 4'b0110; unbalanced_4b = 1'b0; end
            3'd7: begin
                if (rd_mid == 0) data_4b = 4'b1110; 
                else data_4b = 4'b0001;
                unbalanced_4b = 1'b1;
            end
            default: begin data_4b = 4'b0000; unbalanced_4b = 1'b0; end
        endcase

        // K28.5 (Comma) override
        if (k_select && data_5b == 5'd28 && data_3b == 3'd5) begin
            data_4b = (rd == 0) ? 4'b1010 : 4'b0101;
            unbalanced_4b = 1'b0;
        end
    end

    // **********************
    // Output logic
    // **********************
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd <= 1'b0;
            data_out <= 10'b0101111100;
        end else if (tx_en) begin
            rd <= unbalanced_4b ? ~rd_mid : rd_mid;
            data_out <= {data_4b, data_6b};
        end
    end

endmodule