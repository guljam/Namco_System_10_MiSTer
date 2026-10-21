// Namco System 10 EXIO board with its TMP95C061 microcontroller (Taiko no Tatsujin drums), high-level.
// Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later
//
// [MAME-SOURCE namcos10_exio.cpp namcos10_exio_device (ident 0x30), namcos10.cpp namcos10_map_exio_inner]
// Board-bus window 0xE00000 (CPU 0x1FE00000):
//   E06000-E0FFFF  shared RAM, one byte per 16-bit location: byte k at E06000 + 2k (MCU address 0x3000 + k)
//   E10000         ctrl (bit 0 rising starts the MCU)      E18000  bus request: reads 2 while 1 was written
//   E28000         MCU status: 0x0101 once the MCU runs     E50000/E58000  EXIO_IN1/2 (unused: 0xFFFF)
// The game uploads the MCU program into the shared RAM (taiko2/4: the same program, taiko6: a later build) and
// starts it. The program's main loop (disassembled from the upload, entry 0x3067, loop at 0x3B4D) keeps a block
// at MCU 0x6008 (shared byte 0x3008) up to date:
//   0x3008       0x31 every pass (the game writes 0x17 there and looks for it to come back)
//   0x300A       16-bit pass counter (~2400 passes per second)
//   0x3020-302F  8 ADC words, multiplexer 0-3 x channel 0/1 = EXIO_ANALOG1-8 = drum sensors
//                P1 right rim, P1 right surface, P1 left surface, P1 left rim, then the same for P2
//                ADREG format {10-bit value, 6 x 1}: 0x003F at rest, 0xFFFF for a full hit (MAME)
//   0x3033       ADC channel 3 >> 8 (unconnected: 0x00)
//   0x37DE       0x17 = read ADC channel 2 into 0x37E0 (word), then cleared
//   0x3751       0x17 = set timer outputs from 0x374E-0x3750, then cleared
// Over boot, attract and play the game reads only 0x3008, 0x3020-0x302F and 0x3033 (MAME read watchpoints);
// nothing else of the program image is ever read back, so no RAM is kept for it.
// GAHAHA Ippatsudou 1 / 2 run the same kind of program; their ADC inputs are two analog sticks per player
// (EXIO_ANALOG1-8 = P1 left X, left Y, right X, right Y, then P2), 10-bit values in the same ADREG format.
//
// NFL Classic Football (serial_en): its program also runs the MCU's serial port SC0 (8-bit UART), wired to the
// cabinet's control-panel board (four trackballs, the play-clock digits, lamps). MAME does not emulate it; the
// protocol is taken from the uploaded MCU program (SC0 receive interrupt at MCU 0x3D2A) and the game's driver
// (main CPU 0x80013BF0, 0x800A1B80, 0x800A1D20), and was checked in MAME with a Lua stand-in for the board:
//   0x374E-0x3750 + 0x3751 = 0x17   UART set-up (mode, baud rate, control); the MCU clears 0x3751
//   0x375E-...    + 0x375B length + 0x3752 = 0x17   send; the MCU clears 0x3752 when the bytes are out
//   0x379E-0x37DD  64-byte receive ring, 0x3758 its write index (the game keeps its own read index)
// Every other frame the game sends {B1, digit, digit, lamps, 0 x 5, sum of bytes 0-8} and takes bytes 1-8 of the
// reply as the trackball counters X1 Y1 X2 Y2 X3 Y3 X4 Y4 (8-bit, free running; it uses new - old for X and
// old - new for Y). At start-up it may send {A0, 0 x 8, A0} and expect it echoed back. This module answers
// both ~2.5 ms after the send request (a 10-byte reply at the board's baud rate).
module s10_exio #(
    parameter int CLK_HZ = 33_868_800
) (
    input  wire        clk,
    input  wire        reset,
    input  wire        enable,            // board record: EXIO with microcontroller (ident 0x30), high-level

    input  wire [23:0] addr,
    input  wire [31:0] wdata,
    input  wire  [3:0] wmask,
    input  wire  [1:0] size,
    input  wire        rd,
    input  wire        wr,
    output reg  [31:0] rdata = 0,

    input  wire  [7:0] drum,               // 1 = hit, bit n = EXIO_ANALOG(n+1)
    input  wire        analog_en,          // ADC = analog values (GAHAHA) instead of drum hits
    input  wire [79:0] analog,             // 10 bits per channel, channel n at [10n +: 10] = EXIO_ANALOG(n+1)

    input  wire        serial_en,          // NFL Classic Football: control-panel board on SC0
    input  wire [63:0] tb,                 // trackball counters, byte i = reply byte i + 1 (X1 Y1 X2 Y2 ... Y4)
    input  wire [15:0] exio_in1            // EXIO_IN1 (0xE50000), active low
);
    reg  [15:0] ctrl = 0, bus_req = 0;
    reg         active = 1'b0;
    reg  [15:0] start_cnt = 0;            // MCU start-up after ctrl bit 0 rises (~1 ms)
    reg         running = 1'b0;
    reg   [7:0] alive = 0;                // shared 0x3008
    reg  [15:0] passes = 0;               // shared 0x300A
    reg  [15:0] adc2 = 16'h003F;          // shared 0x37E0
    reg   [7:0] req_adc2 = 0;             // shared 0x37DE
    reg   [7:0] req_tmr = 0;              // shared 0x3751
    reg  [13:0] pass_div = 0;
    localparam int PASS_DIV = CLK_HZ / 2400;

    // SC0 (serial_en)
    reg   [7:0] req_tx = 0;               // shared 0x3752
    reg   [7:0] tx [0:9];                 // shared 0x375E-0x3767 (the game's packets are 10 bytes)
    reg   [7:0] rxb [0:31];               // shared 0x379E-0x37DD: the ring is 64 bytes, but at most one 10-byte reply
                                          // is ever waiting, so the last 32 bytes written are kept (position & 31)
    reg   [5:0] rx_idx = 0;               // shared 0x3758
    reg   [3:0] resp_wait = 0;            // passes until the reply arrives
    reg   [3:0] resp_n = 0;               // reply bytes left to store
    reg         resp_echo = 1'b0;
    reg   [7:0] resp_sum = 0;
    reg  [63:0] resp_tb = 0;
    initial for (int i = 0; i < 10; i++) tx[i] = 8'h00;
    initial for (int i = 0; i < 32; i++) rxb[i] = 8'h00;

    function automatic [7:0] ram_r(input [14:0] k);
        logic [15:0] w;
        if (analog_en) w = {analog[10*k[3:1] +: 10], 6'h3F};
        else           w = drum[k[3:1]] ? 16'hFFFF : 16'h003F;
        if (k >= 15'h3020 && k <= 15'h302F) ram_r = k[0] ? w[15:8] : w[7:0];
        else if (serial_en && k >= 15'h379E && k <= 15'h37DD) ram_r = rxb[5'(k - 15'h379E)];
        else if (serial_en && k >= 15'h375E && k <= 15'h3767) ram_r = tx[4'(k - 15'h375E)];
        else if (serial_en && k == 15'h3752) ram_r = req_tx;
        else if (serial_en && k == 15'h3758) ram_r = {2'b00, rx_idx};
        else case (k)
            15'h3008: ram_r = alive;
            15'h300A: ram_r = passes[7:0];
            15'h300B: ram_r = passes[15:8];
            15'h37DE: ram_r = req_adc2;
            15'h37E0: ram_r = adc2[7:0];
            15'h37E1: ram_r = adc2[15:8];
            15'h3751: ram_r = req_tmr;
            default:  ram_r = 8'h00;
        endcase
    endfunction

    function automatic [15:0] reg_r(input [23:0] a);
        if (a >= 24'hE06000 && a < 24'hE10000) reg_r = {8'h00, ram_r(a[15:1] - 15'h3000)};
        else case ({a[23:2], 2'b00})
            24'hE10000: reg_r = ctrl;
            24'hE18000: reg_r = (bus_req == 16'd1) ? 16'h0002 : 16'h0000;
            24'hE28000: reg_r = active ? 16'h0101 : 16'h0000;
            24'hE50000: reg_r = exio_in1;
            24'hE58000: reg_r = 16'hFFFF;
            default:    reg_r = 16'h0000;
        endcase
    endfunction

    wire        hit   = enable && addr[23:21] == 3'b111;
    wire [23:0] a_lo  = {addr[23:2], 2'b00};
    wire [23:0] a_hi  = {addr[23:2], 2'b10};
    wire        rd_lo = (size == 2'b10) || !addr[1];
    wire        rd_hi = (size == 2'b10) ||  addr[1];

    task automatic reg_w(input [23:0] a, input [15:0] d);
        if (a >= 24'hE06000 && a < 24'hE10000) begin
            case (a[15:1] - 15'h3000)
                15'h3008: alive    <= d[7:0];
                15'h37DE: req_adc2 <= d[7:0];
                15'h3751: begin
                    req_tmr <= d[7:0];
                    if (serial_en && d[7:0] == 8'h17) rx_idx <= 0;    // UART (re)configured: empty ring
                end
                15'h3752: if (serial_en) req_tx <= d[7:0];
                default: if (serial_en && (a[15:1] - 15'h3000) >= 15'h375E && (a[15:1] - 15'h3000) <= 15'h3767)
                             tx[4'((a[15:1] - 15'h3000) - 15'h375E)] <= d[7:0];
            endcase
        end else case ({a[23:2], 2'b00})
            24'hE10000: begin
                ctrl <= d;
                if (d[0] && !ctrl[0]) begin running <= 1'b0; start_cnt <= 16'(CLK_HZ / 1000); end
                if (!d[0] && ctrl[0]) running <= 1'b0;
            end
            24'hE18000: bus_req <= d;
            default: ;
        endcase
    endtask

    always @(posedge clk) begin
        rdata <= 0;
        if (reset || !enable) begin
            ctrl <= 0; bus_req <= 0; active <= 1'b0; running <= 1'b0; start_cnt <= 0;
            alive <= 0; passes <= 0; req_adc2 <= 0; req_tmr <= 0; adc2 <= 16'h003F;
            req_tx <= 0; rx_idx <= 0; resp_wait <= 0; resp_n <= 0;
        end else begin
            if (rd && hit) rdata <= {rd_hi ? reg_r(a_hi) : 16'h0000, rd_lo ? reg_r(a_lo) : 16'h0000};
            if (wr && hit) begin
                if (wmask[1:0] != 2'b00) reg_w(a_lo, wdata[15:0]);
                if (wmask[3:2] != 2'b00) reg_w(a_hi, wdata[31:16]);
            end

            // MCU start-up, then one main-loop pass every ~0.42 ms
            if (start_cnt != 0) begin
                start_cnt <= start_cnt - 1'd1;
                if (start_cnt == 16'd1) begin running <= 1'b1; active <= 1'b1; end
            end
            if (running) begin
                if (pass_div == 14'(PASS_DIV - 1)) begin
                    pass_div <= 0;
                    passes   <= passes + 1'd1;
                    alive    <= 8'h31;
                    if (req_adc2 == 8'h17) begin adc2 <= 16'h003F; req_adc2 <= 8'h00; end
                    if (req_tmr  == 8'h17) req_tmr <= 8'h00;
                    // SC0: a send request goes out, the board's reply comes back ~2.5 ms later
                    if (req_tx == 8'h17) begin
                        req_tx <= 8'h00;
                        if (tx[0] == 8'hB1 || tx[0] == 8'hA0) begin
                            resp_wait <= 4'd6;
                            resp_echo <= (tx[0] == 8'hA0);
                        end
                    end
                    if (resp_wait != 0) begin
                        resp_wait <= resp_wait - 1'd1;
                        if (resp_wait == 4'd1) begin resp_n <= 4'd10; resp_sum <= 8'h00; resp_tb <= tb; end
                    end
                end else pass_div <= pass_div + 1'd1;
            end

            // store the reply in the receive ring, one byte per clock
            if (resp_n != 0) begin
                logic [7:0] b;
                case (resp_n)
                    4'd10:   b = resp_echo ? tx[0] : 8'hB1;
                    4'd1:    b = resp_echo ? tx[9] : resp_sum;
                    default: b = resp_echo ? tx[10 - resp_n] : resp_tb[8 * (9 - resp_n) +: 8];
                endcase
                rxb[rx_idx[4:0]] <= b;
                rx_idx      <= rx_idx + 1'd1;
                resp_sum    <= resp_sum + b;
                resp_n      <= resp_n - 1'd1;
            end
        end
    end
endmodule
