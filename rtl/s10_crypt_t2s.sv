// Namco System 10 MEM(N) KEYCUS type-2 decrypter, serial form (any number of nonlinear product terms).
// Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later
//
// Same function as s10_crypt_t2.sv (MAME ns10_type2_decrypter_device / ..._nonlinear_device), generalised:
//   plain  = cipher ^ mask
//   C' = {C[47:0], cipher}   P' = {P[47:0], plain}
//   mask'[j] = parity(emask[j] & C') ^ parity(dmask[j] & P') ^ xmask[j] ^ (out[j] & NL)
//   NL = XOR over terms t of parity(Ac_t & C' ^ Ap_t & P') & parity(Bc_t & C' ^ Bp_t & P')
//        (or the next bit of the recorded table, Point Blank 3)
// Taiko no Tatsujin 3 / 5 / RT need 3-5 product terms (MAME lambdas), the other games one.
//
// The masks live in a small RAM of 128-bit rows {P mask, C mask}, written by the loader from the board record:
//   rows 0-15   {dmask[j], emask[j]}         rows 16+2t / 17+2t  term t: {Ap, Ac} / {Bp, Bc}   (t < 8)
//   rows 32-47  IV table: C history after activate = row[47:0]
// One row is evaluated per clock: a step takes 16 + 2*nterms + 3 clocks (busy). plain is combinational from the
// state before the step, as before; the caller must wait for !busy before the next step or activate.
module s10_crypt_t2s (
    input  wire          clk,
    input  wire          reset,

    // mask RAM write port (loader): row, 16-bit lane (0-3 C mask, 4-7 P mask)
    input  wire          row_we,
    input  wire   [5:0]  row_addr,
    input  wire   [2:0]  row_lane,
    input  wire  [15:0]  row_data,

    input  wire  [15:0]  xmask,
    input  wire  [15:0]  nl_out,
    input  wire   [2:0]  nterms,          // product terms (0 = 1, record default)
    input  wire          nl_tab_en,
    input  wire          nl_tab_bit,

    input  wire          activate,
    input  wire   [3:0]  iv,
    input  wire          deactivate,
    input  wire          word_valid,
    input  wire  [15:0]  cipher,
    output wire  [15:0]  plain,
    output reg           active = 1'b0,
    output reg           busy = 1'b0
);
    // ------------------------------------------------------------------ mask RAM: 8 lanes x 64 x 16
    reg   [5:0] raddr = 0;
    wire [127:0] row;
    genvar gl;
    generate
        for (gl = 0; gl < 8; gl = gl + 1) begin : g_lane
            reg [15:0] mem [0:63];
            reg [15:0] q = 0;
            always @(posedge clk) begin
                if (row_we && row_lane == 3'(gl)) mem[row_addr] <= row_data;
                q <= mem[raddr];
            end
            assign row[16*gl +: 16] = q;
        end
    endgenerate

    // ------------------------------------------------------------------ state
    reg  [47:0] hist_c = 0, hist_p = 0;
    reg  [15:0] mask = 0;
    assign plain = cipher ^ mask;

    reg  [63:0] cn = 0, pn = 0;            // C', P' of the step in progress
    reg  [15:0] lin = 0;
    reg         nl = 1'b0, pa = 1'b0, tbit = 1'b0;
    reg   [5:0] ri = 0;                    // row being read
    reg   [5:0] ei = 0;                    // row whose data is in 'row' this clock
    reg   [1:0] lat = 0;                   // RAM read latency counter
    reg   [5:0] last = 0;                  // last row of the step
    localparam [1:0] I_IDLE = 2'd0, I_STEP = 2'd1, I_ACT = 2'd2;
    reg   [1:0] ist = I_IDLE;

    wire        par = ^(row[63:0] & cn) ^ ^(row[127:64] & pn);
    wire  [2:0] nt  = (nterms == 3'd0) ? 3'd1 : nterms;

    always @(posedge clk) begin
        if (reset) begin
            active <= 1'b0; busy <= 1'b0; ist <= I_IDLE; mask <= 0; hist_c <= 0; hist_p <= 0;
        end else case (ist)
            I_IDLE:
                if (activate) begin
                    raddr <= 6'd32 + {2'b00, iv};
                    lat   <= 2'd1;
                    busy  <= 1'b1;
                    ist   <= I_ACT;
                end else if (deactivate) active <= 1'b0;
                else if (word_valid && active) begin
                    cn    <= {hist_c, cipher};
                    pn    <= {hist_p, plain};
                    tbit  <= nl_tab_bit;
                    lin   <= 0;
                    nl    <= 1'b0;
                    raddr <= 6'd0;
                    ri    <= 6'd1;
                    ei    <= 6'd0;
                    lat   <= 2'd1;
                    last  <= 6'd15 + {nt, 1'b0};
                    busy  <= 1'b1;
                    ist   <= I_STEP;
                end
            I_ACT: begin                                  // IV row -> C history
                if (lat != 0) lat <= lat - 1'd1;
                else begin
                    hist_c <= row[47:0];
                    hist_p <= 48'd0;
                    mask   <= 16'd0;
                    active <= 1'b1;
                    busy   <= 1'b0;
                    ist    <= I_IDLE;
                end
            end
            I_STEP: begin
                raddr <= ri;                              // read ahead one row per clock
                ri    <= ri + 1'd1;
                if (lat != 0) lat <= lat - 1'd1;
                else begin
                    // 'row' holds row ei
                    if (ei < 6'd16) lin[ei[3:0]] <= par;
                    else if (!ei[0]) pa <= par;
                    else nl <= nl ^ (pa & par);
                    ei <= ei + 1'd1;
                    if (ei == last) begin
                        hist_c <= cn[47:0];
                        hist_p <= pn[47:0];
                        mask   <= lin ^ xmask ^ (nl_out & {16{nl_tab_en ? tbit : (nl ^ (pa & par))}});
                        busy   <= 1'b0;
                        ist    <= I_IDLE;
                    end
                end
            end
            default: ist <= I_IDLE;
        endcase
    end
endmodule
