// Namco System 10 MEM(P3): plays the pre-converted MP3 board audio (tools/p3audio.py .p3a file on SD slot 0).
// Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later
//
// A play request from s10_p3 carries the stream's length and three CRC-32 samples. The player scans the file's
// index (32-byte entries after a 32-byte header) for the entry with the same samples whose MP3 length F satisfies
// F <= length < F + 2048 (the games store lengths rounded up to 2 KB), then streams that entry's PCM (16-bit stereo,
// 44.1 kHz, 1 KB aligned) through a 16 KB ring and outputs one frame per 768 clk (33.8688 MHz / 44100), scaled by
// the LC82310 volume (MAME's attenuation table). A stop request or a new play request ends the current stream.
module s10_p3audio (
    input  wire          clk,               // clk_1x, 33.8688 MHz
    input  wire          reset,
    input  wire          enable,

    input  wire          play_req,
    input  wire  [23:0]  play_len,
    input  wire  [31:0]  play_c0,
    input  wire  [31:0]  play_c1,
    input  wire  [31:0]  play_c2,
    input  wire          stop_req,
    input  wire   [6:0]  volume,

    output reg signed [15:0] audio_l = 0,
    output reg signed [15:0] audio_r = 0,

    // hps_io slot 0 (1 KB blocks, 16-bit data, up to 4 blocks per request)
    output reg   [31:0]  sd_lba = 0,
    output reg    [5:0]  sd_blk_cnt = 0,
    output reg           sd_rd = 1'b0,
    input  wire          sd_ack,
    input  wire  [12:0]  sd_buff_addr,
    input  wire  [15:0]  sd_buff_dout,
    input  wire          sd_buff_wr,
    input  wire          img_mounted,
    input  wire  [63:0]  img_size
);
    function automatic [11:0] gain_of(input [6:0] v);
        case (v)
            7'd0: gain_of = 12'd4095;
            7'd1: gain_of = 12'd3964;
            7'd2: gain_of = 12'd3832;
            7'd3: gain_of = 12'd3700;
            7'd4: gain_of = 12'd3567;
            7'd5: gain_of = 12'd3435;
            7'd6: gain_of = 12'd3303;
            7'd7: gain_of = 12'd3171;
            7'd8: gain_of = 12'd3039;
            7'd9: gain_of = 12'd2907;
            7'd10: gain_of = 12'd2775;
            7'd11: gain_of = 12'd2643;
            7'd12: gain_of = 12'd2510;
            7'd13: gain_of = 12'd2378;
            7'd14: gain_of = 12'd2246;
            7'd15: gain_of = 12'd2114;
            7'd16: gain_of = 12'd1982;
            7'd17: gain_of = 12'd1850;
            7'd18: gain_of = 12'd1718;
            7'd19: gain_of = 12'd1586;
            7'd20: gain_of = 12'd1453;
            7'd21: gain_of = 12'd1321;
            7'd22: gain_of = 12'd1189;
            7'd23: gain_of = 12'd1123;
            7'd24: gain_of = 12'd1057;
            7'd25: gain_of = 12'd925;
            7'd26: gain_of = 12'd793;
            7'd27: gain_of = 12'd727;
            7'd28: gain_of = 12'd661;
            7'd29: gain_of = 12'd595;
            7'd30: gain_of = 12'd529;
            7'd31: gain_of = 12'd462;
            7'd32: gain_of = 12'd396;
            7'd33: gain_of = 12'd363;
            7'd34: gain_of = 12'd330;
            7'd35: gain_of = 12'd297;
            7'd36: gain_of = 12'd264;
            7'd37: gain_of = 12'd242;
            7'd38: gain_of = 12'd220;
            7'd39: gain_of = 12'd198;
            7'd40: gain_of = 12'd176;
            7'd41: gain_of = 12'd154;
            7'd42: gain_of = 12'd132;
            7'd43: gain_of = 12'd128;
            7'd44: gain_of = 12'd124;
            7'd45: gain_of = 12'd120;
            7'd46: gain_of = 12'd117;
            7'd47: gain_of = 12'd113;
            7'd48: gain_of = 12'd109;
            7'd49: gain_of = 12'd105;
            7'd50: gain_of = 12'd101;
            7'd51: gain_of = 12'd97;
            7'd52: gain_of = 12'd93;
            7'd53: gain_of = 12'd89;
            7'd54: gain_of = 12'd85;
            7'd55: gain_of = 12'd82;
            7'd56: gain_of = 12'd78;
            7'd57: gain_of = 12'd74;
            7'd58: gain_of = 12'd70;
            7'd59: gain_of = 12'd66;
            7'd60: gain_of = 12'd62;
            7'd61: gain_of = 12'd58;
            7'd62: gain_of = 12'd54;
            7'd63: gain_of = 12'd51;
            7'd64: gain_of = 12'd47;
            7'd65: gain_of = 12'd43;
            7'd66: gain_of = 12'd39;
            7'd67: gain_of = 12'd35;
            7'd68: gain_of = 12'd31;
            7'd69: gain_of = 12'd27;
            7'd70: gain_of = 12'd23;
            7'd71: gain_of = 12'd19;
            7'd72: gain_of = 12'd16;
            7'd73: gain_of = 12'd12;
            7'd74: gain_of = 12'd8;
            7'd75: gain_of = 12'd4;
            7'd76: gain_of = 12'd0;
            default: gain_of = 12'd0;
        endcase
    endfunction

    reg         disc = 1'b0;                     // a .p3a file is mounted
    always @(posedge clk) if (img_mounted) disc <= (img_size != 0);

    // ---------------------------------------------------------------------------------------------- ring buffer
    reg  [15:0] ring [0:8191];                   // 16 KB of 16-bit words (93 ms)
    reg  [12:0] r_wp = 0, r_rp = 0;              // r_wp: first word of the next fetched block
    reg  [14:0] r_cnt = 0;                       // words fetched and not yet played
    reg  [15:0] r_q = 0;
    reg  [12:0] r_ra = 0;
    reg         r_we = 1'b0;
    reg  [12:0] r_wa = 0;
    reg  [15:0] r_wd = 0;
    always @(posedge clk) begin
        r_q <= ring[r_ra];
        if (r_we) ring[r_wa] <= r_wd;
    end

    // ---------------------------------------------------------------------------------------------- state
    localparam [1:0] A_IDLE = 2'd0, A_SCAN = 2'd1, A_SCANW = 2'd2, A_PLAY = 2'd3;
    reg   [1:0] ast = A_IDLE;
    reg  [23:0] q_len = 0;
    reg  [31:0] q_c0 = 0, q_c1 = 0, q_c2 = 0;
    reg  [31:0] scan_blk = 0;                    // index block being read
    reg  [31:0] n_entries = 0, entry = 0;        // entries in the file / entries parsed
    reg  [31:0] e_len = 0, e_c0 = 0, e_c1 = 0, e_c2 = 0, e_start = 0;
    reg  [15:0] e_frames_lo = 0;
    reg         found = 1'b0;
    reg  [31:0] pcm_blk = 0, frames = 0, blocks_left = 0;
    reg         fetching = 1'b0;
    reg   [2:0] f_n = 0;
    reg   [9:0] tick = 0;
    reg signed [15:0] s_l = 0;

    wire        req_done = !sd_rd && !sd_ack;    // no SD request outstanding
    wire        can_out  = (frames != 0) && (r_cnt >= 15'd2);
    wire signed [12:0] g = $signed({1'b0, gain_of(volume)});

    // An entry is the stream when its samples match and its length F fits the game's length T: normally
    // F <= T < F + 2048 (the game's length is the file's, or rounded up to 2 KB, or includes a 128-byte ID3v1 tag);
    // failing that, F - 1024 <= T < F (Seishun Quiz's table stops inside the zero-padded tail of the last frame)
    function automatic keys(input [31:0] c0, input [31:0] c1, input [31:0] c2);
        keys = (c0 == q_c0) && (q_len < 24'h003000 || c1 == q_c1) && (q_len < 24'h012000 || c2 == q_c2);
    endfunction
    function automatic match(input [31:0] f, input [31:0] c0, input [31:0] c1, input [31:0] c2);
        match = keys(c0, c1, c2) && ({8'd0, q_len} >= f) && ({8'd0, q_len} < f + 32'd2048);
    endfunction
    function automatic match_short(input [31:0] f, input [31:0] c0, input [31:0] c1, input [31:0] c2);
        match_short = keys(c0, c1, c2) && ({8'd0, q_len} < f) && ({8'd0, q_len} + 32'd1024 >= f);
    endfunction
    reg         fb = 1'b0;                       // a match_short entry was seen (used if no exact match follows)
    reg  [31:0] fb_start = 0, fb_frames = 0;

    always @(posedge clk) begin
        reg [14:0] add, sub;
        reg        clr;                          // new stream: empty the ring
        r_we <= 1'b0;
        add = 0; sub = 0; clr = 1'b0;
        if (reset || !enable) begin
            ast <= A_IDLE; sd_rd <= 1'b0; fetching <= 1'b0; audio_l <= 0; audio_r <= 0;
            r_cnt <= 0; r_wp <= 0; r_rp <= 0; frames <= 0;
        end else begin
            if (sd_rd && sd_ack) sd_rd <= 1'b0;

            // ---- SD data: index words or PCM
            if (sd_buff_wr) begin
                if (ast == A_SCANW && !found) begin
                    if (scan_blk == 0 && sd_buff_addr == 13'd4) n_entries[15:0]  <= sd_buff_dout;
                    if (scan_blk == 0 && sd_buff_addr == 13'd5) n_entries[31:16] <= sd_buff_dout;
                    if (scan_blk != 0 || sd_buff_addr >= 13'd16) begin
                        case (sd_buff_addr[3:0])           // word k of a 16-word entry
                            4'd0:  e_len[15:0]   <= sd_buff_dout;   4'd1:  e_len[31:16]   <= sd_buff_dout;
                            4'd2:  e_c0[15:0]    <= sd_buff_dout;   4'd3:  e_c0[31:16]    <= sd_buff_dout;
                            4'd4:  e_c1[15:0]    <= sd_buff_dout;   4'd5:  e_c1[31:16]    <= sd_buff_dout;
                            4'd6:  e_c2[15:0]    <= sd_buff_dout;   4'd7:  e_c2[31:16]    <= sd_buff_dout;
                            4'd8:  e_start[15:0] <= sd_buff_dout;   4'd9:  e_start[31:16] <= sd_buff_dout;
                            4'd10: e_frames_lo   <= sd_buff_dout;
                            4'd11: begin
                                if (entry < n_entries && match(e_len, e_c0, e_c1, e_c2)) begin
                                    found   <= 1'b1;
                                    pcm_blk <= e_start;
                                    frames  <= {sd_buff_dout, e_frames_lo};
                                end else if (entry < n_entries && !fb && match_short(e_len, e_c0, e_c1, e_c2)) begin
                                    fb        <= 1'b1;
                                    fb_start  <= e_start;
                                    fb_frames <= {sd_buff_dout, e_frames_lo};
                                end
                                entry <= entry + 1'd1;
                            end
                            default: ;
                        endcase
                    end
                end else if (ast == A_PLAY && fetching) begin
                    r_we <= 1'b1; r_wa <= r_wp + {2'b0, sd_buff_addr[10:0]}; r_wd <= sd_buff_dout;
                end
            end

            case (ast)
                A_IDLE: ;
                A_SCAN: if (req_done) begin
                    sd_lba <= scan_blk; sd_blk_cnt <= 6'd0; sd_rd <= 1'b1; ast <= A_SCANW;
                end
                A_SCANW: if (req_done) begin
                    if (found) begin
                        blocks_left <= (frames + 32'd255) >> 8;          // 256 stereo frames per 1 KB block
                        r_wp <= 0; r_rp <= 0; clr = 1'b1; tick <= 0; fetching <= 1'b0;
                        ast <= A_PLAY;
                    end else if (entry >= n_entries && fb) begin         // only the slightly longer file matched
                        found <= 1'b1; pcm_blk <= fb_start; frames <= fb_frames;
                        // A_SCANW again with found set: starts the stream on the next clock
                    end else if (entry >= n_entries) ast <= A_IDLE;      // not in the file: silence
                    else begin scan_blk <= scan_blk + 1'd1; ast <= A_SCAN; end
                end
                A_PLAY: begin
                    // fetch up to 4 blocks per request while the ring has room
                    if (!fetching && req_done && blocks_left != 0 && r_cnt <= 15'd6144) begin
                        f_n        <= (blocks_left >= 4) ? 3'd4 : blocks_left[2:0];
                        sd_lba     <= pcm_blk;
                        sd_blk_cnt <= ((blocks_left >= 4) ? 6'd4 : {3'd0, blocks_left[2:0]}) - 6'd1;
                        sd_rd      <= 1'b1;
                        fetching   <= 1'b1;
                    end else if (fetching && req_done) begin
                        fetching    <= 1'b0;
                        pcm_blk     <= pcm_blk + f_n;
                        blocks_left <= blocks_left - f_n;
                        r_wp        <= r_wp + {f_n, 9'd0};
                        add         = {f_n, 9'd0};
                    end
                    // output: one stereo frame every 768 clocks (left word at tick 2, right at tick 4)
                    tick <= (tick == 10'd767) ? 10'd0 : tick + 1'd1;
                    if (tick == 10'd0 && can_out) r_ra <= r_rp;
                    if (tick == 10'd2 && can_out) begin s_l <= r_q; r_ra <= r_rp + 1'd1; end
                    if (tick == 10'd4 && can_out) begin
                        audio_l <= 16'((32'(s_l) * g) >>> 12);
                        audio_r <= 16'((32'($signed(r_q)) * g) >>> 12);
                        r_rp    <= r_rp + 2'd2;
                        frames  <= frames - 1'd1;
                        sub     = 15'd2;
                    end
                    if (frames == 0 && !fetching) begin audio_l <= 0; audio_r <= 0; ast <= A_IDLE; end
                end
                default: ast <= A_IDLE;
            endcase
            r_cnt <= clr ? 15'd0 : r_cnt + add - sub;

            // ---- requests (after the state machine: they win)
            if (stop_req) begin ast <= A_IDLE; frames <= 0; audio_l <= 0; audio_r <= 0; end
            if (play_req && disc) begin
                q_len <= play_len; q_c0 <= play_c0; q_c1 <= play_c1; q_c2 <= play_c2;
                scan_blk <= 0; entry <= 0; n_entries <= 32'hFFFFFFFF; found <= 1'b0; frames <= 0; fb <= 1'b0;
                audio_l <= 0; audio_r <= 0;
                ast <= A_SCAN;
            end
        end
    end
endmodule
