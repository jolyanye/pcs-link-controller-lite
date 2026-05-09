`default_nettype none
`timescale 1ns / 1ps

module tb ();

  initial begin
    $dumpfile("tb.fst");
    $dumpvars(0, tb);
    #1;
  end

  // Signals
  reg clk_sys;    // ui_in[0]
  reg serial_in;  // ui_in[1]
  reg rx_req;     // ui_in[2]
  reg tx_valid;   // ui_in[3]
  reg [3:0] ui_unused;
  wire [7:0] ui_in = {ui_unused, tx_valid, rx_req, serial_in, clk_sys};

  reg clk;   // clk_link (66 MHz)
  reg rst_n;
  reg ena;

  reg [7:0] uio_in;
  wire [7:0] uo_out;
  wire [7:0] uio_out;
  wire [7:0] uio_oe;

  wire serial_out    = uo_out[0];
  wire rx_ack        = uo_out[1];
  wire link_lock_out = uo_out[2];
  wire occupied      = uo_out[3];
  wire rx_valid      = uo_out[4];
  wire tx_fifo_full  = uo_out[5];

  `ifdef GL_TEST
    wire VPWR = 1'b1;
    wire VGND = 1'b0;
  `endif

  tt_um_pcs_link_lite user_project (
`ifdef GL_TEST
      .VPWR(VPWR),
      .VGND(VGND),
`endif
      .ui_in  (ui_in),
      .uo_out (uo_out),
      .uio_in (uio_in),
      .uio_out(uio_out),
      .uio_oe (uio_oe),
      .ena    (ena),
      .clk    (clk),
      .rst_n  (rst_n)
  );

endmodule