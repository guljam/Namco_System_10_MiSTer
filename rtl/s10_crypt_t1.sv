// Namco System 10 MEM(M) ROM-board stream decrypter, type 1 (Mr. Driller 2 only).
//
// Port of MAME 0.289 ns10_type1_decrypter_device (src/mame/namco/ns10crypt.cpp).
// Per decrypted word:
//   plain     = mask ^ bitswap(cipher)
//   mask'     = nbs(cipher, counter) ^ bitswap(cipher) ^ bitswap(plain) ^ 0xECBE
//   counter'  = counter + 1 (8 bit)
// activate (pulse) with iv: mask = INIT_SBOX[iv], counter = 0, active = 1.
// deactivate (pulse): active = 0 (state is kept but irrelevant, the next activate reloads it).
//
// Timing: plain is combinational from the current state and cipher (valid the same cycle as
// word_valid). The state advances at the clock edge where word_valid && active.
// activate/deactivate have priority over word_valid in the same cycle (the word is not consumed).
// Logic: 16 flops mask + 8 counter + active; Quartus 17.0 fit: ~18 ALMs.

module s10_crypt_t1 (
    input  wire        clk,
    input  wire        reset,
    input  wire        activate,
    input  wire [3:0]  iv,
    input  wire        deactivate,
    input  wire        word_valid,
    input  wire [15:0] cipher,
    output wire [15:0] plain,
    output reg         active
);

reg  [15:0] mask;
reg  [7:0]  counter;

// INIT_SBOX {U,U,U,0,4,9,U,U,U,8,U,1,U,9,U,5}, U = 16 (unknown in MAME, unused by mrdrilr2)
reg  [15:0] init_mask;
always @(*) begin
    case (iv)
        4'h3:    init_mask = 16'd0;
        4'h4:    init_mask = 16'd4;
        4'h5:    init_mask = 16'd9;
        4'h9:    init_mask = 16'd8;
        4'hB:    init_mask = 16'd1;
        4'hD:    init_mask = 16'd9;
        4'hF:    init_mask = 16'd5;
        default: init_mask = 16'd16;
    endcase
end

wire [15:0] c = cipher;

// bitswap<16>(cipher, 9,13,15,7,14,8,6,10,11,12,3,5,0,1,4,2)
wire [15:0] c_sw1 = {c[9], c[13], c[15], c[7], c[14], c[8], c[6], c[10],
                     c[11], c[12], c[3], c[5], c[0], c[1], c[4], c[2]};

assign plain = mask ^ c_sw1;
wire [15:0] p = plain;

// bitswap<16>(cipher, 6,11,3,1,13,5,15,10,2,9,8,4,0,12,7,14)
wire [15:0] c_sw2 = {c[6], c[11], c[3], c[1], c[13], c[5], c[15], c[10],
                     c[2], c[9], c[8], c[4], c[0], c[12], c[7], c[14]};
// bitswap<16>(plain, 9,7,5,2,14,4,13,8,0,15,10,1,3,6,12,11)
wire [15:0] p_sw  = {p[9], p[7], p[5], p[2], p[14], p[4], p[13], p[8],
                     p[0], p[15], p[10], p[1], p[3], p[6], p[12], p[11]};

/* verilator lint_off UNUSEDSIGNAL */
wire [7:0] k = counter;   // k[6] is not used by the mrdrilr2 logic
/* verilator lint_on UNUSEDSIGNAL */
wire [15:0] nbs;
assign nbs[15] = k[4];
assign nbs[14] = c[2] ^ c[5];
assign nbs[13] = c[0];
assign nbs[12] = c[4] | c[5];
assign nbs[11] = k[0];
assign nbs[10] = c[6];
assign nbs[9]  = 1'b0;
assign nbs[8]  = c[4] & k[1];
assign nbs[7]  = 1'b0;
assign nbs[6]  = k[3];
assign nbs[5]  = c[3] | k[7];
assign nbs[4]  = c[2] ^ k[3];
assign nbs[3]  = k[2];
assign nbs[2]  = c[7] & k[7];
assign nbs[1]  = k[5];
assign nbs[0]  = c[7] | k[1];

wire [15:0] mask_next = nbs ^ c_sw2 ^ p_sw ^ 16'hECBE;

always @(posedge clk) begin
    if (reset) begin
        active  <= 1'b0;
        mask    <= 16'd0;
        counter <= 8'd0;
    end else if (activate) begin
        active  <= 1'b1;
        mask    <= init_mask;
        counter <= 8'd0;
    end else if (deactivate) begin
        active  <= 1'b0;
    end else if (word_valid && active) begin
        mask    <= mask_next;
        counter <= counter + 8'd1;
    end
end

endmodule
