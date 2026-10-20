// Namco System 10 ATAPI CD-ROM drive (Taiko no Tatsujin), on the main board's IDE port.
// Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later
//
// [MAME-SOURCE namcos10.cpp (m_ata, cs0 at 0x1FBC0000, pio_dma_read), machine/atahle.cpp,
//  bus/ata/atapihle.cpp, bus/ata/atapicdr.cpp, machine/t10mmc.cpp] Behaviour of MAME's ATAPI CD-ROM for the
// commands the games use (captured from taiko2 with local/mame/atacap.lua):
//   ATA:   E5 CHECK POWER MODE, A1 IDENTIFY PACKET DEVICE, EF SET FEATURES, A0 PACKET, (08 DEVICE RESET)
//   ATAPI: BE READ CD (2048-byte user data), 28 READ(10), A8 READ(12); every other packet (4E STOP PLAY/SCAN,
//          BB SET CD SPEED, 00 TEST UNIT READY, 1B START/STOP ...) completes without data.
// Registers (16 bit, board bus): BC0000 data / BC0002 error-feature / BC0004 sector count (interrupt reason) /
// BC0006 sector number / BC0008 byte count low / BC000A byte count high / BC000C device / BC000E status-command.
// Data phase: PIO through the data register or, with feature bit 0 set (the games program multiword DMA with
// SET FEATURES 03h/22h and leave feature = 03h), PSX DMA channel 5, which MAME hands to the drive while its
// DMARQ is pending (32-bit DMA word = two 16-bit data words, low first).
//
// [IMPLEMENTATION] The disc is an image mounted from the OSD on hps_io slot 0 (1 KB blocks, 16-bit data): a .bin
// with 2352-byte raw sectors (recognised by the sync pattern of sector 0) or with 2048-byte sectors (.iso,
// MODE1/2048 .bin), as chdman extractcd writes them. Sectors are delivered one at a time (2048 bytes = one DRQ
// block) from two buffers; while one is delivered, the next sector is read ahead into the other, so the games'
// sequential streaming normally finds its sector loaded. While a sector is not loaded the drive shows BSY; a DMA
// started in the meantime waits (rdma_valid low).
module s10_atapi #(
    parameter int CLK_HZ = 33_868_800
) (
    input  wire        clk,
    input  wire        reset,
    input  wire        enable,            // board record: CD-ROM drive fitted

    // board bus (CPU address bits 23..0)
    input  wire [23:0] addr,
    input  wire [31:0] wdata,
    input  wire  [3:0] wmask,
    input  wire  [1:0] size,
    input  wire        rd,
    input  wire        wr,
    output reg  [31:0] rdata = 0,         // zero unless selected (OR-ed board bus)

    output wire        intrq,             // INTRQ (level)

    // PSX DMA channel 5 while a DMA-mode read is outstanding
    output wire        dma_pending,       // a channel-5 transfer started now belongs to the drive
    output reg         rdma_valid = 1'b0,
    input  wire        rdma_pop,
    output wire [31:0] rdma_data,

    // hps_io slot 0 (1 KB blocks, 16-bit data)
    output reg  [31:0] sd_lba = 0,
    output reg         sd_rd = 1'b0,
    input  wire        sd_ack,
    input  wire  [8:0] sd_buff_addr,
    input  wire [15:0] sd_buff_dout,
    input  wire        sd_buff_wr,
    input  wire        img_mounted,
    input  wire [63:0] img_size
);
    // ================================================================== sector buffers: 2 x 2048 bytes
    // entry {b, e} holds 16-bit words 2e (bits 15:0) and 2e+1 (bits 31:16) of buffer b
    reg [31:0] bram [0:1023];
    reg [31:0] bq = 0;
    reg  [9:0] bra = 0;
    reg        bw_en = 1'b0, bw_hi = 1'b0;
    reg  [9:0] bw_a = 0;
    reg [15:0] bw_d = 0;
    always @(posedge clk) begin
        if (bw_en) begin
            if (bw_hi) bram[bw_a][31:16] <= bw_d;
            else       bram[bw_a][15:0]  <= bw_d;
        end
        bq <= bram[bra];
    end
    assign rdma_data = bq;

    reg  [1:0] bvalid = 0;
    reg [31:0] btag0 = 0, btag1 = 0;

    // ================================================================== SD fetch engine
    reg        disc = 1'b0;               // image mounted
    reg        raw  = 1'b0;               // 2352-byte sectors
    reg        detect = 1'b0;             // sync check of block 0 pending

    localparam [1:0] F_IDLE = 2'd0, F_REQ = 2'd1, F_XFER = 2'd2;
    reg  [1:0] fst = F_IDLE;
    reg        f_det = 1'b0, f_buf = 1'b0;
    reg [31:0] f_lba = 0;
    reg [42:0] f_start = 0;               // image byte offset of the sector's 2048 data bytes
    reg [32:0] f_blk = 0;                 // current 1 KB block
    reg  [1:0] f_left = 0;                // blocks left including the current one
    reg  [2:0] f_sync = 0;

    // request from the command FSM (level, taken when the engine is idle)
    reg        f_req = 1'b0, f_rbuf = 1'b0;
    reg [31:0] f_rlba = 0;

    wire [42:0] raw_off = {f_rlba, 11'd0} + {f_rlba, 8'd0} + {f_rlba, 5'd0} + {f_rlba, 4'd0} + 43'd16;  // x2352 + 16
    wire [42:0] iso_off = {f_rlba, 11'd0};
    wire [42:0] s_off   = raw ? raw_off : iso_off;
    wire [42:0] rel     = {f_blk, 10'd0} + {33'd0, sd_buff_addr, 1'b0} - f_start;

    always @(posedge clk) begin
        bw_en <= 1'b0;
        // a mount can arrive at any time, also while the core is held in reset (Main_MiSTer re-mounts the
        // remembered image while the MRA loads); the disc stays known across resets
        if (img_mounted) begin
            disc   <= (img_size != 0);
            detect <= (img_size != 0);
        end
        if (reset) begin
            fst <= F_IDLE; sd_rd <= 1'b0; bvalid <= 0;
        end else begin
            if (img_mounted) bvalid <= 0;
            case (fst)
                F_IDLE:
                    if (detect) begin
                        f_det <= 1'b1; f_sync <= 0;
                        f_blk <= 0; f_left <= 2'd1;
                        sd_lba <= 0; sd_rd <= 1'b1; fst <= F_REQ;
                    end else if (f_req) begin
                        f_det   <= 1'b0;
                        f_buf   <= f_rbuf;
                        f_lba   <= f_rlba;
                        bvalid[f_rbuf] <= 1'b0;
                        f_start <= s_off;
                        f_blk   <= s_off[42:10];
                        f_left  <= (s_off[9:0] == 10'd0) ? 2'd2 : 2'd3;
                        sd_lba  <= s_off[41:10];
                        sd_rd   <= 1'b1; fst <= F_REQ;
                    end
                F_REQ: if (sd_ack) begin sd_rd <= 1'b0; fst <= F_XFER; end
                F_XFER: begin
                    if (sd_buff_wr) begin
                        if (f_det) begin       // 00 FF FF FF FF FF FF FF FF FF FF 00
                            if (sd_buff_addr == 9'd0) f_sync[0] <= (sd_buff_dout == 16'hFF00);
                            if (sd_buff_addr == 9'd1) f_sync[1] <= (sd_buff_dout == 16'hFFFF);
                            if (sd_buff_addr == 9'd5) f_sync[2] <= (sd_buff_dout == 16'h00FF);
                        end else if (rel < 43'd2048) begin
                            bw_en <= 1'b1;
                            bw_a  <= {f_buf, rel[10:2]};
                            bw_hi <= rel[1];
                            bw_d  <= sd_buff_dout;
                        end
                    end
                    if (!sd_ack) begin
                        if (f_left == 2'd1) begin
                            fst <= F_IDLE;
                            if (f_det) begin detect <= 1'b0; raw <= &f_sync; end
                            else begin
                                bvalid[f_buf] <= 1'b1;
                                if (f_buf) btag1 <= f_lba; else btag0 <= f_lba;
                            end
                        end else begin
                            f_left <= f_left - 1'd1;
                            f_blk  <= f_blk + 1'd1;
                            sd_lba <= sd_lba + 1'd1;
                            sd_rd  <= 1'b1; fst <= F_REQ;
                        end
                    end
                end
                default: fst <= F_IDLE;
            endcase
        end
    end
    wire f_idle = (fst == F_IDLE) && !detect;

    // ================================================================== IDENTIFY PACKET DEVICE (MAME matsushita_cr589_device,
    // as read by taiko2): firmware "1.0", model "MATSHITA CR-589", word 49 = 0x0400
    function automatic [15:0] ident(input [7:0] w);
        case (w)
            8'd0:  ident = 16'h8500;
            8'd23: ident = 16'h312E;   // "1."
            8'd24: ident = 16'h3020;   // "0 "
            8'd27: ident = 16'h4D41;   // "MA"
            8'd28: ident = 16'h5453;   // "TS"
            8'd29: ident = 16'h4849;   // "HI"
            8'd30: ident = 16'h5441;   // "TA"
            8'd31: ident = 16'h2043;   // " C"
            8'd32: ident = 16'h522D;   // "R-"
            8'd33: ident = 16'h3538;   // "58"
            8'd34: ident = 16'h3920;   // "9 "
            8'd49: ident = 16'h0400;
            default: ident = (w >= 8'd25 && w <= 8'd46) ? 16'h2020 : 16'h0000;
        endcase
    endfunction

    // ================================================================== ATA registers and command FSM
    reg        bsy = 1'b0, drdy = 1'b0, drq = 1'b0, err = 1'b0;
    reg  [7:0] error = 8'h01, feature = 0, count = 8'h01, sector = 8'h01, cyl_lo = 8'h14, cyl_hi = 8'hEB;
    reg  [7:0] devhead = 0;
    reg        irq = 1'b0;
    wire [7:0] status = {bsy, drdy, 2'b00, drq, 2'b00, err};
    wire       sel = !devhead[4];
    assign     intrq = enable && irq && sel;

    localparam [2:0] P_IDLE = 3'd0, P_PKT = 3'd1, P_WAIT = 3'd2, P_DATA = 3'd3, P_IDENT = 3'd4, P_TIMER = 3'd5;
    reg  [2:0] phase = P_IDLE;
    reg  [2:0] pkt_n = 0;                 // packet words received
    reg  [7:0] pkt [0:11];
    reg        pkt_go = 1'b0;
    reg [31:0] r_lba = 0;                 // next sector to deliver
    reg [23:0] r_left = 0;                // sectors still to deliver
    reg        r_dma = 1'b0;
    reg        cur = 1'b0;                // buffer being delivered
    reg  [9:0] ptr = 0;                   // 16-bit word index in the data block
    reg [15:0] tmr = 0;
    reg        tmr_rst = 1'b0;            // timer end = soft reset (signature)

    assign dma_pending = enable && r_dma && (phase == P_WAIT || phase == P_DATA);

    // buffer read address follows the data pointer; bq is valid two clocks after ptr/cur change
    always @(posedge clk) bra <= {cur, ptr[9:1]};
    reg  [9:0] bra_q = 0;
    always @(posedge clk) bra_q <= bra;
    wire       bq_ok = (bra == {cur, ptr[9:1]}) && (bra_q == bra);

    wire [15:0] data_word = (phase == P_IDENT) ? ident(ptr[7:0]) : (ptr[0] ? bq[31:16] : bq[15:0]);

    function automatic [15:0] reg_r(input [2:0] o);
        if (bsy && o != 3'd0) reg_r = {8'h00, sel ? status : 8'h00};
        else case (o)
            3'd0: reg_r = (drq && sel && !bsy) ? data_word : 16'hFFFF;
            3'd1: reg_r = {8'h00, error};
            3'd2: reg_r = {8'h00, count};
            3'd3: reg_r = {8'h00, sector};
            3'd4: reg_r = {8'h00, cyl_lo};
            3'd5: reg_r = {8'h00, cyl_hi};
            3'd6: reg_r = {8'h00, devhead};
            default: reg_r = {8'h00, sel ? status : 8'h00};
        endcase
    endfunction

    wire        hit   = enable && (addr[23:4] == 20'hBC000);
    wire  [2:0] o_lo  = {addr[3:2], 1'b0};
    wire  [2:0] o_hi  = {addr[3:2], 1'b1};
    wire        rd_lo = (size == 2'b10) || !addr[1];
    wire        rd_hi = (size == 2'b10) ||  addr[1];
    wire        wr_lo = (wmask[1:0] != 2'b00);
    wire        wr_hi = (wmask[3:2] != 2'b00);

    // packet decode
    wire  [7:0] op     = pkt[0];
    wire [31:0] p_lba  = {pkt[2], pkt[3], pkt[4], pkt[5]};
    wire [23:0] p_len  = (op == 8'hBE) ? {pkt[6], pkt[7], pkt[8]} :
                         (op == 8'h28) ? {8'h00, pkt[7], pkt[8]} :
                         (op == 8'hA8) ? {pkt[7], pkt[8], pkt[9]} : 24'd0;
    wire        p_read = (op == 8'hBE) || (op == 8'h28) || (op == 8'hA8);

    wire        in0 = bvalid[0] && btag0 == r_lba;
    wire        in1 = bvalid[1] && btag1 == r_lba;
    wire [31:0] tag_other = cur ? btag0 : btag1;

    task automatic complete(input logic e, input [7:0] er);
        phase  <= P_IDLE;
        bsy    <= 1'b0;
        drq    <= 1'b0;
        cyl_lo <= 8'h00; cyl_hi <= 8'h00;
        count  <= 8'h03;                  // IO | CoD: command complete
        err    <= e;
        error  <= er;
        irq    <= 1'b1;
    endtask

    // one 16-bit register write (MAME command_w); 'busy' is the state before this access
    task automatic reg_w(input [2:0] o, input [15:0] d);
        if (drq && o != 3'd0 && !(o == 3'd6 && d[7:0] == devhead)) begin
            drq <= 1'b0; bsy <= 1'b0; err <= 1'b1; error <= 8'h04; phase <= P_IDLE; r_dma <= 1'b0;
        end else if (!bsy) begin
            case (o)
                3'd0: if (drq && sel && phase == P_PKT) begin
                    pkt[{pkt_n, 1'b0}]        <= d[7:0];
                    pkt[{pkt_n, 1'b0} + 4'd1] <= d[15:8];
                    pkt_n <= pkt_n + 1'd1;
                    if (pkt_n == 3'd5) begin drq <= 1'b0; pkt_go <= 1'b1; end
                end
                3'd1: feature <= d[7:0];
                3'd2: count   <= d[7:0];
                3'd3: sector  <= d[7:0];
                3'd4: cyl_lo  <= d[7:0];
                3'd5: cyl_hi  <= d[7:0];
                3'd6: devhead <= d[7:0];
                3'd7: if (sel) begin
                    err <= 1'b0; error <= 8'h00; irq <= 1'b0;
                    case (d[7:0])
                        8'hA0: begin phase <= P_PKT; pkt_n <= 0; drq <= 1'b1; count <= 8'h01; end
                        8'hA1: begin phase <= P_IDENT; ptr <= 0; drq <= 1'b1; count <= 8'h02;
                                     cyl_lo <= 8'h00; cyl_hi <= 8'h02; irq <= 1'b1; end
                        8'hE5: begin drdy <= 1'b1; drq <= 1'b0; count <= 8'hFF; irq <= 1'b1; end
                        8'hEF: begin bsy <= 1'b1; phase <= P_TIMER; tmr_rst <= 1'b0; tmr <= 16'(CLK_HZ / 100000); end
                        8'h08: begin bsy <= 1'b1; drdy <= 1'b0; phase <= P_TIMER; tmr_rst <= 1'b1; tmr <= 16'(CLK_HZ / 500); end
                        8'hEC: begin count <= 8'h01; sector <= 8'h01; cyl_lo <= 8'h14; cyl_hi <= 8'hEB;
                                     err <= 1'b1; error <= 8'h04; irq <= 1'b1; end
                        default: begin err <= 1'b1; error <= 8'h04; irq <= 1'b1; end
                    endcase
                end
                default: ;
            endcase
        end
    endtask

    always @(posedge clk) begin
        rdata  <= 0;
        pkt_go <= 1'b0;
        if (fst != F_IDLE) f_req <= 1'b0;   // request taken

        if (reset || !enable) begin
            bsy <= 1'b0; drdy <= 1'b0; drq <= 1'b0; err <= 1'b0; irq <= 1'b0;
            error <= 8'h01; feature <= 0; count <= 8'h01; sector <= 8'h01; cyl_lo <= 8'h14; cyl_hi <= 8'hEB;
            devhead <= 0; phase <= P_IDLE; rdma_valid <= 1'b0; r_dma <= 1'b0; f_req <= 1'b0;
        end else begin
            // ---- bus reads (MAME 16-bit handlers: low half, then high half)
            if (rd && hit) begin
                rdata <= {rd_hi ? reg_r(o_hi) : 16'h0000, rd_lo ? reg_r(o_lo) : 16'h0000};
                if (rd_lo && o_lo == 3'd0 && drq && sel && !bsy) begin                 // data register pop
                    ptr <= ptr + 1'd1;
                    if (phase == P_IDENT && ptr == 10'd255) complete(1'b0, 8'h00);
                    if (phase == P_DATA && ptr == 10'd1023) begin
                        drq <= 1'b0; r_left <= r_left - 1'd1; r_lba <= r_lba + 1'd1; phase <= P_WAIT;
                    end
                end
                if (rd_hi && o_hi == 3'd7 && sel && !bsy) irq <= 1'b0;                 // status read clears INTRQ
            end

            // ---- DMA (32-bit words = two data words)
            if (rdma_valid && rdma_pop) begin
                rdma_valid <= 1'b0;
                ptr <= ptr + 2'd2;
                if (ptr == 10'd1022) begin
                    drq <= 1'b0; r_left <= r_left - 1'd1; r_lba <= r_lba + 1'd1; phase <= P_WAIT;
                end
            end else if (phase == P_DATA && r_dma && drq && !rdma_valid && bq_ok)
                rdma_valid <= 1'b1;

            // ---- bus writes (low half, then high half)
            if (wr && hit) begin
                if (wr_lo) reg_w(o_lo, wdata[15:0]);
                if (wr_hi) reg_w(o_hi, wdata[31:16]);
            end

            // ---- execute a received packet
            if (pkt_go) begin
                if (p_read && !disc)       complete(1'b1, 8'h24);                       // NOT READY, ABRT
                else if (!p_read || p_len == 0) complete(1'b0, 8'h00);
                else begin
                    r_lba <= p_lba; r_left <= p_len; r_dma <= feature[0];
                    phase <= P_WAIT; bsy <= 1'b1;
                end
            end

            // ---- wait for the next sector: DRQ (+ DMARQ, or INTRQ for PIO), or command complete
            if (phase == P_WAIT && !pkt_go) begin
                if (r_left == 0) begin
                    complete(1'b0, 8'h00);
                    r_dma <= 1'b0;
                end else if (in0 || in1) begin
                    bsy <= 1'b0; drq <= 1'b1; phase <= P_DATA;
                    cur <= in1; ptr <= 0;
                    cyl_lo <= 8'h00; cyl_hi <= 8'h08;   // 0x800 bytes
                    count  <= 8'h02;                    // IO
                    if (!r_dma) irq <= 1'b1;
                end else begin
                    bsy <= 1'b1;
                    if (f_idle && !f_req) begin f_req <= 1'b1; f_rbuf <= !cur; f_rlba <= r_lba; end
                end
            end
            // read ahead the following sector into the other buffer
            if (phase == P_DATA && f_idle && !f_req && !(bvalid[!cur] && tag_other == r_lba + 1'd1)) begin
                f_req <= 1'b1; f_rbuf <= !cur; f_rlba <= r_lba + 1'd1;
            end

            // ---- SET FEATURES / DEVICE RESET busy time
            if (phase == P_TIMER) begin
                if (tmr != 0) tmr <= tmr - 1'd1;
                else begin
                    bsy <= 1'b0; phase <= P_IDLE;
                    if (tmr_rst) begin
                        count <= 8'h01; sector <= 8'h01; cyl_lo <= 8'h14; cyl_hi <= 8'hEB;
                        devhead <= devhead & 8'h10; error <= 8'h01;
                    end else begin
                        // SET FEATURES (MAME set_features with IDENTIFY words 62-64/88 = 0): transfer mode
                        // PIO default 0/1 or PIO flow control 0-2 succeed, DMA modes fail (the games still
                        // use DMA afterwards: feature bit 0 stays set); 01/66/81/CC succeed; else ABRT
                        if (!(feature == 8'h03 ? ((count[7:3] == 5'd0 && count[2:1] == 2'd0) || (count[7:3] == 5'd1 && count[2:0] <= 3'd2))
                                               : (feature == 8'h01 || feature == 8'h66 || feature == 8'h81 || feature == 8'hCC))) begin
                            err <= 1'b1; error <= 8'h04;
                        end
                        irq <= 1'b1;
                    end
                end
            end
        end
    end
endmodule
