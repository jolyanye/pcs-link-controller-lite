module cdc_fifo #(
    parameter DATA_WIDTH = 10,
    parameter ADDR_WIDTH = 2
)(
    // Write domain (system clk)
    input wire clk_wr,
    input wire rst_n_wr,
    input wire wr_en, // from encoder when data valid
    input wire [DATA_WIDTH-1:0] data_in,
    output wire full,

    // Read domain (link clk)
    input wire clk_rd,
    input wire rst_n_rd,
    input wire rd_en, // from serializer when it needs data
    output wire [DATA_WIDTH-1:0] data_out,
    output wire empty
);

    // Internal memory and pointers
    reg [DATA_WIDTH-1:0] mem [0:(1<<ADDR_WIDTH)-1];  // memory array with 4 slots
    reg [ADDR_WIDTH:0] wr_ptr_bin, wr_ptr_gray;
    reg [ADDR_WIDTH:0] rd_ptr_bin, rd_ptr_gray;
    
    // Synchronizers
    reg [ADDR_WIDTH:0] wr_ptr_gray_sync1, wr_ptr_gray_sync2;
    reg [ADDR_WIDTH:0] rd_ptr_gray_sync1, rd_ptr_gray_sync2;

    // **********************
    // Write domain logic
    // **********************
    wire [ADDR_WIDTH:0] wr_ptr_bin_next = wr_ptr_bin + (wr_en && !full ? 1 : 0);
    wire [ADDR_WIDTH:0] wr_ptr_gray_next = wr_ptr_bin_next ^ (wr_ptr_bin_next >> 1);

    always @(posedge clk_wr or negedge rst_n_wr) begin
        if (!rst_n_wr) begin
            wr_ptr_bin <= 0;
            wr_ptr_gray <= 0;
        end else begin
            wr_ptr_bin <= wr_ptr_bin_next;
            wr_ptr_gray <= wr_ptr_gray_next;
        end
    end

    // Write data to memory array
    always @(posedge clk_wr) begin
        if (wr_en && !full)
            mem[wr_ptr_bin[ADDR_WIDTH-1:0]] <= data_in;
    end

    // **********************
    // Read pointer logic
    // **********************
    wire [ADDR_WIDTH:0] rd_ptr_bin_next = rd_ptr_bin + (rd_en && !empty ? 1 : 0);
    wire [ADDR_WIDTH:0] rd_ptr_gray_next = rd_ptr_bin_next ^ (rd_ptr_bin_next >> 1);

    always @(posedge clk_rd or negedge rst_n_rd) begin
        if (!rst_n_rd) begin
            rd_ptr_bin <= 0;
            rd_ptr_gray <= 0;
        end else begin
            rd_ptr_bin <= rd_ptr_bin_next;
            rd_ptr_gray <= rd_ptr_gray_next;
        end
    end

    // Read data from memory array
    assign data_out = mem[rd_ptr_bin[ADDR_WIDTH-1:0]];

    // **********************
    // Two-stage synchronizers for both write and read pointers
    // **********************
    always @(posedge clk_rd or negedge rst_n_rd) begin
        if (!rst_n_rd) begin
            wr_ptr_gray_sync1 <= 0;
            wr_ptr_gray_sync2 <= 0;
        end else begin
            wr_ptr_gray_sync1 <= wr_ptr_gray;
            wr_ptr_gray_sync2 <= wr_ptr_gray_sync1;
        end
    end

    always @(posedge clk_wr or negedge rst_n_wr) begin
        if (!rst_n_wr) begin
            rd_ptr_gray_sync1 <= 0;
            rd_ptr_gray_sync2 <= 0;
        end else begin
            rd_ptr_gray_sync1 <= rd_ptr_gray;
            rd_ptr_gray_sync2 <= rd_ptr_gray_sync1;
        end
    end

    // **********************
    // Full & empty logic
    // **********************
    assign full = (wr_ptr_gray == {~rd_ptr_gray_sync2[ADDR_WIDTH:ADDR_WIDTH-1], rd_ptr_gray_sync2[ADDR_WIDTH-2:0]});
    assign empty = (rd_ptr_gray == wr_ptr_gray_sync2);

endmodule