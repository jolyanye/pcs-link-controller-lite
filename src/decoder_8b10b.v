module decoder_8b10b (
    input wire clk,
    input wire rst_n,
    input wire [9:0] data_in,
    input wire rd_en,
    output reg [7:0] data_out,
    output reg valid_out
);

    // Intermediate values
    wire [5:0] data_6b = data_in[5:0];
    wire [3:0] data_4b = data_in[9:6];

    reg [4:0] decoded_5b;
    reg [2:0] decoded_3b;
    reg decode_err_6b;
    reg decode_err_4b;
    reg decode_err;

    // **********************
    // 6b/5b conversion LUT
    // **********************
    always @(*) begin
        decode_err_6b = 1'b0;
        case (data_6b)
            6'b011000, 6'b100111: decoded_5b = 5'd0;
            6'b100010, 6'b011101: decoded_5b = 5'd1;
            6'b010010, 6'b101101: decoded_5b = 5'd2;
            6'b110001:             decoded_5b = 5'd3;
            6'b001010, 6'b110101: decoded_5b = 5'd4;
            6'b101001:             decoded_5b = 5'd5;
            6'b011001:             decoded_5b = 5'd6;
            6'b000111, 6'b111000: decoded_5b = 5'd7;
            6'b000110, 6'b111001: decoded_5b = 5'd8;
            6'b100101:             decoded_5b = 5'd9;
            6'b010101:             decoded_5b = 5'd10;
            6'b110100:             decoded_5b = 5'd11;
            6'b001101:             decoded_5b = 5'd12;
            6'b101100:             decoded_5b = 5'd13;
            6'b011100:             decoded_5b = 5'd14;
            6'b101000, 6'b010111: decoded_5b = 5'd15;
            6'b100100, 6'b011011: decoded_5b = 5'd16;
            6'b100011:             decoded_5b = 5'd17;
            6'b010011:             decoded_5b = 5'd18;
            6'b110010:             decoded_5b = 5'd19;
            6'b001011:             decoded_5b = 5'd20;
            6'b101010:             decoded_5b = 5'd21;
            6'b011010:             decoded_5b = 5'd22;
            6'b000101, 6'b111010: decoded_5b = 5'd23;
            6'b001100, 6'b110011: decoded_5b = 5'd24;
            6'b100110:             decoded_5b = 5'd25;
            6'b010110:             decoded_5b = 5'd26;
            6'b001001, 6'b110110: decoded_5b = 5'd27;
            6'b001110:             decoded_5b = 5'd28;
            6'b010001, 6'b101110: decoded_5b = 5'd29;
            6'b100001, 6'b011110: decoded_5b = 5'd30;
            6'b010100, 6'b101011: decoded_5b = 5'd31;
            // K28.5 (Comma) Special Case
            6'b001111, 6'b110000: decoded_5b = 5'd28; 
            default: begin decoded_5b = 5'd0; decode_err_6b = 1'b1; end
        endcase
    end

    // **********************
    // 4b/3b conversion LUT
    // **********************
    always @(*) begin
        decode_err_4b = 1'b0;
        case (data_4b)
            4'b0100, 4'b1011: decoded_3b = 3'd0;
            4'b1001:          decoded_3b = 3'd1;
            4'b0101:          decoded_3b = 3'd2;
            4'b0011, 4'b1100: decoded_3b = 3'd3;
            4'b0010, 4'b1101: decoded_3b = 3'd4;
            4'b1010:          decoded_3b = 3'd5;
            4'b0110:          decoded_3b = 3'd6;
            4'b0001, 4'b1110: decoded_3b = 3'd7;
            default: begin decoded_3b = 3'd0; decode_err_4b = 1'b1; end
        endcase

        // K28.5 (Comma) Special Case
        if ((data_6b == 6'b001111 || data_6b == 6'b110000) && (data_4b == 4'b0101 || data_4b == 4'b1010)) begin
            decoded_3b = 3'd5;
            decode_err_4b = 1'b0; 
        end
    end

    // **********************
    // Output logic
    // **********************
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_out <= 8'b0;
            valid_out <= 1'b0;
            decode_err <= 1'b0;
        end else begin
            if (rd_en && !(decode_err_6b || decode_err_4b)) begin
                data_out <= {decoded_3b, decoded_5b};
                decode_err <= decode_err_6b || decode_err_4b;
                valid_out <= 1'b1;
            end else begin
                decode_err <= 1'b0;
                valid_out <= 1'b0;
            end
        end
    end

endmodule