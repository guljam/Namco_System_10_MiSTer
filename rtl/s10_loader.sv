// Namco System 10 ROM loader: board record, BIOS descramble, DDR3 image / nvram writer.
// Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later
//
// MRA indexes (hps_io WIDE=1: one little-endian 16-bit word per ioctl_wr, ioctl_addr = byte offset):
//   1  board record (docs/ARCHITECTURE.md section 5), sent first
//   0  BIOS part of the first flash / NAND: unscrambled here and written to the SDRAM BIOS area, as MAME's
//      memm_driver_init / memn_driver_init copy it to "maincpu:rom":
//        MEM(M): flash bytes [0, 0x62000)          -> BIOS [0, 0x62000),  w' = bitswap(w ^ 0xAAAA)
//        MEM(N): NAND0 from page 0x40 (0x210-byte pages, the 16 spare bytes dropped, big-endian words):
//                pages 0x40-0x11F -> BIOS [0, 0x1C000), pages 0x120- -> BIOS [0x20000, ...), w' = bitswap(w ^ xor)
//      Before the first word the whole 4 MB BIOS area is filled with 0x55 (MAME ROM_FILL).
//   2  MEM(M) flash / MEM(N) NAND chips   -> DDR3 image +0
//   3  MEM(M) data mask ROMs             -> DDR3 image +0x800000
//   9  nvram                             -> DDR3 image +save_base
// Indexes 2/3 normally come by DDR3 fast loading (MRA address=): Main_MiSTer writes DDR3 itself and sends
// only the length, so no ioctl_wr arrives. With older firmware the words arrive through ioctl and are written
// to DDR3 here. The PSX is held in reset during downloads, so the writer owns the PSX DDR3 port (top level).
module s10_loader #(
    parameter [26:0] BIOS_SDRAM = 27'h0400000,
    parameter [27:0] IMG_BASE   = 28'h2000000     // DDR3 0x32000000
) (
    input  wire         clk,                // clk_1x (hps_io clk_sys)
    input  wire         clk2,               // clk_2x (DDR3)

    input  wire         ioctl_download,
    input  wire  [7:0]  ioctl_index,
    input  wire         ioctl_wr,
    input  wire [26:0]  ioctl_addr,
    input  wire [15:0]  ioctl_dout,
    output wire         ioctl_wait,

    // ---- board record
    output wire         board_memn,
    output wire  [1:0]  crypt_type,
    output wire  [4:0]  nand_count,
    output wire         nand_big,
    output wire [15:0]  data_xor,
    output reg  [63:0]  perm,
    output wire  [7:0]  exio_ident,
    output wire [27:0]  save_base,
    output wire [1023:0] t2_emask,
    output wire [1023:0] t2_dmask,
    output wire [15:0]  t2_xmask,
    output wire [1023:0] t2_iv,
    output wire [63:0]  t2_nl_ac, t2_nl_ap, t2_nl_bc, t2_nl_bp,
    output wire [15:0]  t2_nl_out,
    output reg          record_ok = 1'b0,

    // ---- SDRAM channel 3 (s10_ch3): BIOS words and fills
    output reg          dl_req = 1'b0,
    output reg  [26:0]  dl_addr = 0,
    output reg  [31:0]  dl_data = 0,
    input  wire         dl_done,
    output reg          fill_start = 1'b0,
    output reg  [26:0]  fill_base = 0,
    output reg  [20:0]  fill_words = 0,
    output reg  [31:0]  fill_value = 0,
    input  wire         fill_busy,

    // ---- DDR3 writer (clk2 domain), owns the PSX DDR3 port while own = 1
    output wire         ddr_own,
    output reg          ddr_we = 1'b0,
    output reg  [27:0]  ddr_addr = 0,      // byte address from 0x30000000
    output reg  [63:0]  ddr_din = 0,
    output reg   [7:0]  ddr_be = 0,
    input  wire         ddr_busy
);
    // =====================================================================================================
    // Board record: 464 bytes
    // =====================================================================================================
    localparam int RECB = 464;
    reg  [8*RECB-1:0] rec = 0;

    assign board_memn  = rec[8*4 +: 8] == 8'd1;
    assign crypt_type  = rec[8*5 +: 2];
    assign nand_count  = rec[8*6 +: 5];
    assign nand_big    = rec[8*7 +: 8] == 8'd1;
    assign data_xor    = rec[8*8 +: 16];
    assign exio_ident  = rec[8*26 +: 8];
    assign save_base   = rec[8*28 +: 28];
    assign t2_emask    = rec[8*32  +: 1024];
    assign t2_dmask    = rec[8*160 +: 1024];
    assign t2_xmask    = rec[8*288 +: 16];
    assign t2_iv       = rec[8*296 +: 1024];
    assign t2_nl_ac    = rec[8*424 +: 64];
    assign t2_nl_ap    = rec[8*432 +: 64];
    assign t2_nl_bc    = rec[8*440 +: 64];
    assign t2_nl_bp    = rec[8*448 +: 64];
    assign t2_nl_out   = rec[8*456 +: 16];
    // record bytes 10..25: MAME bitswap<16> arguments in order (source bit of output bit 15, ..., of bit 0)
    always @* for (int i = 0; i < 16; i++) perm[4*i +: 4] = rec[8*(10 + 15 - i) +: 4];

    function automatic [15:0] unscramble(input [15:0] d, input [63:0] p);
        for (int i = 0; i < 16; i++) unscramble[i] = d[p[4*i +: 4]];
    endfunction

    // =====================================================================================================
    // Download state
    // =====================================================================================================
    reg        dl_q = 1'b0;
    wire       dl_rise = ioctl_download && !dl_q;
    reg        bios_dl = 1'b0, rec_dl = 1'b0, img_dl = 1'b0;
    reg [27:0] img_off = 0;               // image offset of the current ioctl index
    reg        bios_filling = 1'b0;

    // BIOS stream position (MEM(N): NAND page / column)
    reg [15:0] b_page = 16'h40;
    reg  [9:0] b_col  = 0;
    reg [15:0] b_lo   = 0;
    reg        sd_wait = 1'b0;             // waiting for an SDRAM write

    // DDR3 writer (clk side)
    reg [63:0] acc_d = 0;
    reg  [7:0] acc_be = 0;
    reg [27:0] acc_a = 0;                 // image byte offset of the beat
    reg        acc_any = 1'b0;
    reg        wb_req = 1'b0;              // clk: beat handed to clk2
    reg        wb_done = 1'b0;             // clk2
    reg [63:0] wb_d = 0;
    reg  [7:0] wb_be = 0;
    reg [27:0] wb_a = 0;

    assign ioctl_wait = sd_wait || wb_req || bios_filling || fill_busy && bios_dl;

    always @(posedge clk) begin
        dl_req     <= 1'b0;
        fill_start <= 1'b0;
        dl_q       <= ioctl_download;

        if (dl_done) sd_wait <= 1'b0;
        if (wb_req && wb_done) wb_req <= 1'b0;
        if (bios_filling && !fill_busy && !fill_start) bios_filling <= 1'b0;

        if (dl_rise) begin
            bios_dl <= (ioctl_index == 8'd0);
            rec_dl  <= (ioctl_index == 8'd1);
            img_dl  <= (ioctl_index == 8'd2 || ioctl_index == 8'd3 || ioctl_index == 8'd9);
            img_off <= (ioctl_index == 8'd3) ? 28'h800000 : (ioctl_index == 8'd9) ? save_base : 28'h0;
            b_page  <= 16'h40;
            b_col   <= 0;
            acc_any <= 1'b0;
            acc_be  <= 0;
            if (ioctl_index == 8'd0) begin
                // MAME ROM_FILL(0x55) of the 4 MB BIOS region, before the copy
                fill_start   <= 1'b1;
                fill_base    <= BIOS_SDRAM;
                fill_words   <= 21'h100000;
                fill_value   <= 32'h55555555;
                bios_filling <= 1'b1;
            end
            if (ioctl_index == 8'd1) record_ok <= 1'b0;
        end

        if (!ioctl_download && dl_q) begin
            if (rec_dl) record_ok <= (rec[31:0] == 32'h42303153);       // "S10B"
            // flush a partial DDR3 beat
            if (img_dl && acc_any && !wb_req) begin
                wb_d <= acc_d; wb_be <= acc_be; wb_a <= acc_a; wb_req <= 1'b1;
                acc_any <= 1'b0; acc_be <= 0;
            end
            bios_dl <= 1'b0; rec_dl <= 1'b0; img_dl <= 1'b0;
        end

        if (ioctl_download && ioctl_wr) begin
            // ---- board record
            if (rec_dl && ioctl_addr < RECB) begin
                rec[8*ioctl_addr +: 8] <= ioctl_dout[7:0];
                if (ioctl_addr + 1 < RECB) rec[8*(ioctl_addr + 1) +: 8] <= ioctl_dout[15:8];
            end

            // ---- BIOS
            if (bios_dl) begin
                if (!board_memn) begin
                    // MEM(M): little-endian flash words, 0xAAAA then the bitswap
                    if (!ioctl_addr[1]) b_lo <= unscramble(ioctl_dout ^ 16'hAAAA, perm);
                    else begin
                        dl_addr <= BIOS_SDRAM + {ioctl_addr[26:2], 2'b00};
                        dl_data <= {unscramble(ioctl_dout ^ 16'hAAAA, perm), b_lo};
                        dl_req  <= 1'b1;
                        sd_wait <= 1'b1;
                    end
                end else begin
                    // MEM(N): big-endian NAND words of the data area only
                    if (b_col < 10'd512) begin
                        if (!b_col[1]) b_lo <= unscramble({ioctl_dout[7:0], ioctl_dout[15:8]} ^ data_xor, perm);
                        else begin
                            dl_addr <= BIOS_SDRAM + ((b_page < 16'h120) ? ({11'd0, b_page - 16'h40} << 9)
                                                                        : 27'h20000 + ({11'd0, b_page - 16'h120} << 9))
                                                  + {17'd0, b_col[8:2], 2'b00};
                            dl_data <= {unscramble({ioctl_dout[7:0], ioctl_dout[15:8]} ^ data_xor, perm), b_lo};
                            dl_req  <= 1'b1;
                            sd_wait <= 1'b1;
                        end
                    end
                    if (b_col == 10'd526) begin b_col <= 0; b_page <= b_page + 1'd1; end
                    else b_col <= b_col + 10'd2;
                end
            end

            // ---- DDR3 image / nvram words
            if (img_dl) begin
                acc_d[16*ioctl_addr[2:1] +: 16] <= ioctl_dout;
                acc_be[2*ioctl_addr[2:1] +: 2]  <= 2'b11;
                acc_a   <= img_off + {1'b0, ioctl_addr[26:3], 3'b000};
                acc_any <= 1'b1;
                if (ioctl_addr[2:1] == 2'b11) begin
                    wb_d    <= {ioctl_dout, acc_d[47:0]};
                    wb_be   <= {2'b11, acc_be[5:0]};
                    wb_a    <= img_off + {1'b0, ioctl_addr[26:3], 3'b000};
                    wb_req  <= 1'b1;
                    acc_any <= 1'b0;
                    acc_be  <= 0;
                end
            end
        end
    end

    // =====================================================================================================
    // DDR3 beat writer (clk2): owns the port during image / nvram downloads
    // =====================================================================================================
    assign ddr_own = img_dl || wb_req || wb_done;
    reg wbusy = 1'b0;
    always @(posedge clk2) begin
        if (!wb_req) wb_done <= 1'b0;
        if (!wbusy) begin
            if (wb_req && !wb_done && !ddr_we) begin
                ddr_we   <= 1'b1;
                ddr_addr <= IMG_BASE + wb_a;
                ddr_din  <= wb_d;
                ddr_be   <= wb_be;
                wbusy    <= 1'b1;
            end
        end else if (!ddr_busy) begin
            ddr_we  <= 1'b0;
            wbusy   <= 1'b0;
            wb_done <= 1'b1;
        end
    end
endmodule
