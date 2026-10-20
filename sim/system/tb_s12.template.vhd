-- ============================================================================
-- tb_s12 -- full-system NVC testbench for the Tenkomori (Namco System 12) core
-- (generated from tb_s12.template.vhd by gen_tb.py - edit the template)
-- ----------------------------------------------------------------------------
-- psx_mister (MIPS/GPU/DMA/... + System 12 memory map) + s12_sub (H8/3002, C352,
-- shared RAM) + s12_ch3 (SDRAM channel 3) on one SDRAM model preloaded with the
-- image the MiSTer loader writes (scripts/romtool.py sdram). VRAM in ddrram_model.
-- Outputs in the run directory:
--   gra_fb_out_vga.gra  video capture (tools: sim/system/gra2png.py)
--   mips_pc.log         MIPS PC sampled every 100 us
--   s12_events.log      ROM-DMA starts, bank writes, shared-RAM traffic summary, H8 PC
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

library psx;
library tb;

entity tb_s12 is
   generic (
      TURBO     : std_logic := '0';
      TCACHE    : std_logic := '0';
      TC50      : std_logic := '0';
      HACK480   : std_logic := '0';
      SDRAM_IMG : string := "sdram.bin";
      SLOWVRAM  : integer := 0;
      TRACE_FROM_US : integer := 0;
      TRACE_TO_US   : integer := 0;
      FULLRESET     : std_logic := '0';  -- '1': hardware savestate reset sequence (slower)
      FB_EVERY      : integer := 1;
      WATCHIDX      : integer := -1;
      H8HOLD        : std_logic := '0';
      MIPS_HOLD_US  : integer := 0;      -- keep the MIPS in reset this long (H8 state transplant restores first)  -- '1': keep the H8 sub CPU in reset (state transplants)
      VTRACE_FROM   : integer := 0;      -- ms: dump raw PSX video (per clkvid) to video_trace.txt
      VTRACE_TO     : integer := 0;      -- framebuffer dump: every Nth frame
      LOGVRAM       : std_logic := '1'   -- '0': skip the VRAM write log
   );
end entity;

architecture sim of tb_s12 is

   signal clk1x  : std_logic := '1';
   signal clk2x  : std_logic := '1';
   signal clk3x  : std_logic := '1';
   signal clkvid : std_logic := '1';
   signal reset  : std_logic := '1';
   signal psx_reset : std_logic;
   signal sig_req   : std_logic := '1';
   signal sig_done  : std_logic;

   signal ram_refresh        : std_logic;
   signal ram_dataWrite      : std_logic_vector(31 downto 0);
   signal ram_dataRead32     : std_logic_vector(31 downto 0);
   signal ram_Adr            : std_logic_vector(26 downto 0);
   signal ram_cntDMA         : std_logic_vector(1 downto 0);
   signal ram_be             : std_logic_vector(3 downto 0);
   signal ram_rnw            : std_logic;
   signal ram_ena            : std_logic;
   signal ram_dma            : std_logic;
   signal ram_iscache        : std_logic;
   signal ram_done           : std_logic;
   signal ram_dmafifo_adr    : std_logic_vector(22 downto 0);
   signal ram_dmafifo_data   : std_logic_vector(31 downto 0);
   signal ram_dmafifo_empty  : std_logic;
   signal ram_dmafifo_read   : std_logic;
   signal cache_wr           : std_logic_vector(3 downto 0);
   signal cache_data         : std_logic_vector(31 downto 0);
   signal cache_addr         : std_logic_vector(7 downto 0);
   signal dma_wr             : std_logic;
   signal dma_reqprocessed   : std_logic;
   signal dma_data           : std_logic_vector(31 downto 0);

   signal DDRAM_BUSY         : std_logic;
   signal DDRAM_BURSTCNT     : std_logic_vector(7 downto 0);
   signal DDRAM_ADDR         : std_logic_vector(28 downto 0);
   signal DDRAM_DOUT         : std_logic_vector(63 downto 0);
   signal DDRAM_DOUT_READY   : std_logic;
   signal DDRAM_RD           : std_logic;
   signal DDRAM_DIN          : std_logic_vector(63 downto 0);
   signal DDRAM_BE           : std_logic_vector(7 downto 0);
   signal DDRAM_WE           : std_logic;

   signal hsync, vsync, hblank, vblank, video_ce, video_interlace : std_logic;
   signal video_r, video_g, video_b : std_logic_vector(7 downto 0);

   signal sh_addr   : std_logic_vector(11 downto 0);
   signal sh_wdata  : std_logic_vector(31 downto 0);
   signal sh_be     : std_logic_vector(3 downto 0);
   signal sh_we     : std_logic;
   signal sh_rdata  : std_logic_vector(31 downto 0);
   signal rdma_start, rdma_valid, rdma_pop : std_logic;
   signal rdma_src  : std_logic_vector(26 downto 0);
   signal rdma_data : std_logic_vector(31 downto 0);

   signal ch3_addr  : std_logic_vector(26 downto 0);
   signal ch3_din, ch3_dout : std_logic_vector(31 downto 0);
   signal ch3_req, ch3_rnw, ch3_ready : std_logic;
   signal ch3_be    : std_logic_vector(3 downto 0);

   signal h8_prog_addr  : std_logic_vector(18 downto 0);
   signal h8_prog_rd, h8_prog_ready : std_logic;
   signal h8_prog_data  : std_logic_vector(31 downto 0);
   signal wave_addr     : std_logic_vector(23 downto 0);
   signal wave_rd, wave_ready : std_logic;
   signal wave_data     : std_logic_vector(31 downto 0);
   signal sample_ce     : std_logic := '0';
   signal audio_l, audio_r : std_logic_vector(15 downto 0);
   signal h8_pc         : std_logic_vector(23 downto 0);
   signal h8_ill        : std_logic;

   signal exe_dummy : unsigned(31 downto 0);
   signal psx_reset_m : std_logic := '1';
   signal tb_in_p1, tb_in_sys : std_logic_vector(7 downto 0) := x"FF";
   signal tb_ee_wr   : std_logic := '0';
   signal tb_ee_addr : std_logic_vector(9 downto 0) := (others => '0');
   signal tb_ee_data : std_logic_vector(31 downto 0) := (others => '0');
   signal ddr_wr_cnt, ddr_rd_cnt, poly_cnt, pix_cnt : integer := 0;
   signal vbl_cnt, exc_cnt : integer := 0;

begin

   -- exact 1:2:3 ratios (one PLL on hardware); the SDRAM model's ready handshake relies on it
   clk1x  <= not clk1x  after 14763 ps;   -- 33.8688 MHz
   clk2x  <= not clk2x  after  7381.5 ps;
   clk3x  <= not clk3x  after  4921 ps;   -- 101.6 MHz
   clkvid <= not clkvid after  9311 ps;   -- 53.7 MHz

   reset <= '1', '0' after 400 ns;

   -- coh700b boot signature copy (s12_ch3) holds the MIPS in reset like the top level does
   process (clk1x)
   begin
      if rising_edge(clk1x) then
         if reset = '1' then
            sig_req <= '1';
         elsif sig_done = '1' then
            sig_req <= '0';
         end if;
      end if;
   end process;
   psx_reset <= reset or sig_req;
   process
   begin
      psx_reset_m <= '1';
      wait until psx_reset = '0';
      if now < MIPS_HOLD_US * 1 us then wait for MIPS_HOLD_US * 1 us - now; end if;
      loop
         psx_reset_m <= psx_reset;
         wait on psx_reset;
      end loop;
   end process;

   process (clk1x)
      variable n : integer := 0;
   begin
      if rising_edge(clk1x) then
         sample_ce <= '0';
         n := n + 1;
         if n = 384 then n := 0; sample_ce <= '1'; end if;
      end if;
   end process;

   ipsx : entity psx.psx_mister
      generic map (is_simu => '1', ss_fullreset => FULLRESET)
      port map (
@@PSX_PORTMAP@@
      );

   isub : entity psx.s12_sub
      port map (
         clk        => clk1x,
         reset      => psx_reset or H8HOLD,
         pause      => '0',
         sample_ce  => sample_ce,
         vblank     => vblank,
         in_p2      => x"FF",
         in_p1      => tb_in_p1,
         in_sys     => tb_in_sys,
         in_ext     => x"FF",
         dsw        => x"FF",
         rtc_bcd    => x"26101605" & x"123456",
         prog_addr  => h8_prog_addr,
         prog_rd    => h8_prog_rd,
         prog_data  => h8_prog_data,
         prog_ready => h8_prog_ready,
         wave_addr  => wave_addr,
         wave_rd    => wave_rd,
         wave_data  => wave_data,
         wave_ready => wave_ready,
         sh_addr    => sh_addr,
         sh_wdata   => sh_wdata,
         sh_be      => sh_be,
         sh_we      => sh_we,
         sh_rdata   => sh_rdata,
         audio_l    => audio_l,
         audio_r    => audio_r,
         dbg_pc     => h8_pc,
         dbg_illegal=> h8_ill
      );

   ich3 : entity psx.s12_ch3
      port map (
         clk         => clk1x,
         ch3_addr    => ch3_addr,
         ch3_din     => ch3_din,
         ch3_dout    => ch3_dout,
         ch3_req     => ch3_req,
         ch3_rnw     => ch3_rnw,
         ch3_be      => ch3_be,
         ch3_ready   => ch3_ready,
         sig_req     => sig_req and not reset,
         sig_done    => sig_done,
         prog_sdaddr => std_logic_vector(to_unsigned(16#2400000#, 27) + resize(unsigned(h8_prog_addr), 27)),
         prog_rd     => h8_prog_rd,
         prog_data   => h8_prog_data,
         prog_ready  => h8_prog_ready,
         wave_sdaddr => std_logic_vector(to_unsigned(16#2480000#, 27) + resize(unsigned(wave_addr), 27)),
         wave_rd     => wave_rd,
         wave_data   => wave_data,
         wave_ready  => wave_ready,
         rdma_start  => rdma_start,
         rdma_src    => rdma_src,
         rdma_valid  => rdma_valid,
         rdma_pop    => rdma_pop,
         rdma_data   => rdma_data
      );

   isdram : entity tb.sdram_model_s12
      generic map (DOREFRESH => '1', INITFILE => SDRAM_IMG, FILELOADING => '1')
      port map (
         clk                  => clk1x,
         clk3x                => clk3x,
         refresh              => ram_refresh,
         addr                 => ram_Adr,
         req                  => ram_ena,
         ram_dma              => ram_dma,
         ram_dmacnt           => ram_cntDMA,
         ram_iscache          => ram_iscache,
         rnw                  => ram_rnw,
         be                   => ram_be,
         di                   => ram_dataWrite,
         do                   => open,
         do32                 => ram_dataRead32,
         done                 => ram_done,
         cache_wr             => cache_wr,
         cache_data           => cache_data,
         cache_addr           => cache_addr,
         dma_wr               => dma_wr,
         dma_data             => dma_data,
         reqprocessed         => dma_reqprocessed,
         ram_idle             => open,
         ram_dmafifo_adr      => ram_dmafifo_adr,
         ram_dmafifo_data     => ram_dmafifo_data,
         ram_dmafifo_empty    => ram_dmafifo_empty,
         ram_dmafifo_read     => ram_dmafifo_read,
         fileSize             => open,
         exe_initial_pc       => exe_dummy,
         exe_initial_gp       => open,
         exe_load_address     => open,
         exe_file_size        => open,
         exe_stackpointer     => open,
         ch3_addr             => ch3_addr,
         ch3_din              => ch3_din,
         ch3_dout             => ch3_dout,
         ch3_req              => ch3_req,
         ch3_rnw              => ch3_rnw,
         ch3_be               => ch3_be,
         ch3_ready            => ch3_ready
      );

   iddrram : entity tb.ddrram_model
      generic map (SLOWTIMING => SLOWVRAM, RANDOMTIMING => '0', LOGVRAM => LOGVRAM)
      port map (
         DDRAM_CLK        => clk2x,
         DDRAM_BUSY       => DDRAM_BUSY,
         DDRAM_BURSTCNT   => DDRAM_BURSTCNT,
         DDRAM_ADDR       => DDRAM_ADDR,
         DDRAM_DOUT       => DDRAM_DOUT,
         DDRAM_DOUT_READY => DDRAM_DOUT_READY,
         DDRAM_RD         => DDRAM_RD,
         DDRAM_DIN        => DDRAM_DIN,
         DDRAM_BE         => DDRAM_BE,
         DDRAM_WE         => DDRAM_WE
      );

   ifb : entity tb.framebuffer
      generic map (EVERY => FB_EVERY)
      port map (
         clk             => clkvid,
         hblank          => hblank,
         vblank          => vblank,
         video_ce        => video_ce,
         video_interlace => video_interlace,
         video_r         => video_r,
         video_g         => video_g,
         video_b         => video_b
      );

   process (clk1x)
      variable vd : std_logic := '0';
      variable ed : unsigned(4 downto 0) := (others => '0');
   begin
      if rising_edge(clk1x) then
         if << signal .tb_s12.ipsx.ipsx_top.irq_VBLANK : std_logic >> = '1' and vd = '0' then vbl_cnt <= vbl_cnt + 1; end if;
         vd := << signal .tb_s12.ipsx.ipsx_top.irq_VBLANK : std_logic >>;
         if << signal .tb_s12.ipsx.ipsx_top.icpu.exception : unsigned(4 downto 0) >> /= 0 and ed = 0 then exc_cnt <= exc_cnt + 1; end if;
         ed := << signal .tb_s12.ipsx.ipsx_top.icpu.exception : unsigned(4 downto 0) >>;
      end if;
   end process;

   process (clk2x)
   begin
      if rising_edge(clk2x) then
         if DDRAM_WE = '1' and DDRAM_BUSY = '0' then ddr_wr_cnt <= ddr_wr_cnt + 1; end if;
         if << signal .tb_s12.ipsx.ipsx_top.igpu.poly_pipeline_new : std_logic >> = '1' then poly_cnt <= poly_cnt + 1; end if;
         if << signal .tb_s12.ipsx.ipsx_top.igpu.pixelWrite : std_logic >> = '1' then pix_cnt <= pix_cnt + 1; end if;
         if DDRAM_RD = '1' and DDRAM_BUSY = '0' then ddr_rd_cnt <= ddr_rd_cnt + 1; end if;
      end if;
   end process;

   -- early probe: CE / stall / PC every 2 us for the first 60 us
   process
      file f : text open write_mode is "probe.log";
      variable l : line;
   begin
      wait for 4400 us;
      for i in 1 to 400 loop
         wait for 10 us;
         write(l, now / 1 ns); write(l, string'(" ns ce "));
         write(l, << signal .tb_s12.ipsx.ipsx_top.ce : std_logic >>);
         write(l, string'(" stall "));
         write(l, to_integer(<< signal .tb_s12.ipsx.ipsx_top.icpu.stall : unsigned(4 downto 0) >>));
         write(l, string'(" pc "));
         hwrite(l, std_logic_vector(<< signal .tb_s12.ipsx.ipsx_top.icpu.PC : unsigned(31 downto 0) >>));
         write(l, string'(" dbgpause "));
         hwrite(l, << signal .tb_s12.ipsx.ipsx_top.zn_dbg_pause : std_logic_vector(31 downto 0) >>);
         write(l, string'(" gfifoE "));
         write(l, << signal .tb_s12.ipsx.ipsx_top.igpu.fifoIn_Empty : std_logic >>);
         write(l, string'(" gidle "));
         write(l, << signal .tb_s12.ipsx.ipsx_top.igpu.proc_idle : std_logic >>);
         write(l, string'(" gfifo "));
         hwrite(l, << signal .tb_s12.ipsx.ipsx_top.igpu.fifoIn_Dout : std_logic_vector(31 downto 0) >>);
         write(l, string'(" reqF "));
         write(l, << signal .tb_s12.ipsx.ipsx_top.igpu.proc_requestFifo : std_logic >>);
         write(l, string'(" pbusy "));
         write(l, << signal .tb_s12.ipsx.ipsx_top.igpu.pipeline_busy : std_logic >>);
         write(l, string'(" fval "));
         write(l, << signal .tb_s12.ipsx.ipsx_top.igpu.fifoIn_Valid : std_logic >>);
         write(l, string'(" ddrW ")); write(l, ddr_wr_cnt);
         write(l, string'(" polyN ")); write(l, poly_cnt);
         write(l, string'(" pixW ")); write(l, pix_cnt);
         write(l, string'(" pst "));
         write(l, to_integer(unsigned(<< signal .tb_s12.ipsx.ipsx_top.igpu.poly_dbg_state : std_logic_vector(4 downto 0) >>)));
         write(l, string'(" py "));
         write(l, to_integer(<< signal .tb_s12.ipsx.ipsx_top.igpu.poly_pipeline_y : unsigned(9 downto 0) >>));
         write(l, string'(" ddrR ")); write(l, ddr_rd_cnt);
         write(l, string'(" rst "));
         write(l, << signal .tb_s12.ipsx.ipsx_top.reset_intern : std_logic >>);
         writeline(f, l); flush(f);
      end loop;
      wait;
   end process;

   -- MIPS retired-PC trace in a window (TRACE_FROM_US .. TRACE_TO_US)
   process (clk1x)
      file f : text open write_mode is "mips_trace.log";
      variable l : line;
      variable last : std_logic_vector(31 downto 0) := (others => '1');
      variable pc : std_logic_vector(31 downto 0);
   begin
      if rising_edge(clk1x) then
         if now >= TRACE_FROM_US * 1 us and now <= TRACE_TO_US * 1 us then
            pc := std_logic_vector(<< signal .tb_s12.ipsx.ipsx_top.icpu.PCold1 : unsigned(31 downto 0) >>);
            if pc /= last then
               hwrite(l, pc);
               write(l, string'(" op0 "));
               hwrite(l, std_logic_vector(<< signal .tb_s12.ipsx.ipsx_top.icpu.opcode0 : unsigned(31 downto 0) >>));
               write(l, string'(" op1 "));
               hwrite(l, std_logic_vector(<< signal .tb_s12.ipsx.ipsx_top.icpu.opcode1 : unsigned(31 downto 0) >>));
               write(l, string'(" t "));
               write(l, now / 1 ns);
               writeline(f, l); flush(f);
               last := pc;
            end if;
            if << signal .tb_s12.ipsx.ipsx_top.icpu.regs_wren_a : std_logic >> = '1' then
               write(l, string'("   r"));
               write(l, to_integer(unsigned(<< signal .tb_s12.ipsx.ipsx_top.icpu.regs_address_a : std_logic_vector(4 downto 0) >>)));
               write(l, string'(" <= "));
               hwrite(l, << signal .tb_s12.ipsx.ipsx_top.icpu.regs_data_a : std_logic_vector(31 downto 0) >>);
               writeline(f, l); flush(f);
            end if;
         end if;
      end if;
   end process;

   -- DMA register writes
   process (clk1x)
      file f : text open write_mode is "dma_regs.log";
      variable l : line;
   begin
      if rising_edge(clk1x) then
         if << signal .tb_s12.ipsx.ipsx_top.bus_dma_write : std_logic >> = '1' then
            write(l, now / 1 us); write(l, string'(" us DMA["));
            hwrite(l, "0" & std_logic_vector(<< signal .tb_s12.ipsx.ipsx_top.bus_dma_addr : unsigned(6 downto 0) >>));
            write(l, string'("] <= "));
            hwrite(l, << signal .tb_s12.ipsx.ipsx_top.bus_dma_dataWrite : std_logic_vector(31 downto 0) >>);
            writeline(f, l); flush(f);
         end if;
      end if;
   end process;

   -- scripted inputs: inputs.txt lines "<time_ms> <p1 hex> <sys hex>" (active low, MAME in_r bytes:
   -- p1 = START B3 B2 B1 U D L R, sys = SERVICE TEST COIN1 COIN2 ...). Missing file = idle inputs.
   process
      file f : text;
      variable st : file_open_status;
      variable l : line;
      variable t : integer;
      variable p, y : std_logic_vector(7 downto 0);
   begin
      file_open(st, f, "inputs.txt", read_mode);
      if st = open_ok then
         while not endfile(f) loop
            readline(f, l);
            if l'length > 0 and l(l'low) /= '#' then
               read(l, t); hread(l, p); hread(l, y);
               if now < t * 1 ms then wait for t * 1 ms - now; end if;
               tb_in_p1 <= p; tb_in_sys <= y;
            end if;
         end loop;
         file_close(f);
      end if;
      wait;
   end process;

   -- optional EEPROM image (the MRA nvram, as the HPS would load it): eeprom.hex, 1024 lines of
   -- 32-bit hex words (bytes on lanes 0/2). scripts/romtool.py-independent; see local tooling.
   process
      file f : text;
      variable st : file_open_status;
      variable l : line;
      variable w : std_logic_vector(31 downto 0);
      variable a : integer := 0;
   begin
      file_open(st, f, "eeprom.hex", read_mode);
      if st = open_ok then
         while not endfile(f) and a < 1024 loop
            readline(f, l);
            hread(l, w);
            wait until rising_edge(clk1x);
            tb_ee_wr <= '1'; tb_ee_addr <= std_logic_vector(to_unsigned(a, 10)); tb_ee_data <= w;
            a := a + 1;
         end loop;
         wait until rising_edge(clk1x);
         tb_ee_wr <= '0';
         file_close(f);
      end if;
      wait;
   end process;

   -- C352 output, one line per 88.2 kHz sample (convert with sim/system/audio2wav.py)
   process (clk1x)
      file f : text open write_mode is "audio.txt";
      variable l : line;
      variable sd : std_logic := '0';
   begin
      if rising_edge(clk1x) then
         sd := sample_ce;
         if sample_ce = '1' then
            write(l, to_integer(signed(audio_l))); write(l, string'(" ")); write(l, to_integer(signed(audio_r)));
            writeline(f, l); flush(f);
         end if;
      end if;
   end process;

   -- raw PSX video output per clkvid cycle (hs vs hb vb ce + RGB) for replay through sys/video_mixer
   process (clkvid)
      file f : text open write_mode is "video_trace.txt";
      variable l : line;
      variable w : std_logic_vector(31 downto 0);
   begin
      if rising_edge(clkvid) and VTRACE_TO > 0 and now >= VTRACE_FROM * 1 ms and now < VTRACE_TO * 1 ms then
         w := "000" & hsync & vsync & hblank & vblank & video_ce & video_r & video_g & video_b;
         hwrite(l, w); writeline(f, l); flush(f);
      end if;
   end process;

   -- GP1 and CPU (PIO) GP0 command writes, same filter as local/mame/gp1.lua
   process (clk1x)
      file f : text open write_mode is "gp1.log";
      variable l : line;
      variable d : std_logic_vector(31 downto 0);
   begin
      if rising_edge(clk1x) then
         if << signal .tb_s12.ipsx.ipsx_top.bus_gpu_write : std_logic >> = '1' then
            d := << signal .tb_s12.ipsx.ipsx_top.bus_gpu_dataWrite : std_logic_vector(31 downto 0) >>;
            if << signal .tb_s12.ipsx.ipsx_top.bus_gpu_addr : unsigned(3 downto 0) >> = x"4" then
               write(l, now / 1 us); write(l, string'(" us GP1 ")); hwrite(l, d); writeline(f, l); flush(f);
            elsif << signal .tb_s12.ipsx.ipsx_top.bus_gpu_addr : unsigned(3 downto 0) >> = x"0" and
                  unsigned(d(31 downto 24)) >= 2 and unsigned(d(31 downto 24)) <= 16#7F# and d(31 downto 24) /= x"28" then
               write(l, now / 1 us); write(l, string'(" us GP0 ")); hwrite(l, d); writeline(f, l); flush(f);
            end if;
         end if;
      end if;
   end process;

   -- GPU timeline: gpu_timeline.log (us): DMA-to-GPU word bursts, GPU busy/idle, vblank
   process (clk1x)
      file f : text open write_mode is "gpu_timeline.log";
      variable l : line;
      variable busy, busy_d, vb_d : std_logic := '0';
      variable lastdma : time := 0 ns;
      variable indma : boolean := false;
      variable nw : integer := 0;
      variable idlecnt : integer := 0;
   begin
      if rising_edge(clk1x) then
         if << signal .tb_s12.ipsx.ipsx_top.DMA_GPU_writeEna : std_logic >> = '1' then
            if not indma then
               write(l, now / 1 us); write(l, string'(" DMA-start")); writeline(f, l); flush(f);
               indma := true; nw := 0;
            end if;
            nw := nw + 1; lastdma := now;
         elsif indma and now - lastdma > 20 us then
            write(l, lastdma / 1 us); write(l, string'(" DMA-end words ")); write(l, nw); writeline(f, l); flush(f);
            indma := false;
         end if;
         busy := not (<< signal .tb_s12.ipsx.ipsx_top.igpu.proc_idle : std_logic >> and << signal .tb_s12.ipsx.ipsx_top.igpu.fifoIn_Empty : std_logic >>);
         if busy = '1' then idlecnt := 0; elsif idlecnt < 1000 then idlecnt := idlecnt + 1; end if;
         if busy = '1' and busy_d = '0' then write(l, now / 1 us); write(l, string'(" GPU-busy")); writeline(f, l); flush(f); busy_d := '1'; end if;
         if busy_d = '1' and idlecnt = 300 then write(l, now / 1 us - 9); write(l, string'(" GPU-idle")); writeline(f, l); flush(f); busy_d := '0'; end if;
         if vblank = '1' and vb_d = '0' then write(l, now / 1 us); write(l, string'(" VBLANK")); writeline(f, l); flush(f); end if;
         vb_d := vblank;
      end if;
   end process;

   -- Data-cache coherency checker: cache_check.log
   -- Shadow of main RAM (4 MB) holding the latest value written by anyone (CPU stores as they
   -- enter the cache, DMA writes as they enter the cache); every data-cache read hit is compared.
   process (clk1x)
      type tshadow is array(0 to 1048575) of std_logic_vector(31 downto 0);
      variable sh : tshadow;
      variable inited : boolean := false;
      file fb : text;
      file f : text open write_mode is "cache_check.log";
      variable l : line;
      variable idx : integer;
      variable w, d : std_logic_vector(31 downto 0);
      variable m : std_logic_vector(3 downto 0);
      variable a : unsigned(31 downto 0);
      variable nmis, nhit, nbad : integer := 0;
      type tta is array(0 to 3) of time;
      type tad is array(0 to 3) of std_logic_vector(27 downto 0);
      variable rq_t : tta := (others => 0 ns);
      variable rq_a : tad := (others => (others => '0'));
      variable rq_w : std_logic_vector(0 to 3) := (others => '0');
      variable tnext : time := 10 ms;
      type cfile is file of character;
      file fc : cfile;
      variable st : file_open_status;
      variable ch : character;
      variable b : integer;
   begin
      if rising_edge(clk1x) then
         if not inited then
            inited := true;
            file_open(st, fc, "sdram.bin", read_mode);
            if st = open_ok then
               for i in 0 to 1048575 loop
                  w := (others => '0');
                  for k in 0 to 3 loop
                     read(fc, ch); b := character'pos(ch);
                     w(k*8+7 downto k*8) := std_logic_vector(to_unsigned(b, 8));
                  end loop;
                  sh(i) := w;
               end loop;
               file_close(fc);
            end if;
         end if;
         -- compare first (a hit uses the cache content before this edge's writes)
         if << signal .tb_s12.ipsx.ipsx_top.icpu.dcache_read_enable : std_logic >> = '1' and
            << signal .tb_s12.ipsx.ipsx_top.icpu.dcache_read_hit : std_logic >> = '1' and TCACHE = '1' then
            nhit := nhit + 1;
            idx := to_integer(unsigned(<< signal .tb_s12.ipsx.ipsx_top.icpu.dcache_read_addr : std_logic_vector(19 downto 0) >>));
            d := << signal .tb_s12.ipsx.ipsx_top.icpu.dcache_read_data : std_logic_vector(31 downto 0) >>;
            if d /= sh(idx) then
               nmis := nmis + 1;
               if nmis <= 300 then
                  write(l, now / 1 ns); write(l, string'(" ns MISMATCH addr "));
                  hwrite(l, std_logic_vector(to_unsigned(idx * 4, 24)));
                  write(l, string'(" cache ")); hwrite(l, d); write(l, string'(" ram ")); hwrite(l, sh(idx));
                  write(l, string'(" pc ")); hwrite(l, std_logic_vector(<< signal .tb_s12.ipsx.ipsx_top.icpu.PC : unsigned(31 downto 0) >>));
                  writeline(f, l); flush(f);
               end if;
            end if;
         end if;
         -- bad read fill: the cache is written from a RAM read completion with data /= RAM
         if << signal .tb_s12.ipsx.ipsx_top.icpu.dcache_write_enable : std_logic >> = '1' and
            << signal .tb_s12.ipsx.ipsx_top.dma_cache_write : std_logic >> = '0' and
            not (<< signal .tb_s12.ipsx.ipsx_top.icpu.mem4_request : std_logic >> = '1' and
                 << signal .tb_s12.ipsx.ipsx_top.icpu.mem4_rnw : std_logic >> = '0') then
            idx := to_integer(unsigned(<< signal .tb_s12.ipsx.ipsx_top.icpu.dcache_write_addr : std_logic_vector(19 downto 0) >>));
            d := << signal .tb_s12.ipsx.ipsx_top.icpu.dcache_write_data : std_logic_vector(31 downto 0) >>;
            if d /= sh(idx) and nbad < 300 then
               nbad := nbad + 1;
               write(l, now / 1 ns); write(l, string'(" ns BADFILL addr "));
               hwrite(l, std_logic_vector(to_unsigned(idx * 4, 24)));
               write(l, string'(" fill ")); hwrite(l, d); write(l, string'(" ram ")); hwrite(l, sh(idx));
               write(l, string'(" | last reqs:"));
               for k in 0 to 3 loop
                  write(l, string'(" ")); write(l, rq_t(k) / 1 ns); write(l, string'("ns ")); hwrite(l, rq_a(k));
                  if rq_w(k) = '1' then write(l, string'("R")); else write(l, string'("W")); end if;
               end loop;
               writeline(f, l); flush(f);
            end if;
         end if;
         if << signal .tb_s12.ipsx.ipsx_top.icpu.dcache_write_enable : std_logic >> = '1' and
            to_integer(unsigned(<< signal .tb_s12.ipsx.ipsx_top.icpu.dcache_write_addr : std_logic_vector(19 downto 0) >>)) = WATCHIDX then
            write(l, now / 1 ns); write(l, string'(" ns WATCH write data "));
            hwrite(l, << signal .tb_s12.ipsx.ipsx_top.icpu.dcache_write_data : std_logic_vector(31 downto 0) >>);
            write(l, string'(" clear ")); write(l, << signal .tb_s12.ipsx.ipsx_top.icpu.dcache_write_clear : std_logic >>);
            write(l, string'(" dma ")); write(l, << signal .tb_s12.ipsx.ipsx_top.dma_cache_write : std_logic >>);
            write(l, string'(" st ")); write(l, << signal .tb_s12.ipsx.ipsx_top.icpu.mem4_request : std_logic >>);
            write(l, string'(" rnw ")); write(l, << signal .tb_s12.ipsx.ipsx_top.icpu.mem4_rnw : std_logic >>);
            write(l, string'(" ramdone ")); write(l, << signal .tb_s12.ipsx.ipsx_top.icpu.ram_done : std_logic >>);
            write(l, string'(" pc ")); hwrite(l, std_logic_vector(<< signal .tb_s12.ipsx.ipsx_top.icpu.PC : unsigned(31 downto 0) >>));
            writeline(f, l); flush(f);
         end if;
         if ram_ena = '1' then
            for k in 3 downto 1 loop rq_t(k) := rq_t(k-1); rq_a(k) := rq_a(k-1); rq_w(k) := rq_w(k-1); end loop;
            rq_t(0) := now; rq_a(0) := "0" & ram_Adr; rq_w(0) := ram_rnw;
         end if;
         -- CPU store as it enters the cache
         if << signal .tb_s12.ipsx.ipsx_top.icpu.mem4_request : std_logic >> = '1' and
            << signal .tb_s12.ipsx.ipsx_top.icpu.mem4_rnw : std_logic >> = '0' then
            a := << signal .tb_s12.ipsx.ipsx_top.icpu.executeMemWriteAddr : unsigned(31 downto 0) >>;
            if a(28 downto 0) < 16#800000# then
               idx := to_integer(a(21 downto 2));
               w := << signal .tb_s12.ipsx.ipsx_top.icpu.mem4_dataWrite : std_logic_vector(31 downto 0) >>;
               m := << signal .tb_s12.ipsx.ipsx_top.icpu.executeMemWriteMask : std_logic_vector(3 downto 0) >>;
               for k in 0 to 3 loop
                  if m(k) = '1' then sh(idx)(k*8+7 downto k*8) := w(k*8+7 downto k*8); end if;
               end loop;
            end if;
         end if;
         -- DMA write as it enters the cache
         if << signal .tb_s12.ipsx.ipsx_top.dma_cache_write : std_logic >> = '1' then
            idx := to_integer(unsigned(<< signal .tb_s12.ipsx.ipsx_top.dma_cache_Adr : std_logic_vector(21 downto 0) >>(21 downto 2)));
            sh(idx) := << signal .tb_s12.ipsx.ipsx_top.dma_cache_data : std_logic_vector(31 downto 0) >>;
         end if;
         if now >= tnext then
            write(l, now / 1 ms); write(l, string'(" ms hits ")); write(l, nhit); write(l, string'(" mismatches ")); write(l, nmis);
            writeline(f, l); flush(f);
            tnext := tnext + 10 ms;
         end if;
      end if;
   end process;

   -- libetc VSync() timeout branch executions (v_wait copies seen in Tenkomori): vsync_timeout.log
   process (clk1x)
      file f : text open write_mode is "vsync_timeout.log";
      variable l : line;
      variable p, pp : unsigned(31 downto 0) := (others => '0');
   begin
      if rising_edge(clk1x) then
         p := << signal .tb_s12.ipsx.ipsx_top.icpu.PCold2 : unsigned(31 downto 0) >>;
         if p /= pp and (p = x"8004C2D4" or p = x"80047C78" or p = x"80063D6C" or p = x"800819DC") then
            write(l, now / 1 us); write(l, string'(" us VSync timeout at ")); hwrite(l, std_logic_vector(p));
            writeline(f, l); flush(f);
         end if;
         pp := p;
      end if;
   end process;

   -- CPU stall breakdown per 10 ms window: cpu_stall.log
   --   run = no stall; ifetch = stall1 (instruction fetch / I-cache miss); dec = stall2;
   --   exe = stall3 (mul/div/GTE/HI-LO); mem = stall4 (data read/write); dma = DMA owns the bus
   process (clk1x)
      file f : text open write_mode is "cpu_stall.log";
      variable l : line;
      variable st : unsigned(4 downto 0);
      variable crun, cif, cdec, cexe, cmem, cdma : integer := 0;
      variable tnext : time := 10 ms;
   begin
      if rising_edge(clk1x) then
         st := unsigned(<< signal .tb_s12.ipsx.ipsx_top.icpu.stall : unsigned(4 downto 0) >>);
         if st = 0 then crun := crun + 1;
         elsif st(4) = '1' then cdma := cdma + 1;
         elsif st(3) = '1' then cmem := cmem + 1;
         elsif st(2) = '1' then cexe := cexe + 1;
         elsif st(1) = '1' then cdec := cdec + 1;
         else cif := cif + 1; end if;
         if now >= tnext then
            write(l, now / 1 ms); write(l, string'(" ms run ")); write(l, crun);
            write(l, string'(" ifetch ")); write(l, cif); write(l, string'(" dec ")); write(l, cdec);
            write(l, string'(" exe ")); write(l, cexe); write(l, string'(" mem ")); write(l, cmem);
            write(l, string'(" dma ")); write(l, cdma);
            writeline(f, l); flush(f);
            crun := 0; cif := 0; cdec := 0; cexe := 0; cmem := 0; cdma := 0;
            tnext := tnext + 10 ms;
         end if;
      end if;
   end process;

   -- MIPS PC / H8 PC every 100 us
   process
      file f : text open write_mode is "mips_pc.log";
      variable l : line;
   begin
      loop
         wait for 100 us;
         write(l, now / 1 us); write(l, string'(" us MIPS "));
         hwrite(l, std_logic_vector(<< signal .tb_s12.ipsx.ipsx_top.icpu.PC : unsigned(31 downto 0) >>));
         write(l, string'(" H8 "));
         hwrite(l, h8_pc);
         write(l, string'(" ISTAT "));
         hwrite(l, "0" & std_logic_vector(<< signal .tb_s12.ipsx.ipsx_top.iirq.I_STATUS : unsigned(10 downto 0) >>));
         write(l, string'(" IMASK "));
         hwrite(l, std_logic_vector(<< signal .tb_s12.ipsx.ipsx_top.iirq.I_MASK : unsigned(31 downto 0) >>));
         write(l, string'(" SR "));
         hwrite(l, std_logic_vector(<< signal .tb_s12.ipsx.ipsx_top.icpu.cop0_SR : unsigned(31 downto 0) >>));
         write(l, string'(" CAUSE "));
         hwrite(l, std_logic_vector(<< signal .tb_s12.ipsx.ipsx_top.icpu.cop0_CAUSE : unsigned(31 downto 0) >>));
         write(l, string'(" vbl ")); write(l, vbl_cnt);
         write(l, string'(" exc ")); write(l, exc_cnt);
         writeline(f, l); flush(f);
      end loop;
   end process;

   -- System 12 events
   process (clk1x)
      file f : text open write_mode is "s12_events.log";
      variable l : line;
      variable shw, shr : integer := 0;
      variable rd_d : std_logic := '0';
      variable ch3n, ch3r : integer := 0;
      variable sigd : std_logic := '0';
      variable ramn, ramd : integer := 0;
   begin
      if rising_edge(clk1x) then
         if rdma_start = '1' and rd_d = '0' then
            write(l, now / 1 us); write(l, string'(" us ROMDMA src "));
            hwrite(l, "0" & rdma_src);
            writeline(f, l); flush(f);
         end if;
         rd_d := rdma_start;
         if sh_we = '1' then shw := shw + 1; end if;
         if ch3_req = '1' and ch3n < 40 then
            ch3n := ch3n + 1;
            write(l, now / 1 ns); write(l, string'(" ns CH3 req addr "));
            hwrite(l, "0" & ch3_addr); write(l, string'(" rnw ")); write(l, ch3_rnw);
            writeline(f, l); flush(f);
         end if;
         if ch3_ready = '1' and ch3r < 40 then
            ch3r := ch3r + 1;
            write(l, now / 1 ns); write(l, string'(" ns CH3 ready dout "));
            hwrite(l, ch3_dout);
            writeline(f, l); flush(f);
         end if;
         if sig_done = '1' and sigd = '0' then
            write(l, now / 1 ns); write(l, string'(" ns signature copied, MIPS released"));
            writeline(f, l); flush(f);
         end if;
         sigd := sig_done;
         if ram_ena = '1' and ramn < 60 then
            ramn := ramn + 1;
            write(l, now / 1 ns); write(l, string'(" ns RAM req "));
            hwrite(l, "0" & ram_Adr); write(l, string'(" rnw ")); write(l, ram_rnw);
            write(l, string'(" cache ")); write(l, ram_iscache);
            writeline(f, l); flush(f);
         end if;
         if ram_done = '1' and ramd < 60 then
            ramd := ramd + 1;
            write(l, now / 1 ns); write(l, string'(" ns RAM done "));
            hwrite(l, ram_dataRead32);
            writeline(f, l); flush(f);
         end if;
         if h8_ill = '1' then
            write(l, now / 1 us); write(l, string'(" us H8 ILLEGAL at "));
            hwrite(l, h8_pc);
            writeline(f, l); flush(f);
            report "H8 illegal opcode" severity failure;
         end if;
      end if;
   end process;

end architecture;
