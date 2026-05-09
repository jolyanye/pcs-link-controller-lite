module pcs_link_ctrl_top #(
    parameter DATA_WIDTH = 10,
    parameter ADDR_WIDTH = 2
)(
    // Clock/Reset
    input wire clk_sys,
    input wire clk_link,
    input wire rst_n,

    // I/O
    input wire serial_in,
    output wire serial_out,

    // User interface (SPLIT BUS FOR ASIC)
    input  wire [7:0] data_in,
    output wire [7:0] data_out,

    // TX/RX handshake & control
    input wire rx_req,
    input wire tx_valid,
    output wire rx_valid,
    output wire rx_ack,
    output wire occupied,
    output wire link_lock_out,
    output wire tx_fifo_full
);
    // **********************
    // Intermediate signals
    // **********************
    // Control path signals
    wire tx_en;
    wire rx_rd_en;
    wire flush;
    wire bus_dir; // 1 for RX, 0 for TX
    wire tx_ser_rd_en;
    wire rx_deser_wr_en;
    wire tx_fifo_empty;
    wire rx_fifo_empty, rx_fifo_full;

    // Datapath signals
    wire [9:0] tx_enc_data;
    wire [9:0] tx_fifo_data_out;
    wire [9:0] rx_deser_data_out;
    wire [9:0] rx_fifo_data_out;
    wire [7:0] rx_decoded_byte;

    // **********************
    // ASIC-Compatible Bus Logic
    // **********************
    assign data_out = bus_dir ? rx_decoded_byte : 8'b00000000;
    wire [7:0] tx_raw_byte = data_in;

    // **********************
    // LTSSM
    // **********************
    ltssm_arbiter ltssm_inst(
        .clk(clk_sys),
        .rst_n(rst_n),
        .rx_req(rx_req),
        .tx_valid(tx_valid),
        .tx_fifo_full(tx_fifo_full),
        .rx_fifo_empty(rx_fifo_empty),
        .rx_ack(rx_ack),
        .occupied(occupied),
        .tx_en(tx_en),
        .rx_rd_en(rx_rd_en),
        .bus_dir(bus_dir),
        .flush(flush)
    );

    // **********************
    // Transmit Path (LTSSM -> Encoder -> TX FIFO -> Serializer)
    // **********************
    encoder_8b10b encoder(
        .clk(clk_sys),
        .rst_n(rst_n && !flush),
        .tx_en(tx_en),
        .data_in(tx_raw_byte),
        .k_select(1'b0),
        .data_out(tx_enc_data)
    );

     // Wait 1 cycle for the encoder to produce last set of data for fifo
    reg tx_fifo_wr_en;
    always @(posedge clk_sys or negedge rst_n) begin
        if (!rst_n) begin
            tx_fifo_wr_en <= 1'b0;
        end else begin
            tx_fifo_wr_en <= tx_en;
        end
    end

    // **********************
    // THE 8-DEEP SYNCHRONOUS SKID BUFFER (V3)
    // **********************
    wire real_fifo_full;
    reg [9:0] skid_mem [0:7]; // Expanded to an array of 8 slots!
    reg [2:0] skid_wr_ptr;
    reg [2:0] skid_rd_ptr;
    reg [3:0] skid_count;     // Can count from 0 to 8

    // We MUST push data into the skid buffer if the real FIFO is full,
    // OR if the skid buffer is currently draining (count > 0). 
    wire skid_push = tx_fifo_wr_en && (real_fifo_full || skid_count > 0);
    wire skid_pop  = !real_fifo_full && (skid_count > 0);

    always @(posedge clk_sys or negedge rst_n) begin
        if (!rst_n) begin
            skid_count  <= 0;
            skid_wr_ptr <= 0;
            skid_rd_ptr <= 0;
        end else begin
            case ({skid_push, skid_pop})
                2'b10: begin // Push only (Catching Overshoot)
                    skid_mem[skid_wr_ptr] <= tx_enc_data;
                    skid_wr_ptr <= skid_wr_ptr + 1;
                    skid_count <= skid_count + 1;
                end
                2'b01: begin // Pop only (Draining into CDC FIFO)
                    skid_rd_ptr <= skid_rd_ptr + 1;
                    skid_count <= skid_count - 1;
                end
                2'b11: begin // Push and Pop simultaneously
                    skid_mem[skid_wr_ptr] <= tx_enc_data;
                    skid_wr_ptr <= skid_wr_ptr + 1;
                    skid_rd_ptr <= skid_rd_ptr + 1;
                end
                default: ; 
            endcase
        end
    end

    // Mux the Skid Buffer into the real CDC FIFO
    wire cdc_wr_en     = (skid_count > 0) ? 1'b1 : tx_fifo_wr_en;
    wire [9:0] cdc_din = (skid_count > 0) ? skid_mem[skid_rd_ptr] : tx_enc_data;

    cdc_fifo #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) tx_cdc_fifo (
        // Write side
        .clk_wr(clk_sys),
        .rst_n_wr(rst_n && !flush),
        .wr_en(cdc_wr_en),        
        .data_in(cdc_din),        
        .full(real_fifo_full),    
        
        // Read side
        .clk_rd(clk_link),
        .rst_n_rd(rst_n && !flush),
        .rd_en(tx_ser_rd_en),
        .data_out(tx_fifo_data_out),
        .empty(tx_fifo_empty)
    );

    // Assert full to the testbench if the real FIFO is full, OR if our skid buffer has caught anything.
    assign tx_fifo_full = real_fifo_full | (skid_count > 0);

    serializer_10b serializer(
        .clk(clk_link),
        .rst_n(rst_n),
        .data_in(tx_fifo_data_out),
        .fifo_empty(tx_fifo_empty),
        .rd_en(tx_ser_rd_en),
        .serial_out(serial_out)
    );

    // **********************
    // Receive Path (Deserializer -> RX FIFO -> Decoder -> LTSSM)
    // **********************
    deserializer_10b deserializer(
        .clk(clk_link),
        .rst_n(rst_n),
        .serial_in(serial_in),
        .fifo_full(rx_fifo_full),
        .data_out(rx_deser_data_out),
        .wr_en(rx_deser_wr_en),
        .link_lock(link_lock_out)
    );

    cdc_fifo #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) rx_cdc_fifo (
        // Write side
        .clk_wr(clk_link),
        .rst_n_wr(rst_n && !flush),
        .wr_en(rx_deser_wr_en),
        .data_in(rx_deser_data_out),
        .full(rx_fifo_full),

        // Read side
        .clk_rd(clk_sys),
        .rst_n_rd(rst_n && !flush),
        .rd_en(rx_rd_en),
        .data_out(rx_fifo_data_out),
        .empty(rx_fifo_empty)
    );

    decoder_8b10b decoder(
        .clk(clk_sys),
        .rst_n(rst_n && !flush),
        .data_in(rx_fifo_data_out),
        .rd_en(rx_rd_en),
        .data_out(rx_decoded_byte),
        .valid_out(rx_valid)
    );

endmodule