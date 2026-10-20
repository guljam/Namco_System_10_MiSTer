// Namco System 10 MEM(N) ROM-board stream decrypter, type 2 (generic, per-game parameters).
//
// Port of MAME 0.289 ns10_type2_decrypter_device (src/mame/namco/ns10crypt.cpp) with the per-game
// nonlinear lambda expressed in the generic form used by every known type-2 game:
//
//   plain  = cipher ^ mask
//   C'     = {C[47:0], cipher}        P' = {P[47:0], plain}       (64-bit word histories)
//   mask'[j] = ^(emask[j] & C') ^ ^(dmask[j] & P')                 j = 0..15
//              ^ xmask[j]
//              ^ (A & B & nl_out[j])
//   A = ^((nl_ac & C') ^ (nl_ap & P'))     B = ^((nl_bc & C') ^ (nl_bp & P'))
//
// Table form (MAME ns10_type2_decrypter_nonlinear_device, Point Blank 3 / Gunbalina): with nl_tab_en the
// nonlinear term is nl_out * nl_tab_bit instead of nl_out * (A & B); nl_tab_bit is the next bit of the
// game's recorded bit stream (MSB first per byte), supplied by the caller, which advances its cursor on
// every consumed word (word_valid && active).
//
// activate (pulse) with iv: C = ivtab[iv], P = 0, mask = 0, active = 1.
// deactivate (pulse): active = 0.
//
// Parameter vector layout: emask/dmask/ivtab element i at [i*64 +: 64] (i = output bit j for the
// masks, i = iv for ivtab). The parameters must be static while decrypting; the core should hold
// them in registers loaded from the MRA board record (they are only read combinationally here).
// scripts/ns10crypt.py t2_param_vectors() packs a parameter set in this layout.
//
// Timing: plain is combinational from the current state and cipher (valid the same cycle as
// word_valid). The state advances at the clock edge where word_valid && active.
// activate/deactivate have priority over word_valid in the same cycle (the word is not consumed).
//
// Cost (ALM-heavy part): 16 output bits x 128-input masked parity (emask&C' ^ dmask&P') plus two
// 128-input masked parities for the nonlinear term = 18 x 128 AND/XOR inputs, ~3 LUT levels after
// the plain = cipher ^ mask XOR. Quartus 17.0 fit on 5CSEBA6U23I7 with the masks as run-time
// registers (no constant folding): ~670 ALMs for this module, Fmax ~114 MHz (registered in/out).
// The 2048+1024+272 parameter flops live in the core (~1.7k more ALMs worth of registers if they
// are plain flops; the IV table could instead be a small ROM/MLAB read at activate time).
// State: 48+48+16+1 flops. Critical path: mask reg -> plain -> P' -> parity tree -> mask reg.

module s10_crypt_t2 (
    input  wire          clk,
    input  wire          reset,

    // per-game parameters (static)
    input  wire [1023:0] emask,
    input  wire [1023:0] dmask,
    input  wire [15:0]   xmask,
    input  wire [1023:0] ivtab,
    input  wire [63:0]   nl_ac,
    input  wire [63:0]   nl_ap,
    input  wire [63:0]   nl_bc,
    input  wire [63:0]   nl_bp,
    input  wire [15:0]   nl_out,
    input  wire          nl_tab_en,
    input  wire          nl_tab_bit,

    input  wire          activate,
    input  wire [3:0]    iv,
    input  wire          deactivate,
    input  wire          word_valid,
    input  wire [15:0]   cipher,
    output wire [15:0]   plain,
    output reg           active
);

// Only the three previous words are kept: the oldest 16 bits of MAME's 64-bit history are
// shifted out before they are ever used (C' = {C[47:0], cipher}), so 48-bit registers are exact.
reg  [47:0] hist_c;
reg  [47:0] hist_p;
reg  [15:0] mask;

assign plain = cipher ^ mask;

wire [63:0] c_next = {hist_c, cipher};
wire [63:0] p_next = {hist_p, plain};

wire [15:0] lin;
genvar j;
generate
    for (j = 0; j < 16; j = j + 1) begin : g_bit
        // two 64-bit parities (identical to one 128-bit parity; NVC 1.23 mis-reduces vectors > 64 bits)
        assign lin[j] = ^(emask[j*64 +: 64] & c_next) ^ ^(dmask[j*64 +: 64] & p_next);
    end
endgenerate

wire nl_a = ^(nl_ac & c_next) ^ ^(nl_ap & p_next);
wire nl_b = ^(nl_bc & c_next) ^ ^(nl_bp & p_next);

wire        nl_term   = nl_tab_en ? nl_tab_bit : (nl_a & nl_b);
wire [15:0] mask_next = lin ^ xmask ^ (nl_out & {16{nl_term}});

wire [63:0] iv_sel = ivtab[iv*64 +: 64];
/* verilator lint_off UNUSEDSIGNAL */
wire [15:0] iv_unused = iv_sel[63:48];   // shifted out before first use (see hist_c)
/* verilator lint_on UNUSEDSIGNAL */

always @(posedge clk) begin
    if (reset) begin
        active <= 1'b0;
        hist_c <= 48'd0;
        hist_p <= 48'd0;
        mask   <= 16'd0;
    end else if (activate) begin
        active <= 1'b1;
        hist_c <= iv_sel[47:0];
        hist_p <= 48'd0;
        mask   <= 16'd0;
    end else if (deactivate) begin
        active <= 1'b0;
    end else if (word_valid && active) begin
        hist_c <= c_next[47:0];
        hist_p <= p_next[47:0];
        mask   <= mask_next;
    end
end

endmodule
