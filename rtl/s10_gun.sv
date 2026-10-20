// Namco System 10 light guns (Point Blank 3 / Gunbalina, EXIO(G) board): aim positions.
// Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later
//
// [MAME-SOURCE namcos10.cpp exio_lightgun_io_r, INPUT_PORTS ptblank3] The EXIO board returns, per player,
// X and Y as 22-bit values split over two registers (bits 5-0, bits 21-6). MAME's EXIO_LIGHTGUN ports
// run X 0..0x13F and Y 0..0xEF across the visible screen; the game (code at 0x80094848) builds
// (lo << 4 | hi << 10) and converts it to screen positions with the calibration in its settings, whose
// FIRST POWER ON defaults match that range. The trigger is the player's button 1 on IN1 (bits 4 / 12).
//
// [IMPLEMENTATION] Aim source, as the NB-1 core (nb1_gun.sv):
//   MiSTer joysticks: player n's left analog stick (hps_io joystick_l_analog_n, signed -128..127 edge to
//   edge). Main_MiSTer delivers a GunCon 2 (15 kHz CRT, calibrated per core with F10), Sinden / Gun4IR /
//   Wiimote guns and plain analog sticks this way, so the port value is analog + 128.
//   Mouse for player 1 (OSD): relative motion accumulated, clamped to 0..255.
// Board values, exact integer forms of MAME's ranges: X = v * 320 / 256 = v + v/4, Y = v * 240 / 256 = (v * 15) >> 4.
module s10_gun (
    input  wire        clk,
    input  wire        src_mouse,         // OSD: 1 = player 1 aims with the mouse
    input  wire [15:0] joy_a0,            // hps_io joystick_l_analog_0 {Y, X}, signed
    input  wire [15:0] joy_a1,
    input  wire [24:0] ps2_mouse,         // hps_io ps2_mouse

    output reg   [7:0] p1_x = 8'h80, p1_y = 8'h80,   // aim 0..255 (crosshair)
    output reg   [7:0] p2_x = 8'h80, p2_y = 8'h80,
    output reg   [8:0] x0 = 9'd160, y0 = 9'd120,      // EXIO board values
    output reg   [8:0] x1 = 9'd160, y1 = 9'd120
);
    reg  [7:0] mx = 8'h80, my = 8'h80;
    reg        ms_q = 1'b0;
    wire signed [9:0] mx_n = $signed({2'b00, mx}) + $signed({{2{ps2_mouse[4]}}, ps2_mouse[15:8]});
    wire signed [9:0] my_n = $signed({2'b00, my}) - $signed({{2{ps2_mouse[5]}}, ps2_mouse[23:16]});

    always @(posedge clk) begin
        ms_q <= ps2_mouse[24];
        if (ms_q != ps2_mouse[24]) begin                      // one mouse report
            mx <= (mx_n < 0) ? 8'd0 : (mx_n > 255) ? 8'd255 : mx_n[7:0];
            my <= (my_n < 0) ? 8'd0 : (my_n > 255) ? 8'd255 : my_n[7:0];
        end
        p1_x <= src_mouse ? mx : {~joy_a0[7],  joy_a0[6:0]};  // signed + 128
        p1_y <= src_mouse ? my : {~joy_a0[15], joy_a0[14:8]};
        p2_x <= {~joy_a1[7],  joy_a1[6:0]};
        p2_y <= {~joy_a1[15], joy_a1[14:8]};

        x0 <= {1'b0, p1_x} + p1_x[7:2];
        y0 <= 9'(({4'd0, p1_y} * 12'd15) >> 4);
        x1 <= {1'b0, p2_x} + p2_x[7:2];
        y1 <= 9'(({4'd0, p2_y} * 12'd15) >> 4);
    end
endmodule
