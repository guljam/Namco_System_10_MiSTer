// Namco System 10 MEM ROM board: MEM(M) (Intel 28F640J5 flash + mask ROMs, KEYCUS type-1 decrypter) and
// MEM(N) (K9F2808U0B / K9F5608U0D NAND, KEYCUS type-2 decrypter, bad-block-table SRAM).
// Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later
//
// Behaviour follows MAME 0.289: namcos10.cpp (namcos10_memm_state / namcos10_memn_state), nandflash.cpp,
// intelfsh.cpp (16-bit Intel StrataFlash) and ns10crypt.cpp. See docs/ARCHITECTURE.md section 3.2.
//
// All ROM-board images live in DDR3 (byte offset img_base from 0x30000000):
//   MEM(M): flash (8 MB) at +0, data mask ROMs at +0x800000, stored as MAME's little-endian 16-bit words.
//   MEM(N): NAND chip k at +k*chip_bytes (0x1080000 / 0x2100000), raw 0x210-byte pages (0x200 data + 0x10 spare).
// Reads go through a buffer filled from DDR3: MEM(N) one NAND page (528 bytes), MEM(M) a 64-byte line.
// Program/erase write the DDR3 image directly. The MRA <nvram> is a window of the image (save_base): it is
// uploaded from DDR3 here and loaded into DDR3 by the top-level load writer.
//
// Bus semantics (MAME 16-bit handlers on the 32-bit bus): a word access is two 16-bit handler calls, low half
// (addr+0) first, then high half (addr+2); a byte/half access is one call for the half it falls in. The full
// aligned word is returned; the memory mux selects the bytes.
//
// Clocks: clk (= clk_1x: CPU bus, SDRAM channel 3, ioctl) and clk2 (= clk_2x: DDR3 arbiter), from one PLL.
module s10_mem (
    input  wire          clk,
    input  wire          clk2,
    input  wire          reset,

    // ---- board record (static while a game runs)
    input  wire          board_memn,         // 0 = MEM(M), 1 = MEM(N)
    input  wire   [1:0]  crypt_type,         // 0 none, 1 type 1 (MEM(M)), 2 type 2 (MEM(N))
    input  wire   [4:0]  nand_count,         // MEM(N): number of NAND chips
    input  wire          nand_big,           // MEM(N): K9F5608U0D (65536 pages, sequential row read)
    input  wire  [15:0]  data_xor,           // MEM(N) descramble XOR (MEM(M) flash banks always use 0xAAAA)
    input  wire  [63:0]  perm,               // descramble: perm[4*i+3:4*i] = source bit of output bit i
    input  wire  [27:0]  img_base,           // DDR3 byte offset (from 0x30000000) of the image
    input  wire  [27:0]  save_base,          // image byte offset of the nvram window
    input  wire [1023:0] t2_emask,
    input  wire [1023:0] t2_dmask,
    input  wire  [15:0]  t2_xmask,
    input  wire [1023:0] t2_iv,
    input  wire  [63:0]  t2_nl_ac, t2_nl_ap, t2_nl_bc, t2_nl_bp,
    input  wire  [15:0]  t2_nl_out,

    // ---- board bus (CPU address bits 23..0)
    input  wire  [23:0]  addr,
    input  wire  [31:0]  wdata,
    input  wire   [3:0]  wmask,
    input  wire   [1:0]  size,               // 00 byte, 01 half, 10 word
    input  wire          rd,
    input  wire          wr,
    output reg   [31:0]  rdata = '0,          // zero unless completing a read (OR-ed board bus)
    output wire          stall,

    // ---- PSX DMA channel 5 (MEM(N) "PIO" DMA: a 32-bit word = two data-register reads, low half first)
    input  wire          rdma_start,
    output wire          rdma_valid,
    input  wire          rdma_pop,
    output wire  [31:0]  rdma_data,

    // ---- SDRAM channel 3 client: MEM(N) SRAM at 0x1F500000 (bad-block table, 1 MB window as MAME)
    output reg           sram_req = 1'b0,
    output reg   [19:0]  sram_addr = '0,
    output reg           sram_rnw = 1'b1,
    output reg    [3:0]  sram_be = '0,
    output reg   [31:0]  sram_wdata = '0,
    input  wire  [31:0]  sram_rdata,
    input  wire          sram_ready,

    // ---- nvram upload (hps_io, clk domain): ioctl_rd + ioctl_addr -> ioctl_din, held by ioctl_wait
    input  wire          up_active,
    input  wire          up_rd,
    input  wire  [26:0]  up_addr,
    output reg   [15:0]  up_din = '0,
    output wire          up_wait,
    output reg           save_req = 1'b0,    // pulse ~1.5 s after the last program/erase

    // ---- DDR3 client (clk2 domain), into psx_top's arbiter (single-beat writes, burst reads)
    output reg           ddr_request = 1'b0,
    input  wire          ddr_ack,
    output reg    [7:0]  ddr_burstcnt = '0,
    output reg   [27:0]  ddr_addr = '0,
    output reg   [63:0]  ddr_din = '0,
    output reg    [7:0]  ddr_be = '0,
    output reg           ddr_we = 1'b0,
    output reg           ddr_rd = 1'b0,
    input  wire  [63:0]  ddr_dout,
    input  wire          ddr_dout_ready
);
    // =====================================================================================================
    // Descrambler: MAME m_unscrambler = bitswap<16>(d, s15, ..., s0)
    // =====================================================================================================
    function automatic [15:0] unscramble(input [15:0] d, input [63:0] p);
        for (int i = 0; i < 16; i++) unscramble[i] = d[p[4*i +: 4]];
    endfunction

    // =====================================================================================================
    // Decrypters: plain = f(state, cipher) is combinational; the state advances on word_valid
    // =====================================================================================================
    reg         cr_act_p = 1'b0, cr_deact_p = 1'b0, cr_step = 1'b0;
    reg   [3:0] cr_iv = '0;
    reg  [15:0] cr_cipher = '0;
    wire [15:0] t1_plain, t2_plain;
    wire        t1_active, t2_active;

    s10_crypt_t1 crypt_t1 (
        .clk(clk), .reset(reset || crypt_type != 2'd1),
        .activate(cr_act_p), .iv(cr_iv), .deactivate(cr_deact_p),
        .word_valid(cr_step && crypt_type == 2'd1), .cipher(cr_cipher),
        .plain(t1_plain), .active(t1_active)
    );
    s10_crypt_t2 crypt_t2 (
        .clk(clk), .reset(reset || crypt_type != 2'd2),
        .activate(cr_act_p), .iv(cr_iv), .deactivate(cr_deact_p),
        .word_valid(cr_step && crypt_type == 2'd2), .cipher(cr_cipher),
        .emask(t2_emask), .dmask(t2_dmask), .xmask(t2_xmask), .ivtab(t2_iv),
        .nl_ac(t2_nl_ac), .nl_ap(t2_nl_ap), .nl_bc(t2_nl_bc), .nl_bp(t2_nl_bp), .nl_out(t2_nl_out),
        .plain(t2_plain), .active(t2_active)
    );
    wire        cr_active = (crypt_type == 2'd1) ? t1_active : (crypt_type == 2'd2) ? t2_active : 1'b0;
    wire [15:0] cr_plain  = (crypt_type == 2'd1) ? t1_plain  : t2_plain;

    // =====================================================================================================
    // Buffers (8 byte lanes x 128, clocked by clk2): PAGE (DDR3 data) and PGM (NAND page register)
    // =====================================================================================================
    reg   [7:0] pg_lane [0:7][0:127];
    reg   [7:0] pm_lane [0:7][0:127];
    reg   [7:0] pg_q [0:7];
    reg   [7:0] pm_q [0:7];

    reg         eng_pg_we = 1'b0;          // clk2: DDR3 beat -> PAGE
    reg   [6:0] eng_pg_wi = '0;
    reg  [63:0] eng_pg_wd = '0;
    reg         eng_rd_own = 1'b0;         // clk2: engine owns the read index (program write-back)
    reg   [6:0] eng_ri = '0;
    reg   [9:0] fsm_rb = '0;               // clk: byte offset the FSM reads from PAGE
    reg         pm_we = 1'b0;              // clk: one byte into PGM
    reg   [9:0] pm_wa = '0;
    reg   [7:0] pm_wd = '0;
    reg [527:0] pm_written = '0;           // PGM byte written since 0x80 (unwritten bytes program as 0xFF)

    always @(posedge clk2) begin
        for (int l = 0; l < 8; l++) begin
            if (eng_pg_we)                      pg_lane[l][eng_pg_wi]   <= eng_pg_wd[8*l +: 8];
            if (pm_we && pm_wa[2:0] == l[2:0])  pm_lane[l][pm_wa[9:3]]  <= pm_wd;
            pg_q[l] <= pg_lane[l][eng_rd_own ? eng_ri : fsm_rb[9:3]];
            pm_q[l] <= pm_lane[l][eng_ri];
        end
    end
    wire [7:0] fsm_byte = pg_q[fsm_rb[2:0]];   // valid one clk after fsm_rb changes

    // =====================================================================================================
    // DDR3 engine (clk2). Jobs come from the clk FSM with a 4-phase handshake (job_req / job_done).
    // =====================================================================================================
    localparam [1:0] J_FETCH = 2'd0,       // read job_beats beats at job_addr into PAGE[0..]
                     J_WBACK = 2'd1,       // write PAGE & PGM back (NAND program), job_beats beats
                     J_FILL  = 2'd2,       // write job_beats beats of 0xFF (erase)
                     J_WRITE = 2'd3;       // write one beat job_d64 with job_be
    localparam int   BURST   = 32;

    reg         job_req   = 1'b0;          // clk
    reg   [1:0] job_type  = '0;
    reg  [27:0] job_addr  = '0;            // image byte offset, 8-aligned
    reg  [13:0] job_beats = '0;
    reg  [63:0] job_d64   = '0;
    reg   [7:0] job_be    = '0;
    reg         job_done  = 1'b0;          // clk2

    localparam [2:0] E_IDLE = 3'd0, E_RDREQ = 3'd1, E_RD = 3'd2, E_WRPREP = 3'd3, E_WRREQ = 3'd4, E_WR = 3'd5;
    reg   [2:0] est = E_IDLE;
    reg  [13:0] e_left = '0;               // beats still to transfer
    reg   [7:0] e_burst = '0;              // beats left in the current read burst
    reg   [6:0] e_idx = '0;
    reg  [27:0] e_addr = '0;
    reg         e_acked = 1'b0;

    always @(posedge clk2) begin
        eng_pg_we <= 1'b0;
        if (reset) begin
            est <= E_IDLE; job_done <= 1'b0; eng_rd_own <= 1'b0;
            ddr_request <= 1'b0; ddr_we <= 1'b0; ddr_rd <= 1'b0;
        end else begin
            case (est)
                E_IDLE: begin
                    if (!job_req) job_done <= 1'b0;
                    if (job_req && !job_done) begin
                        e_addr <= img_base + job_addr;
                        e_left <= job_beats;
                        e_idx  <= '0;
                        eng_ri <= '0;
                        if (job_type == J_FETCH) est <= E_RDREQ;
                        else begin
                            eng_rd_own <= (job_type == J_WBACK);
                            est        <= E_WRPREP;
                        end
                    end
                end
                E_RDREQ: begin
                    e_burst      <= (e_left > BURST) ? 8'(BURST) : e_left[7:0];
                    ddr_burstcnt <= (e_left > BURST) ? 8'(BURST) : e_left[7:0];
                    ddr_addr     <= e_addr;
                    ddr_request  <= 1'b1;
                    ddr_rd       <= 1'b1;
                    ddr_we       <= 1'b0;
                    e_acked      <= 1'b0;
                    est          <= E_RD;
                end
                E_RD: begin
                    if (ddr_ack) begin e_acked <= 1'b1; ddr_rd <= 1'b0; end
                    if (ddr_dout_ready && (e_acked || ddr_ack)) begin
                        eng_pg_we <= 1'b1;
                        eng_pg_wi <= e_idx;
                        eng_pg_wd <= ddr_dout;
                        e_idx     <= e_idx + 1'd1;
                        e_left    <= e_left - 1'd1;
                        e_addr    <= e_addr + 28'd8;
                        e_burst   <= e_burst - 1'd1;
                        if (e_burst == 8'd1) begin
                            ddr_request <= 1'b0;
                            est         <= (e_left == 14'd1) ? E_IDLE : E_RDREQ;
                            if (e_left == 14'd1) job_done <= 1'b1;
                        end
                    end
                end
                E_WRPREP: est <= E_WRREQ;            // PAGE/PGM read latency for eng_ri
                E_WRREQ: begin
                    ddr_request  <= 1'b1;
                    ddr_we       <= 1'b1;
                    ddr_rd       <= 1'b0;
                    ddr_burstcnt <= 8'd1;
                    ddr_addr     <= e_addr;
                    case (job_type)
                        J_WBACK: begin
                            for (int l = 0; l < 8; l++)
                                ddr_din[8*l +: 8] <= pg_q[l] & (pm_written[{e_idx, l[2:0]}] ? pm_q[l] : 8'hFF);
                            ddr_be <= 8'hFF;
                        end
                        J_FILL:  begin ddr_din <= {64{1'b1}}; ddr_be <= 8'hFF;   end
                        default: begin ddr_din <= job_d64;    ddr_be <= job_be;  end
                    endcase
                    est <= E_WR;
                end
                E_WR: begin
                    if (ddr_ack) begin
                        ddr_request <= 1'b0;
                        ddr_we      <= 1'b0;
                        e_addr      <= e_addr + 28'd8;
                        e_idx       <= e_idx + 1'd1;
                        eng_ri      <= e_idx + 1'd1;
                        e_left      <= e_left - 1'd1;
                        if (e_left == 14'd1) begin
                            eng_rd_own <= 1'b0;
                            job_done   <= 1'b1;
                            est        <= E_IDLE;
                        end else est <= E_WRPREP;
                    end
                end
                default: est <= E_IDLE;
            endcase
        end
    end

    // =====================================================================================================
    // NAND chips (MAME nand_device), one state set per chip
    // =====================================================================================================
    localparam [2:0] NM_INIT = 3'd0, NM_READ = 3'd1, NM_PROGRAM = 3'd2, NM_ERASE = 3'd3, NM_STATUS = 3'd4, NM_ID = 3'd5;
    localparam [1:0] PM_A = 2'd0, PM_B = 2'd1, PM_C = 2'd2;
    reg   [2:0] n_mode  [0:15];
    reg   [1:0] n_pmode [0:15];
    reg  [15:0] n_page  [0:15];
    reg   [9:0] n_byte  [0:15];
    reg   [1:0] n_aload [0:15];
    reg   [9:0] n_pgmcnt = '0;
    reg   [3:0] nand_idx = '0;
    reg  [15:0] nand_ctrl = '0;
    reg  [23:0] nand_address = '0;         // MAME m_nand_address: column | row << 8 | page << 16

    wire [16:0] nand_pages   = nand_big ? 17'd65536 : 17'd32768;
    wire [27:0] chip_bytes   = nand_big ? 28'h2100000 : 28'h1080000;
    wire        chip_present = ({1'b0, nand_idx} < nand_count);
    wire  [2:0] cur_mode     = n_mode[nand_idx];
    wire  [1:0] cur_pmode    = n_pmode[nand_idx];
    wire [15:0] cur_page     = n_page[nand_idx];
    wire  [9:0] cur_byte     = n_byte[nand_idx];
    wire  [1:0] cur_aload    = n_aload[nand_idx];
    wire [27:0] cur_pagebase = nand_idx * chip_bytes + cur_page * 28'd528;
    wire        cur_inpage   = (cur_byte < 10'd528) && ({1'b0, cur_page} < nand_pages);
    // reading past the page end: K9F5608U0D continues with the next page (sequential row read)
    wire  [9:0] next_byte    = (nand_big && cur_byte == 10'd527) ? ((cur_pmode != PM_C) ? 10'd0 : 10'd512) : cur_byte + 1'd1;
    wire [15:0] next_page    = (nand_big && cur_byte == 10'd527) ? cur_page + 1'd1 : cur_page;
    // program data register wraps at the page end (MAME data_w)
    wire  [9:0] pgm_next     = (cur_byte == 10'd527) ? ((cur_pmode != PM_C) ? 10'd0 : 10'd512) : cur_byte + 1'd1;

    // =====================================================================================================
    // MEM(M) state: bank window + Intel 28F640J5 command interface
    // =====================================================================================================
    reg   [4:0] bank_idx = '0;
    reg         bank_direct = 1'b0;        // MAME m_bank_access_nand_direct
    localparam [2:0] FM_NORMAL = 3'd0, FM_STATUS = 3'd1, FM_ID = 3'd2, FM_WRITE1 = 3'd3, FM_CLEAR1 = 3'd4,
                     FM_SETMASTER = 3'd5, FM_WBUF1 = 3'd6, FM_WBUF2 = 3'd7;
    reg   [2:0] fmode = FM_NORMAL;
    reg   [7:0] fstatus = 8'h80;
    reg         fmaster = 1'b0;
    reg   [4:0] wb_n = '0, wb_count = '0;
    reg  [22:0] wb_start = '0;             // word address
    reg  [15:0] wb_data [0:15];
    reg  [25:0] ferase_timer = '0;         // after an erase, status reads 0x80 again after ~1 s (MAME)

    // =====================================================================================================
    // Buffer tag
    // =====================================================================================================
    reg         tag_valid = 1'b0;
    reg  [27:0] tag_base  = '0;            // image byte offset of buffer byte 0

    // =====================================================================================================
    // CPU-side sequencer (clk)
    // =====================================================================================================
    wire mine_w = (addr[23:20] == 4'h3) || (addr[23:20] == 4'h4) || (addr[23:20] == 4'h5) || (addr[23:17] == 7'b1011_010);
    wire mine_r = (addr[23:20] == 4'h4) || (addr[23:20] == 4'h5) || (addr[23:17] == 7'b1011_010);

    reg  [23:0] wq_a [0:3];                // pending CPU writes (writes never stall the CPU)
    reg  [31:0] wq_d [0:3];
    reg   [3:0] wq_m [0:3];
    reg   [2:0] wq_wp = '0, wq_rp = '0;
    wire        wq_empty = (wq_wp == wq_rp);

    reg         rd_pend = 1'b0;            // a CPU read is outstanding (stalls the bus)
    reg  [23:0] rd_a = '0;
    reg   [1:0] rd_size = '0;
    assign stall = rd_pend;

    localparam [5:0]
        S_IDLE   = 6'd0,  S_RHALF  = 6'd1,  S_RNEXT  = 6'd2,  S_RDONE  = 6'd3,
        S_NB     = 6'd4,  S_NBQ    = 6'd5,  S_NBDONE = 6'd6,  S_DEC1   = 6'd7,  S_DEC2   = 6'd8,
        S_WIN    = 6'd9,  S_WW0    = 6'd10, S_WW1    = 6'd11, S_WW2    = 6'd12,
        S_SRAM   = 6'd13, S_SRAMW  = 6'd14,
        S_JOBW   = 6'd15, S_PGMWB  = 6'd16,
        S_WHALF  = 6'd17, S_WNEXT  = 6'd18, S_NDLO   = 6'd19, S_FLASH  = 6'd20, S_WBCOMMIT = 6'd21,
        S_UP     = 6'd22, S_UPQ0   = 6'd23, S_UPQ1   = 6'd24, S_UPQ2   = 6'd25;
    reg   [5:0] st = S_IDLE;
    reg   [5:0] st_ret = S_IDLE;           // where S_JOBW / the line reader return to

    reg         t_write = 1'b0;            // current transaction: write
    reg         t_dma = 1'b0;              // current transaction: DMA word
    reg  [23:0] t_a = '0;
    reg  [31:0] t_d = '0;
    reg   [3:0] t_m = '0;
    reg   [1:0] t_sz = '0;
    reg         t_h = 1'b0;                // current half: 0 = addr+0, 1 = addr+2
    reg  [31:0] t_res = '0;
    reg  [15:0] h_val = '0;                // result of the current 16-bit handler
    reg         nb_second = 1'b0;          // NAND: second byte of the 16-bit read
    reg  [15:0] nb_word = '0;
    reg  [27:0] want = '0;                 // image byte offset wanted from the buffer
    reg         win_unscr = 1'b0;          // MEM(M): window word goes through descramble/decrypt
    reg   [7:0] w_lo = '0;

    wire [23:0] t_ha   = {t_a[23:2], t_h, 1'b0};
    wire        t_hsel = t_write ? (t_h ? (t_m[3:2] != 2'b00) : (t_m[1:0] != 2'b00))
                                 : (t_h ? (t_sz == 2'b10 || t_a[1]) : (t_sz == 2'b10 || !t_a[1]));
    wire [15:0] t_d16  = t_h ? t_d[31:16] : t_d[15:0];
    wire        t_b0   = t_h ? t_m[2] : t_m[0];          // byte lane 0 of the half (8-bit registers)
    wire        is_sram = board_memn && (t_a[23:20] == 4'h5);

    // MEM(M) window: word address bank*0x100000 + offset, and its image byte offset
    wire [19:0] win_off  = t_ha[20:1];
    wire [24:0] win_word = {bank_idx, win_off};
    wire  [4:0] dbank    = bank_idx - 5'h10;
    wire [27:0] win_img  = (bank_idx < 5'h10) ? {2'b00, win_word, 1'b0}
                                              : 28'h800000 + {2'b00, dbank, win_off, 1'b0};

    // DMA words (on demand, one at a time: each word advances the NAND pointer by four bytes)
    reg  [31:0] dq_word = '0;
    reg         dq_full = 1'b0;
    reg         dma_on  = 1'b0;
    assign rdma_valid = dq_full;
    assign rdma_data  = dq_word;

    // nvram upload / autosave
    reg         up_busy = 1'b0;
    assign up_wait = up_busy;
    reg  [26:0] save_timer = '0;
    reg         dirty = 1'b0;

    task automatic start_job(input [1:0] ty, input [27:0] a, input [13:0] beats, input [5:0] ret);
        job_type  <= ty;
        job_addr  <= a;
        job_beats <= beats;
        job_req   <= 1'b1;
        st_ret    <= ret;
        st        <= S_JOBW;
    endtask

    task automatic mark_dirty;
        dirty      <= 1'b1;
        save_timer <= 27'd50_000_000;
        tag_valid  <= 1'b0;
    endtask

    always @(posedge clk) begin
        pm_we      <= 1'b0;
        cr_act_p   <= 1'b0;
        cr_deact_p <= 1'b0;
        cr_step    <= 1'b0;
        save_req   <= 1'b0;
        rdata      <= '0;

        // ---- bus capture (any state)
        if (wr && mine_w) begin
            wq_a[wq_wp[1:0]] <= addr;
            wq_d[wq_wp[1:0]] <= wdata;
            wq_m[wq_wp[1:0]] <= wmask;
            wq_wp            <= wq_wp + 1'd1;
        end
        if (rd && mine_r) begin
            rd_pend <= 1'b1;
            rd_a    <= addr;
            rd_size <= size;
        end
        if (rdma_start) dma_on <= board_memn;
        if (rdma_pop && dq_full) dq_full <= 1'b0;

        // ---- timers
        if (ferase_timer != 0) begin
            ferase_timer <= ferase_timer - 1'd1;
            if (ferase_timer == 26'd1 && fmode == FM_STATUS) fstatus <= 8'h80;
        end
        if (save_timer != 0) begin
            save_timer <= save_timer - 1'd1;
            if (save_timer == 27'd1 && dirty) begin save_req <= 1'b1; dirty <= 1'b0; end
        end

        if (reset) begin
            st <= S_IDLE; rd_pend <= 1'b0; wq_rp <= wq_wp; job_req <= 1'b0; tag_valid <= 1'b0;
            bank_idx <= '0; bank_direct <= 1'b0; fmode <= FM_NORMAL; fstatus <= 8'h80; fmaster <= 1'b0;
            nand_idx <= '0; nand_ctrl <= '0; nand_address <= '0; dma_on <= 1'b0; dq_full <= 1'b0;
            up_busy <= 1'b0; sram_req <= 1'b0;
            for (int c = 0; c < 16; c++) begin
                n_mode[c] <= NM_INIT; n_pmode[c] <= PM_A; n_page[c] <= '0; n_byte[c] <= '0; n_aload[c] <= '0;
            end
        end else begin
            case (st)
                // ======================================================================================= idle
                S_IDLE: begin
                    t_h   <= 1'b0;
                    t_res <= '0;
                    if (up_active && up_rd) begin
                        up_busy <= 1'b1;
                        want    <= save_base + {1'b0, up_addr};
                        st      <= S_UP;
                    end else if (!wq_empty) begin
                        t_write <= 1'b1; t_dma <= 1'b0;
                        t_a     <= wq_a[wq_rp[1:0]];
                        t_d     <= wq_d[wq_rp[1:0]];
                        t_m     <= wq_m[wq_rp[1:0]];
                        wq_rp   <= wq_rp + 1'd1;
                        st      <= (board_memn && wq_a[wq_rp[1:0]][23:20] == 4'h5) ? S_SRAM : S_WHALF;
                    end else if (rd_pend) begin
                        t_write <= 1'b0; t_dma <= 1'b0;
                        t_a     <= rd_a;
                        t_sz    <= rd_size;
                        st      <= (board_memn && rd_a[23:20] == 4'h5) ? S_SRAM : S_RHALF;
                    end else if (dma_on && !dq_full) begin
                        t_write <= 1'b0; t_dma <= 1'b1;
                        t_a     <= 24'h450000;
                        t_sz    <= 2'b10;          // two data-register reads
                        st      <= S_RHALF;
                    end
                end

                // ======================================================================================= reads
                S_RHALF: begin
                    h_val <= 16'h0000;
                    st    <= S_RNEXT;              // unmapped / not selected: 0
                    if (t_hsel) begin
                        if (!board_memn) begin
                            if (t_ha >= 24'h400000 && t_ha < 24'h600000) st <= S_WIN;
                            else if (t_ha[23:17] == 7'b1011_010) bank_direct <= 1'b1;    // bank_r
                        end else if (t_dma || t_ha == 24'h450000) begin
                            if (!chip_present) h_val <= 16'hFFFF;
                            else begin nb_second <= 1'b0; st <= S_NB; end
                        end else if (t_ha == 24'h470000) h_val <= nand_ctrl;
                        // 0x1F400000 RnB reads 0 (MAME: the ready callback always leaves it 0)
                    end
                end
                S_RNEXT: begin
                    if (t_hsel) begin
                        if (t_h) t_res[31:16] <= h_val; else t_res[15:0] <= h_val;
                    end
                    if (!t_h) begin t_h <= 1'b1; st <= S_RHALF; end
                    else st <= S_RDONE;
                end
                S_RDONE: begin
                    if (t_dma) begin dq_word <= t_res; dq_full <= 1'b1; end
                    else begin rdata <= t_res; rd_pend <= 1'b0; end
                    st <= S_IDLE;
                end

                // ---- MEM(N) data register: two NAND byte reads, high byte first (MAME nand_data_r)
                S_NB: begin
                    case (cur_mode)
                        NM_READ:
                            if (!cur_inpage) begin
                                nb_word <= {nb_word[7:0], 8'hFF};
                                n_byte[nand_idx] <= next_byte;
                                n_page[nand_idx] <= next_page;
                                st <= S_NBDONE;
                            end else if (tag_valid && tag_base == cur_pagebase) begin
                                fsm_rb <= cur_byte;
                                st     <= S_NBQ;
                            end else begin
                                tag_base <= cur_pagebase;
                                start_job(J_FETCH, cur_pagebase, 14'd66, S_NB);
                            end
                        NM_STATUS: begin nb_word <= {nb_word[7:0], 8'hC0}; st <= S_NBDONE; end
                        NM_ID: begin
                            nb_word <= {nb_word[7:0], (cur_byte == 10'd0) ? 8'hEC :
                                                      (cur_byte == 10'd1) ? (nand_big ? 8'h75 : 8'h73) : 8'h00};
                            n_byte[nand_idx] <= cur_byte + 1'd1;
                            st <= S_NBDONE;
                        end
                        default: begin nb_word <= {nb_word[7:0], 8'h00}; st <= S_NBDONE; end
                    endcase
                end
                S_NBQ: begin                                   // PAGE byte available
                    nb_word <= {nb_word[7:0], fsm_byte};
                    n_byte[nand_idx] <= next_byte;
                    n_page[nand_idx] <= next_page;
                    st <= S_NBDONE;
                end
                S_NBDONE: begin
                    if (!nb_second) begin nb_second <= 1'b1; st <= S_NB; end
                    else if (cr_active) begin
                        cr_cipher <= nb_word;
                        cr_step   <= 1'b1;
                        st        <= S_DEC1;
                    end else begin
                        // blocks 0-1 of NAND 0 are stored in the clear (bad-block table, settings)
                        if (nand_idx == 4'd0 && nand_address[23:14] == 10'd0)     // page index < 64 (MAME: block < 2)
                            h_val <= nb_word;
                        else h_val <= unscramble(nb_word ^ data_xor, perm);
                        st <= S_RNEXT;
                    end
                end
                S_DEC1: st <= S_DEC2;                          // decrypter stepped with cr_cipher; plain captured
                S_DEC2: begin h_val <= cr_plain_q; st <= S_RNEXT; end

                // ---- MEM(M) window (MAME range_r)
                S_WIN: begin
                    if (!bank_direct) begin
                        // direct flash access through the Intel state machine (raw words)
                        win_unscr <= 1'b0;
                        case (fmode)
                            FM_STATUS, FM_WBUF2: begin h_val <= {8'h00, fstatus}; st <= S_RNEXT; end
                            FM_WBUF1:            begin h_val <= 16'h0080;          st <= S_RNEXT; end
                            FM_ID: begin
                                case (win_word[7:0])
                                    8'd0:    h_val <= 16'h0089;
                                    8'd1:    h_val <= 16'h0015;
                                    8'd3:    h_val <= {15'd0, fmaster};
                                    default: h_val <= 16'h0000;
                                endcase
                                st <= S_RNEXT;
                            end
                            default: begin want <= {2'b00, win_word, 1'b0}; st <= S_WW0; end
                        endcase
                    end else begin
                        win_unscr <= 1'b1;
                        want      <= win_img;
                        st        <= S_WW0;
                    end
                end
                S_WW0: begin                                   // line in the buffer?
                    if (tag_valid && tag_base == {want[27:6], 6'd0}) begin
                        fsm_rb <= {4'd0, want[5:0]};
                        st     <= S_WW1;
                    end else begin
                        tag_base <= {want[27:6], 6'd0};
                        start_job(J_FETCH, {want[27:6], 6'd0}, 14'd8, S_WW0);
                    end
                end
                S_WW1: begin w_lo <= fsm_byte; fsm_rb <= fsm_rb + 1'd1; st <= S_WW2; end
                S_WW2: begin
                    if (!win_unscr) begin h_val <= {fsm_byte, w_lo}; st <= S_RNEXT; end
                    else if (cr_active) begin
                        cr_cipher <= {fsm_byte, w_lo};
                        cr_step   <= 1'b1;
                        st        <= S_DEC1;
                    end else begin
                        h_val <= (bank_idx < 5'h10) ? unscramble({fsm_byte, w_lo} ^ 16'hAAAA, perm) : {fsm_byte, w_lo};
                        st    <= S_RNEXT;
                    end
                end

                // ---- MEM(N) SRAM, whole word (SDRAM channel 3)
                S_SRAM: begin
                    sram_req   <= 1'b1;
                    sram_addr  <= {t_a[19:2], 2'b00};
                    sram_rnw   <= !t_write;
                    sram_be    <= t_write ? t_m : 4'b1111;
                    sram_wdata <= t_d;
                    st         <= S_SRAMW;
                end
                S_SRAMW: begin
                    if (sram_ready) begin
                        sram_req <= 1'b0;
                        if (!t_write) begin rdata <= sram_rdata; rd_pend <= 1'b0; end
                        st <= S_IDLE;
                    end
                end

                // ======================================================================================= DDR3 jobs
                S_JOBW: begin
                    if (job_req && job_done) begin
                        job_req <= 1'b0;
                        if (job_type == J_FETCH) tag_valid <= 1'b1;
                        st <= st_ret;
                    end
                end
                S_PGMWB: begin                                 // program: the page is fetched; write it back
                    tag_valid <= 1'b0;
                    start_job(J_WBACK, tag_base, 14'd66, S_WNEXT);
                end

                // ======================================================================================= writes
                S_WHALF: begin
                    st <= S_WNEXT;
                    if (t_hsel) begin
                        if (t_ha == 24'h300000 || (board_memn && t_ha == 24'h380000)) begin
                            // crypto switch: bit 15 = activate with IV = bits 3-0
                            if (t_d16[15]) begin cr_act_p <= 1'b1; cr_iv <= t_d16[3:0]; end
                            else cr_deact_p <= 1'b1;
                        end else if (!board_memn) begin
                            if (t_ha[23:17] == 7'b1011_010) begin                       // bank_w
                                bank_idx    <= t_ha[5:1];
                                bank_direct <= (t_ha[16:1] >= 16'h10);
                            end else if (t_ha >= 24'h400000 && t_ha < 24'h600000 && !bank_direct)
                                st <= S_FLASH;
                        end else begin
                            case (t_ha)
                                24'h410000: if (t_b0 && chip_present) begin      // command (MAME nand_device::command_w)
                                    case (t_d16[7:0])
                                        8'hFF: begin n_mode[nand_idx] <= NM_INIT; n_pmode[nand_idx] <= PM_A; end
                                        8'h00: begin n_mode[nand_idx] <= NM_READ; n_pmode[nand_idx] <= PM_A; n_aload[nand_idx] <= '0; end
                                        8'h01: begin n_mode[nand_idx] <= NM_READ; n_pmode[nand_idx] <= PM_B; n_aload[nand_idx] <= '0; end
                                        8'h50: begin n_mode[nand_idx] <= NM_READ; n_pmode[nand_idx] <= PM_C; n_aload[nand_idx] <= '0; end
                                        8'h80: begin n_mode[nand_idx] <= NM_PROGRAM; n_aload[nand_idx] <= '0; n_pgmcnt <= '0; pm_written <= '0; end
                                        8'h10, 8'h15: begin
                                            n_mode[nand_idx] <= NM_INIT;
                                            if (cur_mode == NM_PROGRAM && {1'b0, cur_page} < nand_pages) begin
                                                mark_dirty();
                                                tag_base <= cur_pagebase;
                                                start_job(J_FETCH, cur_pagebase, 14'd66, S_PGMWB);
                                            end
                                        end
                                        8'h60: begin n_mode[nand_idx] <= NM_ERASE; n_page[nand_idx] <= '0; n_aload[nand_idx] <= '0; end
                                        8'hD0: begin
                                            n_mode[nand_idx] <= NM_INIT;
                                            if (cur_mode == NM_ERASE) begin
                                                if (cur_pmode == PM_B) n_pmode[nand_idx] <= PM_A;
                                                mark_dirty();
                                                start_job(J_FILL, nand_idx * chip_bytes + {cur_page[15:5], 5'd0} * 28'd528, 14'd2112, S_WNEXT);
                                            end
                                        end
                                        8'h70: n_mode[nand_idx] <= NM_STATUS;
                                        8'h90: begin n_mode[nand_idx] <= NM_ID; n_aload[nand_idx] <= '0; end
                                        default: n_mode[nand_idx] <= NM_INIT;
                                    endcase
                                end
                                24'h420000, 24'h430000, 24'h440000: if (t_b0) begin    // address (MAME address_w)
                                    if (t_ha == 24'h420000) nand_address[7:0]   <= t_d16[7:0];
                                    if (t_ha == 24'h430000) nand_address[15:8]  <= t_d16[7:0];
                                    if (t_ha == 24'h440000) nand_address[23:16] <= t_d16[7:0];
                                    if (chip_present) case (cur_mode)
                                        NM_READ, NM_PROGRAM: begin
                                            if (cur_aload == 2'd0) begin
                                                n_page[nand_idx] <= '0;
                                                case (cur_pmode)
                                                    PM_A:    n_byte[nand_idx] <= {2'b00, t_d16[7:0]};
                                                    PM_B:    begin n_byte[nand_idx] <= {2'b01, t_d16[7:0]}; n_pmode[nand_idx] <= PM_A; end
                                                    default: n_byte[nand_idx] <= 10'd512 + t_d16[3:0];
                                                endcase
                                            end else if (cur_aload == 2'd1) n_page[nand_idx][7:0]  <= t_d16[7:0];
                                            else if (cur_aload == 2'd2)     n_page[nand_idx][15:8] <= t_d16[7:0];
                                            if (cur_aload != 2'd3) n_aload[nand_idx] <= cur_aload + 1'd1;
                                        end
                                        NM_ERASE: begin
                                            if (cur_aload == 2'd0) n_page[nand_idx][7:0]  <= t_d16[7:0];
                                            if (cur_aload == 2'd1) n_page[nand_idx][15:8] <= t_d16[7:0];
                                            if (cur_aload != 2'd3) n_aload[nand_idx] <= cur_aload + 1'd1;
                                        end
                                        NM_ID: begin
                                            if (cur_aload == 2'd0) n_byte[nand_idx] <= {2'b00, t_d16[7:0]};
                                            if (cur_aload != 2'd3) n_aload[nand_idx] <= cur_aload + 1'd1;
                                        end
                                        default: ;
                                    endcase
                                end
                                24'h450000: if (chip_present && cur_mode == NM_PROGRAM) begin   // data_w: high byte ...
                                    pm_we <= 1'b1; pm_wa <= cur_byte; pm_wd <= t_d16[15:8];
                                    if (n_pgmcnt < 10'd528) pm_written[cur_byte] <= 1'b1;
                                    n_pgmcnt <= n_pgmcnt + 1'd1;
                                    n_byte[nand_idx] <= pgm_next;
                                    st <= S_NDLO;
                                end
                                24'h460000: if ((nand_ctrl & 16'h0004) == 16'h0000) nand_idx <= t_d16[3:0];
                                24'h470000: nand_ctrl <= t_d16;
                                default: ;
                            endcase
                        end
                    end
                end
                S_NDLO: begin                                  // ... then the low byte
                    pm_we <= 1'b1; pm_wa <= cur_byte; pm_wd <= t_d16[7:0];
                    if (n_pgmcnt < 10'd528) pm_written[cur_byte] <= 1'b1;
                    n_pgmcnt <= n_pgmcnt + 1'd1;
                    n_byte[nand_idx] <= pgm_next;
                    st <= S_WNEXT;
                end
                S_WNEXT: begin
                    if (!t_h) begin t_h <= 1'b1; st <= S_WHALF; end
                    else st <= S_IDLE;
                end

                // ---- MEM(M) flash command interface (MAME intelfsh_device::write_full, 16-bit device)
                S_FLASH: begin
                    st <= S_WNEXT;
                    case (fmode)
                        FM_NORMAL, FM_STATUS, FM_ID:
                            case (t_d16[7:0])
                                8'hF0, 8'hFF: fmode <= FM_NORMAL;
                                8'h90:        fmode <= FM_ID;
                                8'h40, 8'h10: fmode <= FM_WRITE1;
                                8'h50:        begin fstatus <= 8'h80; fmode <= FM_STATUS; end
                                8'h20:        fmode <= FM_CLEAR1;
                                8'h60:        fmode <= FM_SETMASTER;
                                8'h70:        fmode <= FM_STATUS;
                                8'hE8:        fmode <= FM_WBUF1;
                                default: ;
                            endcase
                        FM_WRITE1: begin                       // program one word
                            fstatus <= 8'h80;
                            fmode   <= FM_STATUS;
                            mark_dirty();
                            job_d64 <= {4{t_d16}};
                            job_be  <= 8'h03 << {win_word[1:0], 1'b0};
                            start_job(J_WRITE, {2'b00, win_word[24:2], 3'd0}, 14'd1, S_WNEXT);
                        end
                        FM_CLEAR1:
                            if (t_d16[7:0] == 8'hD0) begin     // erase the 64 KB block (MAME: generic Intel path)
                                fstatus      <= 8'h00;
                                fmode        <= FM_STATUS;
                                ferase_timer <= 26'd33_868_800;
                                mark_dirty();
                                start_job(J_FILL, {2'b00, win_word[24:15], 16'd0}, 14'd8192, S_WNEXT);
                            end
                        FM_SETMASTER: begin
                            if (t_d16[7:0] == 8'hF1) fmaster <= 1'b1;
                            if (t_d16[7:0] == 8'hD0) fmaster <= 1'b0;
                        end
                        FM_WBUF1: begin                        // write-buffer word count
                            wb_n     <= (t_d16 > 16'd15) ? 5'd16 : t_d16[4:0] + 1'd1;
                            wb_count <= '0;
                            fstatus  <= 8'h80;
                            fmode    <= FM_WBUF2;
                        end
                        FM_WBUF2:
                            if (wb_count < wb_n) begin
                                if (wb_count != 0 && win_word[22:0] >= wb_start + wb_n) begin
                                    fstatus <= 8'h30;          // outside the buffer window: error
                                    fmode   <= FM_STATUS;
                                end else begin
                                    if (wb_count == 0) wb_start <= win_word[22:0];
                                    wb_data[wb_count[3:0]] <= t_d16;
                                    wb_count <= wb_count + 1'd1;
                                end
                            end else begin
                                fmode <= FM_STATUS;
                                if (t_d16[7:0] == 8'hD0) begin
                                    fstatus  <= 8'h80;
                                    mark_dirty();
                                    wb_count <= '0;
                                    st       <= S_WBCOMMIT;
                                end else fstatus <= 8'h30;
                            end
                        default: fmode <= FM_NORMAL;
                    endcase
                end
                S_WBCOMMIT: begin                              // write-buffer commit, one word per job
                    if (wb_count == wb_n) st <= S_WNEXT;
                    else begin
                        job_d64  <= {4{wb_data[wb_count[3:0]]}};
                        job_be   <= 8'h03 << {wb_start[1:0] + wb_count[1:0], 1'b0};
                        wb_count <= wb_count + 1'd1;
                        start_job(J_WRITE, {2'b00, 23'(wb_start + wb_count) >> 2, 3'd0}, 14'd1, S_WBCOMMIT);
                    end
                end

                // ======================================================================================= nvram upload
                S_UP: begin
                    if (tag_valid && tag_base == {want[27:6], 6'd0}) begin
                        fsm_rb <= {4'd0, want[5:0]};
                        st     <= S_UPQ0;
                    end else begin
                        tag_base <= {want[27:6], 6'd0};
                        start_job(J_FETCH, {want[27:6], 6'd0}, 14'd8, S_UP);
                    end
                end
                S_UPQ0: begin up_din[7:0] <= fsm_byte; fsm_rb <= fsm_rb + 1'd1; st <= S_UPQ1; end
                S_UPQ1: st <= S_UPQ2;
                S_UPQ2: begin up_din[15:8] <= fsm_byte; up_busy <= 1'b0; st <= S_IDLE; end

                default: st <= S_IDLE;
            endcase
        end
    end

    // the plain word for the cipher word presented with cr_step (state before the step), captured in that cycle
    reg [15:0] cr_plain_q = '0;
    always @(posedge clk) if (cr_step) cr_plain_q <= cr_plain;
endmodule
