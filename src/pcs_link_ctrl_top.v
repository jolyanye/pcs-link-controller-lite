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
    output wire link_lock_out
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
    wire tx_fifo_empty, tx_fifo_full;
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

    cdc_fifo #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) tx_cdc_fifo (
        // Write side
        .clk_wr(clk_sys),
        .rst_n_wr(rst_n && !flush),
        .wr_en(tx_fifo_wr_en),
        .data_in(tx_enc_data),
        .full(tx_fifo_full),

        // Read side
        .clk_rd(clk_link),
        .rst_n_rd(rst_n && !flush),
        .rd_en(tx_ser_rd_en),
        .data_out(tx_fifo_data_out),
        .empty(tx_fifo_empty)
    );

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
        .comma_det(),
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
        .valid_out(rx_valid),
        .k_out(),
        .decode_err()
    );

endmodule