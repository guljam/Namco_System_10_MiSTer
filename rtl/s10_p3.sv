// Namco System 10 MEM(P3) board (Golgo 13, Nice Tsukkomi, Seishun Quiz): MCU RAM window and a high-level
// stand-in for the board's TMP95C061 MCU + LC82310 MP3 decoder.
// Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later
//
// [MAME-SOURCE namcos10.cpp namcos10_memp3_state] Board bus (CPU 0x1F300000, 0x9F.., 0xBF..):
//   0x300000 W   firmware: 1 = reset the MCU          0x300006 R  !busy   W  command interrupt (MCU INT5)
//   0x30000C W   RAM bank (64 x 128 KB)                0x30000E R  1 (ready for a firmware upload)
//   0x320000-0x33FFFF  128 KB window into the MCU's 8 MB SDRAM (MCU 0x800000-0xFFFFFF)
// [OBSERVED with MAME taps on all three games, local/mame/p3trace.lua] The game uploads the MCU program (64 KB at MCU
// 0xFF0000) and the MP3 files, writes a command at MCU 0xFE0000 (words: command, argument 1, argument 2) and
// raises the interrupt; the MCU acknowledges, streams the selected MP3 into the LC82310 and sets its volume:
//   004C n      select the stream described at MCU 0xFE0000+n: {u32 offset from 0x800000, u32 length}
//   0050 0 c    start it (plays once)         0053 0 c   stop
//   0056 v      volume: LC82310 attenuation commands 0x13 / 0x15 with v (MAME gain table)
//   0041, 0043  set-up (no audible effect)
// The game never reads anything back from the MCU except the ADC registers it copies to MCU 0xFFFFF0-0xFFFFF7
// (Golgo 13's rifle: AN0 = Y (reversed), AN1 = X, as (v << 6) | (v >> 4)). This module keeps the RAM (DDR3),
// serves the ADC words from the gun input, and turns a "start" into a play request for s10_p3audio: the stream's
// length and CRC-32s of 64 bytes at offsets 0, 0x2000 (length >= 12 KB) and 0x10000 (length >= 72 KB), the keys the
// converter (tools/p3audio.py) stores with each decoded track.
module s10_p3 (
    input  wire          clk,
    input  wire          clk2,
    input  wire          reset,
    input  wire          enable,            // board record: MEM(P3)
    input  wire  [27:0]  mcu_base,          // DDR3 byte offset (from 0x30000000) of the 8 MB MCU RAM

    input  wire  [23:0]  addr,
    input  wire  [31:0]  wdata,
    input  wire   [3:0]  wmask,
    input  wire   [1:0]  size,
    input  wire          rd,
    input  wire          wr,
    output reg   [31:0]  rdata = 0,
    output wire          stall,
    output wire          wstall,            // write buffer nearly full: the memory mux holds the next CPU access

    input  wire   [9:0]  aim_x,             // Golgo 13 rifle, 0 = left
    input  wire   [9:0]  aim_y,             // 0 = top

    output reg           play_req = 1'b0,   // pulse
    output reg   [23:0]  play_len = 0,
    output reg   [31:0]  play_c0 = 0,
    output reg   [31:0]  play_c1 = 0,
    output reg   [31:0]  play_c2 = 0,
    output reg           stop_req = 1'b0,   // pulse
    output reg    [6:0]  volume = 0,        // LC82310 attenuation index (0 = full)

    // DDR3 client (clk2), through s10_ddr_mux
    output reg           ddr_request = 1'b0,
    input  wire          ddr_ack,
    output reg    [7:0]  ddr_burstcnt = 0,
    output reg   [27:0]  ddr_addr = 0,
    output reg   [63:0]  ddr_din = 0,
    output reg    [7:0]  ddr_be = 0,
    output reg           ddr_we = 1'b0,
    output reg           ddr_rd = 1'b0,
    input  wire  [63:0]  ddr_dout,
    input  wire          ddr_dout_ready
);
    // ================================================================================================ CRC-32
    function automatic [31:0] crc8(input [31:0] c, input [7:0] b);
        reg [31:0] x;
        x = c ^ {24'd0, b};
        for (int i = 0; i < 8; i++) x = x[0] ? (x >> 1) ^ 32'hEDB88320 : (x >> 1);
        crc8 = x;
    endfunction

    // ================================================================================================ DDR3 engine
    // Jobs from the clk side (4-phase handshake): read n beats at a byte address (8-aligned) into rbuf, or write
    // one beat. Write beats from the window come through a FIFO (the CPU's writes cannot be stalled).
    reg         job_req = 1'b0;             // clk
    reg   [3:0] job_beats = 0;
    reg  [27:0] job_addr = 0;
    reg         job_done = 1'b0;            // clk2
    reg  [63:0] rbuf [0:15];                // clk2 writes, clk reads after job_done1
    reg         job_done1 = 1'b0;           // job_done one clk later: rbuf has then been stable for a whole clk,
                                            // so rbuf -> clk is a false path (Namco_S10.sdc)

    // write FIFO {beat address 25 bits, be 8, data 64} = 97 bits, 64 entries
    (* ramstyle = "no_rw_check" *) reg [96:0] wf_mem [0:63];
    reg   [6:0] wf_wp = 0;                  // clk
    reg   [6:0] wf_rp = 0;                  // clk2
    reg   [6:0] wf_wp2 = 0, wf_rp1 = 0;     // synchronised copies (same-PLL clocks: one register each way)
    wire        wf_empty2 = (wf_rp == wf_wp2);
    reg  [96:0] wf_head = 0;
    always @(posedge clk2) wf_head <= wf_mem[wf_rp[5:0]];

    localparam [2:0] E_IDLE = 3'd0, E_RD = 3'd1, E_WRPREP = 3'd2, E_WR = 3'd3;
    reg   [2:0] est = E_IDLE;
    reg   [3:0] e_left = 0, e_idx = 0;
    reg         e_acked = 1'b0;
    always @(posedge clk2) begin
        wf_wp2 <= wf_wp;
        if (reset || !enable) begin
            est <= E_IDLE; job_done <= 1'b0; ddr_request <= 1'b0; ddr_rd <= 1'b0; ddr_we <= 1'b0; wf_rp <= wf_wp2;
        end else case (est)
            E_IDLE: begin
                if (!job_req) job_done <= 1'b0;
                if (!wf_empty2) est <= E_WRPREP;                 // queued window writes first (reads see them)
                else if (job_req && !job_done) begin
                    ddr_addr     <= mcu_base + job_addr;
                    ddr_burstcnt <= {4'd0, job_beats};
                    ddr_request  <= 1'b1;
                    ddr_rd       <= 1'b1;
                    ddr_we       <= 1'b0;
                    e_left       <= job_beats;
                    e_idx        <= 0;
                    e_acked      <= 1'b0;
                    est          <= E_RD;
                end
            end
            E_RD: begin
                if (ddr_ack) begin e_acked <= 1'b1; ddr_rd <= 1'b0; end
                if (ddr_dout_ready && (e_acked || ddr_ack)) begin
                    rbuf[e_idx] <= ddr_dout;
                    e_idx  <= e_idx + 1'd1;
                    e_left <= e_left - 1'd1;
                    if (e_left == 4'd1) begin ddr_request <= 1'b0; job_done <= 1'b1; est <= E_IDLE; end
                end
            end
            E_WRPREP: est <= E_WR;                                 // wf_head valid
            E_WR: begin
                if (!ddr_request) begin
                    ddr_addr     <= mcu_base + {wf_head[96:72], 3'b000};
                    ddr_be       <= wf_head[71:64];
                    ddr_din      <= wf_head[63:0];
                    ddr_burstcnt <= 8'd1;
                    ddr_request  <= 1'b1;
                    ddr_we       <= 1'b1;
                    ddr_rd       <= 1'b0;
                end else if (ddr_ack) begin
                    ddr_request <= 1'b0;
                    ddr_we      <= 1'b0;
                    wf_rp       <= wf_rp + 1'd1;
                    est         <= E_IDLE;
                end
            end
            default: est <= E_IDLE;
        endcase
    end

    // ================================================================================================ bus side (clk)
    wire        hit_reg = enable && addr[23:4] == 20'h30000;
    wire        hit_win = enable && addr[23:17] == 7'b0011_001;          // 0x320000-0x33FFFF
    reg   [5:0] bank = 0;
    reg         busy = 1'b0;                                              // command being processed

    // write coalescer: one 64-bit beat {address, data, byte enables}
    reg         cw_valid = 1'b0;
    reg  [24:0] cw_beat = 0;                                              // MCU-RAM byte address [27:3]
    reg  [63:0] cw_data = 0;
    reg   [7:0] cw_be = 0;
    reg   [5:0] cw_age = 0;
    always @(posedge clk) wf_rp1 <= wf_rp;
    wire        wf_full  = (wf_wp - wf_rp1) >= 7'd62;
    // back-pressure well before the FIFO is full (the DDR3 port can wait behind the GPU for a long time); the
    // mux holds the CPU after its current write, so at most a few more beats arrive while wstall is high
    assign      wstall   = enable && (wf_wp - wf_rp1) >= 7'd48;
    wire        wf_empty = (wf_wp == wf_rp1);

    // aim: TMP95C061 ADREG word for a 10-bit value
    function automatic [15:0] adreg(input [9:0] v);
        adreg = {v, v[9:4]};
    endfunction

    // pending CPU read of the window (stall until served)
    reg         rp = 1'b0;
    reg  [16:0] rp_off = 0;
    reg   [1:0] rp_size = 0;
    reg         rp_hi = 1'b0;
    assign stall = rp;

    // HLE command processor
    localparam [3:0] H_IDLE = 4'd0, H_FLUSH = 4'd1, H_CMD = 4'd2, H_CMDW = 4'd3, H_ENT = 4'd4, H_ENTW = 4'd5,
                     H_SMP = 4'd6, H_SMPW = 4'd7, H_CRC = 4'd8, H_PLAY = 4'd9, H_RDW = 4'd10, H_RDDONE = 4'd11;
    reg   [3:0] hst = H_IDLE;
    reg  [15:0] sel = 0;
    reg  [23:0] s_off = 0;                  // stream offset in MCU RAM (from 0x800000)
    reg  [23:0] s_len = 0;
    reg   [1:0] smp = 0;                    // sample being taken (0, 1, 2)
    reg   [6:0] crc_i = 0;
    reg  [31:0] crc = 0;
    reg   [2:0] smp_sh = 0;                 // byte offset of the sample in the first beat

    // which samples exist for this length (the converter's rule)
    reg         flush_now;
    reg  [23:0] smp_a;
    always @* begin
        flush_now = (hst == H_FLUSH);
        smp_a     = s_off + ((smp == 2'd1) ? 24'h002000 : (smp == 2'd2) ? 24'h010000 : 24'd0);
    end
    wire        use1 = (s_len >= 24'h003000);
    wire        use2 = (s_len >= 24'h012000);

    task automatic job(input [27:0] a, input [3:0] n);
        job_addr  <= {a[27:3], 3'b000};
        job_beats <= n;
        job_req   <= 1'b1;
    endtask

    // byte i of the job buffer
    function automatic [7:0] rbyte(input [6:0] i);
        reg [63:0] w;
        w = rbuf[i[6:3]];
        rbyte = w[8 * i[2:0] +: 8];
    endfunction

    // one FIFO push per clock: the coalesced beat leaves when a write to another beat arrives, when it has been
    // idle for 63 clocks, or when a read / command needs the RAM up to date (flush_now)
    wire        wr_win    = wr && hit_win;
    wire        new_beat  = wr_win && (!cw_valid || cw_beat != {bank, addr[16:3]});
    wire        push      = cw_valid && !wf_full && ((wr_win && cw_beat != {bank, addr[16:3]}) ||
                                                     (!wr_win && (cw_age == 6'd63 || flush_now)));
    always @(posedge clk) job_done1 <= job_done;

    always @(posedge clk) begin
        rdata    <= 0;
        play_req <= 1'b0;
        stop_req <= 1'b0;
        if (job_req && job_done1) job_req <= 1'b0;
        if (push) begin
            wf_mem[wf_wp[5:0]] <= {cw_beat, cw_be, cw_data};
            wf_wp <= wf_wp + 1'd1;
        end

        if (reset || !enable) begin
            bank <= 0; busy <= 1'b0; hst <= H_IDLE; rp <= 1'b0; job_req <= 1'b0;
            cw_valid <= 1'b0; wf_wp <= wf_rp1; volume <= 0; sel <= 0;
        end else begin
            // ---- coalescer ageing
            if (cw_valid && !wr_win && cw_age != 6'd63) cw_age <= cw_age + 1'd1;
            if (push && !wr_win) cw_valid <= 1'b0;

            // ---- bus writes
            // register writes: the PSX memory mux presents them word-aligned (addr[1:0] = 0) with byte lanes, so the
            // 16-bit register is picked by the lanes: 0x300000 / 0x30000C = low half, 0x300006 = high half of 0x300004
            if (wr && hit_reg) begin
                if (addr[3:2] == 2'd0 && wmask[1:0] != 0 && wdata[15:0] == 16'd1) begin stop_req <= 1'b1; sel <= 0; end
                if (addr[3:2] == 2'd1 && wmask[3:2] != 0) busy <= 1'b1;                   // 0x300006: command interrupt
                if (addr[3:2] == 2'd3 && wmask[1:0] != 0) bank <= wdata[5:0];             // 0x30000C
            end
            if (wr_win) begin
                // merge into the current beat (the old beat was pushed above if the beat changes)
                if (new_beat) begin
                    cw_beat <= {bank, addr[16:3]};
                    cw_be   <= {addr[2] ? wmask : 4'd0, addr[2] ? 4'd0 : wmask};
                    cw_data <= addr[2] ? {wdata, 32'd0} : {32'd0, wdata};
                end else begin
                    for (int b = 0; b < 4; b++) if (wmask[b]) begin
                        if (addr[2]) begin cw_data[32 + 8 * b +: 8] <= wdata[8 * b +: 8]; cw_be[4 + b] <= 1'b1; end
                        else         begin cw_data[8 * b +: 8]      <= wdata[8 * b +: 8]; cw_be[b]     <= 1'b1; end
                    end
                end
                cw_valid <= 1'b1;
                cw_age   <= 0;
            end

            // ---- bus reads
            if (rd && hit_reg) begin
                case (addr[3:1])
                    3'd3: rdata <= {15'd0, !busy, 16'd0};                  // 0x300006: !busy (upper half)
                    3'd7: rdata <= {16'd1, 16'd0};                         // 0x30000E: 1
                    default: rdata <= 0;
                endcase
            end
            if (rd && hit_win) begin
                if (bank == 6'h3F && addr[16:3] == 14'h3FFE) begin
                    // MCU 0xFFFFF0-0xFFFFF7: ADC registers (AN0 = Y reversed, AN1 = X, AN2/3 = 0)
                    rdata <= addr[2] ? 32'd0 : {adreg(aim_x), adreg(10'd1023 - aim_y)};
                end else begin
                    rp <= 1'b1; rp_off <= addr[16:0]; rp_size <= size;
                end
            end

            // ---- window read / command processing (one at a time; reads first)
            case (hst)
                H_IDLE: begin
                    if (rp || busy) hst <= H_FLUSH;                   // everything written must reach DDR3 first
                end
                H_FLUSH: if (!cw_valid && wf_empty && !job_req) begin
                    if (rp) begin job({1'b0, bank, rp_off} , 4'd1); hst <= H_RDW; end
                    else    begin job(28'h7E0000, 4'd1); hst <= H_CMDW; end          // command at MCU 0xFE0000
                end
                H_RDW: if (job_req && job_done1) hst <= H_RDDONE;
                H_RDDONE: begin
                    // 16-bit (or 32-bit) read of the window
                    rdata <= rp_off[2] ? rbuf[0][63:32] : rbuf[0][31:0];
                    rp    <= 1'b0;
                    hst   <= H_IDLE;
                end
                H_CMDW: if (job_req && job_done1) begin
                    case (rbuf[0][15:0])
                        16'h004C: begin sel <= rbuf[0][31:16]; busy <= 1'b0; hst <= H_IDLE; end
                        16'h0056: begin volume <= (rbuf[0][31:16] > 16'd76) ? 7'd76 : rbuf[0][22:16]; busy <= 1'b0; hst <= H_IDLE; end
                        16'h0053: begin stop_req <= 1'b1; busy <= 1'b0; hst <= H_IDLE; end
                        16'h0050: hst <= H_ENT;
                        default:  begin busy <= 1'b0; hst <= H_IDLE; end
                    endcase
                end
                H_ENT: if (!job_req) begin job(28'h7E0000 + {12'd0, sel}, 4'd1); hst <= H_ENTW; end
                H_ENTW: if (job_req && job_done1) begin
                    s_off <= rbuf[0][23:0];
                    s_len <= rbuf[0][55:32];
                    smp   <= 0;
                    hst   <= H_SMP;
                end
                H_SMP: if (!job_req) begin
                    // 64 bytes at s_off + {0, 0x2000, 0x10000}: 9 beats from the beat holding the first byte
                    smp_sh <= smp_a[2:0];
                    job({4'd0, smp_a}, 4'd9);
                    crc   <= 32'hFFFFFFFF;
                    crc_i <= 0;
                    hst   <= H_SMPW;
                end
                H_SMPW: if (job_req && job_done1) hst <= H_CRC;
                H_CRC: begin
                    crc   <= crc8(crc, rbyte(crc_i + {4'd0, smp_sh}));
                    crc_i <= crc_i + 1'd1;
                    if (crc_i == 7'd63) begin
                        case (smp)
                            2'd0: play_c0 <= ~crc8(crc, rbyte(crc_i + {4'd0, smp_sh}));
                            2'd1: play_c1 <= ~crc8(crc, rbyte(crc_i + {4'd0, smp_sh}));
                            default: play_c2 <= ~crc8(crc, rbyte(crc_i + {4'd0, smp_sh}));
                        endcase
                        if ((smp == 2'd0 && use1) || (smp == 2'd1 && use2)) begin smp <= smp + 1'd1; hst <= H_SMP; end
                        else hst <= H_PLAY;
                    end
                end
                H_PLAY: begin
                    if (!use1) play_c1 <= 0;
                    if (!use2) play_c2 <= 0;
                    play_len <= s_len;
                    play_req <= 1'b1;
                    busy     <= 1'b0;
                    hst      <= H_IDLE;
                end
                default: hst <= H_IDLE;
            endcase
        end
    end
endmodule
