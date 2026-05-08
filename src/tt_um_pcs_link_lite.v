/*
 * Copyright (c) 2026 Jolyan Ye
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_pcs_link_lite (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

    // **********************
    // INPUT MAPPING (ui_in)
    // **********************
    wire clk_sys   = ui_in[0];  // 10 MHz System clock
    wire serial_in = ui_in[1];
    wire rx_req    = ui_in[2];
    wire tx_valid  = ui_in[3];

    // **********************
    // OUTPUT MAPPING (uo_out)
    // **********************
    wire serial_out;
    wire rx_valid;
    wire rx_ack;
    wire occupied;
    wire link_lock_out;

    // Explicitly assign each internal wire to a specific output pin
    assign uo_out[0] = serial_out;
    assign uo_out[1] = rx_ack;
    assign uo_out[2] = link_lock_out;
    assign uo_out[3] = occupied;
    assign uo_out[4] = rx_valid;
    
    // Tie unused output pins safely to ground
    assign uo_out[7:5] = 3'b000; 

    // **********************
    // BIDIRECTIONAL BUS MAPPING (uio)
    // **********************
    wire [7:0] pcs_data_out;
    
    // Drive the output pad with whatever the PCS core is transmitting
    assign uio_out = pcs_data_out;
    
    // Set Output Enable: 1 (drive output) when rx_ack is high, 0 (read input) otherwise
    assign uio_oe = {8{rx_ack}};

    // **********************
    // PCS INSTANTIATION
    // **********************
    pcs_link_ctrl_top #(
        .DATA_WIDTH(10),
        .ADDR_WIDTH(2)
    ) pcs_core (
        .clk_sys(clk_sys),     // Routed to the 10 MHz GPIO clock
        .clk_link(clk),        // Routed to the 66 MHz dedicated clock
        .rst_n(rst_n),
        .serial_in(serial_in),
        .serial_out(serial_out),
        .data_in(uio_in),      
        .data_out(pcs_data_out),
        .rx_req(rx_req),
        .tx_valid(tx_valid),
        .rx_valid(rx_valid),
        .rx_ack(rx_ack),
        .occupied(occupied),
        .link_lock_out(link_lock_out)
    );

endmodule