// Namco System 10: two DDR3 clients (s10_mem, s10_p3) on psx_top's single System 10 arbiter port.
// Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later
//
// Both clients follow the same protocol (clk2 domain): ddr_request is raised with the command and held until the
// transfer is over (a write: until ddr_ack; a read: until its last data beat has arrived), then dropped. The mux
// grants the port to one client at a time (client A first) and keeps it until that client drops its request, so
// ddr_ack and the data beats always belong to the owner; the other client sees neither.
module s10_ddr_mux (
    input  wire        clk2,
    input  wire        reset,

    input  wire        a_request,
    output wire        a_ack,
    input  wire  [7:0] a_burstcnt,
    input  wire [27:0] a_addr,
    input  wire [63:0] a_din,
    input  wire  [7:0] a_be,
    input  wire        a_we,
    input  wire        a_rd,
    output wire        a_dout_ready,

    input  wire        b_request,
    output wire        b_ack,
    input  wire  [7:0] b_burstcnt,
    input  wire [27:0] b_addr,
    input  wire [63:0] b_din,
    input  wire  [7:0] b_be,
    input  wire        b_we,
    input  wire        b_rd,
    output wire        b_dout_ready,

    output wire        ddr_request,
    input  wire        ddr_ack,
    output wire  [7:0] ddr_burstcnt,
    output wire [27:0] ddr_addr,
    output wire [63:0] ddr_din,
    output wire  [7:0] ddr_be,
    output wire        ddr_we,
    output wire        ddr_rd,
    input  wire        ddr_dout_ready
);
    localparam [1:0] O_NONE = 2'd0, O_A = 2'd1, O_B = 2'd2;
    reg  [1:0] own = O_NONE;
    // a new owner is taken only while idle; the grant is visible in the same clock it is taken
    wire [1:0] cur = (own != O_NONE) ? own : a_request ? O_A : b_request ? O_B : O_NONE;

    always @(posedge clk2) begin
        if (reset) own <= O_NONE;
        else if (own == O_NONE) own <= cur;
        else if ((own == O_A && !a_request) || (own == O_B && !b_request)) own <= O_NONE;
    end

    wire sel_b = (cur == O_B);
    assign ddr_request  = (cur == O_A) ? a_request : (cur == O_B) ? b_request : 1'b0;
    assign ddr_burstcnt = sel_b ? b_burstcnt : a_burstcnt;
    assign ddr_addr     = sel_b ? b_addr     : a_addr;
    assign ddr_din      = sel_b ? b_din      : a_din;
    assign ddr_be       = sel_b ? b_be       : a_be;
    assign ddr_we       = sel_b ? b_we       : a_we;
    assign ddr_rd       = sel_b ? b_rd       : a_rd;
    assign a_ack        = (cur == O_A) && ddr_ack;
    assign b_ack        = (cur == O_B) && ddr_ack;
    assign a_dout_ready = (own == O_A) && ddr_dout_ready;
    assign b_dout_ready = (own == O_B) && ddr_dout_ready;
endmodule
