-- ============================================================================
-- tb_board -- replays MAME's MEM-board accesses (local/mame/boardcap.lua) into s10_mem
-- Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later
-- ----------------------------------------------------------------------------
-- capture.bin records: type (0 write / 1 read) + address + data + mem_mask (u32 LE). Each access is
-- presented on the board bus as the PSX memory mux does (writes word-aligned with byte lanes, reads
-- with the byte address and size); every read is compared with MAME's value on the masked lanes.
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

library tb;

entity tb_board is
   generic (OLDDMA : integer := 0; 
      CAP_IMG : string := "capture.bin";
      DDR_IMG : string := "ddr.bin";
      REC_IMG : string := "record.bin";
      MAXERR  : integer := 20
   );
end entity;

architecture sim of tb_board is

   component s10_mem is
      port (
         clk : in std_logic; clk2 : in std_logic; reset : in std_logic;
         board_memn : in std_logic; crypt_type : in std_logic_vector(1 downto 0);
         nand_count : in std_logic_vector(4 downto 0); nand_big : in std_logic;
         data_xor : in std_logic_vector(15 downto 0); perm : in std_logic_vector(63 downto 0);
         img_base : in std_logic_vector(27 downto 0); save_base : in std_logic_vector(27 downto 0);
         t2_row_we : in std_logic; t2_row_addr : in std_logic_vector(5 downto 0);
         t2_row_lane : in std_logic_vector(2 downto 0); t2_row_data : in std_logic_vector(15 downto 0);
         t2_xmask : in std_logic_vector(15 downto 0); t2_nl_out : in std_logic_vector(15 downto 0);
         t2_nterms : in std_logic_vector(2 downto 0);
         t2_nl_table : in std_logic; t2_nl_bits : in std_logic_vector(20 downto 0);
         nl_off : in std_logic_vector(27 downto 0);
         addr : in std_logic_vector(23 downto 0); wdata : in std_logic_vector(31 downto 0);
         wmask : in std_logic_vector(3 downto 0); size : in std_logic_vector(1 downto 0);
         rd : in std_logic; wr : in std_logic; rdata : out std_logic_vector(31 downto 0); stall : out std_logic;
         rdma_start : in std_logic; rdma_valid : out std_logic; rdma_pop : in std_logic; rdma_want : in std_logic;
         rdma_data : out std_logic_vector(31 downto 0);
         sram_req : out std_logic; sram_addr : out std_logic_vector(19 downto 0); sram_rnw : out std_logic;
         sram_be : out std_logic_vector(3 downto 0); sram_wdata : out std_logic_vector(31 downto 0);
         sram_rdata : in std_logic_vector(31 downto 0); sram_ready : in std_logic;
         up_active : in std_logic; up_rd : in std_logic; up_addr : in std_logic_vector(26 downto 0);
         up_din : out std_logic_vector(15 downto 0); up_wait : out std_logic; save_req : out std_logic;
         ddr_request : out std_logic; ddr_ack : in std_logic; ddr_burstcnt : out std_logic_vector(7 downto 0);
         ddr_addr : out std_logic_vector(27 downto 0); ddr_din : out std_logic_vector(63 downto 0);
         ddr_be : out std_logic_vector(7 downto 0); ddr_we : out std_logic; ddr_rd : out std_logic;
         ddr_dout : in std_logic_vector(63 downto 0); ddr_dout_ready : in std_logic
      );
   end component;

   component s10_loader is
      port (
         clk : in std_logic; clk2 : in std_logic;
         ioctl_download : in std_logic; ioctl_index : in std_logic_vector(7 downto 0);
         ioctl_wr : in std_logic; ioctl_addr : in std_logic_vector(26 downto 0);
         ioctl_dout : in std_logic_vector(15 downto 0); ioctl_wait : out std_logic;
         board_memn : out std_logic; crypt_type : out std_logic_vector(1 downto 0);
         nand_count : out std_logic_vector(4 downto 0); nand_big : out std_logic;
         data_xor : out std_logic_vector(15 downto 0); perm : out std_logic_vector(63 downto 0);
         exio_ident : out std_logic_vector(7 downto 0); save_base : out std_logic_vector(27 downto 0);
         t2_row_we : out std_logic; t2_row_addr : out std_logic_vector(5 downto 0);
         t2_row_lane : out std_logic_vector(2 downto 0); t2_row_data : out std_logic_vector(15 downto 0);
         t2_xmask : out std_logic_vector(15 downto 0); t2_nl_out : out std_logic_vector(15 downto 0);
         t2_nterms : out std_logic_vector(2 downto 0); record_ok : out std_logic;
         nl_table : out std_logic; light_gun : out std_logic; cdrom : out std_logic; exio_mcu : out std_logic; exio_analog : out std_logic; memp3 : out std_logic; in1_layout : out std_logic_vector(3 downto 0);
         nl_bits : out std_logic_vector(20 downto 0);
         dl_req : out std_logic; dl_addr : out std_logic_vector(26 downto 0); dl_data : out std_logic_vector(31 downto 0);
         dl_done : in std_logic; fill_start : out std_logic; fill_base : out std_logic_vector(26 downto 0);
         fill_words : out std_logic_vector(20 downto 0); fill_value : out std_logic_vector(31 downto 0);
         fill_busy : in std_logic; ddr_own : out std_logic; ddr_we : out std_logic;
         ddr_addr : out std_logic_vector(27 downto 0); ddr_din : out std_logic_vector(63 downto 0);
         ddr_be : out std_logic_vector(7 downto 0); ddr_busy : in std_logic
      );
   end component;

   signal clk1x  : std_logic := '1';
   signal clk2x  : std_logic := '1';
   signal reset  : std_logic := '1';

   signal DDRAM_BUSY, DDRAM_DOUT_READY : std_logic;
   signal DDRAM_RD, DDRAM_WE : std_logic := '0';
   signal DDRAM_BURSTCNT, DDRAM_BE : std_logic_vector(7 downto 0) := (others => '0');
   signal DDRAM_ADDR : std_logic_vector(28 downto 0) := (others => '0');
   signal DDRAM_DOUT : std_logic_vector(63 downto 0);
   signal DDRAM_DIN  : std_logic_vector(63 downto 0) := (others => '0');

   signal addr  : std_logic_vector(23 downto 0) := (others => '0');
   signal wdata : std_logic_vector(31 downto 0) := (others => '0');
   signal wmask : std_logic_vector(3 downto 0) := (others => '0');
   signal size  : std_logic_vector(1 downto 0) := "10";
   signal rd, wr : std_logic := '0';
   signal rdata : std_logic_vector(31 downto 0);
   signal stall : std_logic;

   signal d_req, d_we, d_rd : std_logic;
   signal rd_dbg : std_logic := '0';
   signal d_ack : std_logic := '0';
   signal d_burst, d_be : std_logic_vector(7 downto 0);
   signal d_addr : std_logic_vector(27 downto 0);
   signal d_din : std_logic_vector(63 downto 0);

   signal sram_req, sram_rnw : std_logic;
   signal sram_ready : std_logic := '0';
   signal sram_addr : std_logic_vector(19 downto 0);
   signal sram_be : std_logic_vector(3 downto 0);
   signal sram_wdata : std_logic_vector(31 downto 0);
   signal sram_rdata : std_logic_vector(31 downto 0) := (others => '0');

   signal ioctl_download, ioctl_wr : std_logic := '0';
   signal ioctl_addr  : std_logic_vector(26 downto 0) := (others => '0');
   signal ioctl_dout  : std_logic_vector(15 downto 0) := (others => '0');
   signal b_memn, b_nand_big, b_record_ok : std_logic;
   signal b_crypt : std_logic_vector(1 downto 0);
   signal b_nand_count : std_logic_vector(4 downto 0);
   signal b_data_xor, b_t2_xmask, b_t2_nl_out : std_logic_vector(15 downto 0);
   signal b_perm : std_logic_vector(63 downto 0);
   signal b_t2_row_we : std_logic;
   signal b_t2_row_addr : std_logic_vector(5 downto 0);
   signal b_t2_row_lane, b_t2_nterms : std_logic_vector(2 downto 0);
   signal b_t2_row_data : std_logic_vector(15 downto 0);
   signal b_exio : std_logic_vector(7 downto 0);
   signal b_nl_table, b_light_gun : std_logic;
   signal b_nl_bits : std_logic_vector(20 downto 0);
   signal b_save_base : std_logic_vector(27 downto 0);

   signal rdma_start, rdma_pop, rdma_want : std_logic := '0';
   signal rdma_want_dut : std_logic;
   signal rdma_valid : std_logic;
   signal rdma_data  : std_logic_vector(31 downto 0);
begin
   -- OLDDMA=1: the device may read ahead at any time (behaviour before the rdma_want fix)
   rdma_want_dut <= '1' when OLDDMA = 1 else rdma_want;

   clk1x <= not clk1x after 14763 ps;
   clk2x <= not clk2x after 7381.5 ps;

   imem : s10_mem
      port map (
         clk => clk1x, clk2 => clk2x, reset => reset,
         board_memn => b_memn, crypt_type => b_crypt, nand_count => b_nand_count, nand_big => b_nand_big,
         data_xor => b_data_xor, perm => b_perm, img_base => x"0800000", save_base => b_save_base,
         t2_row_we => b_t2_row_we, t2_row_addr => b_t2_row_addr, t2_row_lane => b_t2_row_lane,
         t2_row_data => b_t2_row_data, t2_xmask => b_t2_xmask, t2_nl_out => b_t2_nl_out, t2_nterms => b_t2_nterms,
         t2_nl_table => b_nl_table, t2_nl_bits => b_nl_bits, nl_off => x"F000000",
         addr => addr, wdata => wdata, wmask => wmask, size => size, rd => rd, wr => wr,
         rdata => rdata, stall => stall,
         rdma_start => rdma_start, rdma_valid => rdma_valid, rdma_pop => rdma_pop, rdma_want => rdma_want_dut, rdma_data => rdma_data,
         sram_req => sram_req, sram_addr => sram_addr, sram_rnw => sram_rnw, sram_be => sram_be,
         sram_wdata => sram_wdata, sram_rdata => sram_rdata, sram_ready => sram_ready,
         up_active => '0', up_rd => '0', up_addr => (others => '0'), up_din => open, up_wait => open, save_req => open,
         ddr_request => d_req, ddr_ack => d_ack, ddr_burstcnt => d_burst, ddr_addr => d_addr, ddr_din => d_din,
         ddr_be => d_be, ddr_we => d_we, ddr_rd => d_rd, ddr_dout => DDRAM_DOUT, ddr_dout_ready => DDRAM_DOUT_READY
      );

   -- arbiter stand-in (psx_top's: present the request, ack when the bridge takes it, wait for release)
   process (clk2x)
      variable active : std_logic := '0';
   begin
      if rising_edge(clk2x) then
         d_ack <= '0';
         if active = '0' then
            if d_req = '1' then
               active := '1';
               DDRAM_ADDR     <= "0011" & d_addr(27 downto 3);
               DDRAM_BURSTCNT <= d_burst;
               DDRAM_DIN      <= d_din;
               DDRAM_BE       <= d_be;
               DDRAM_WE       <= d_we;
               DDRAM_RD       <= d_rd;
            end if;
         elsif (DDRAM_WE = '1' or DDRAM_RD = '1') then
            if DDRAM_BUSY = '0' then
               DDRAM_WE <= '0'; DDRAM_RD <= '0';
               d_ack <= '1';
            end if;
         elsif d_req = '0' then
            active := '0';
         end if;
      end if;
   end process;

   iddr : entity tb.ddrram_model
      generic map (SLOWTIMING => 0, RANDOMTIMING => '0', LOGVRAM => '0', INITFILE => DDR_IMG, INITOFFSET => 16#0800000#)
      port map (
         DDRAM_CLK => clk2x, DDRAM_BUSY => DDRAM_BUSY, DDRAM_BURSTCNT => DDRAM_BURSTCNT, DDRAM_ADDR => DDRAM_ADDR,
         DDRAM_DOUT => DDRAM_DOUT, DDRAM_DOUT_READY => DDRAM_DOUT_READY, DDRAM_RD => DDRAM_RD,
         DDRAM_DIN => DDRAM_DIN, DDRAM_BE => DDRAM_BE, DDRAM_WE => DDRAM_WE
      );

   -- SRAM (bad-block table, 1 MB) behind a 3-cycle ready
   process (clk1x)
      type mem_t is array(0 to 262143) of std_logic_vector(31 downto 0);
      variable mem : mem_t := (others => (others => '0'));
      variable cnt : integer := 0;
      variable w : std_logic_vector(31 downto 0);
   begin
      if rising_edge(clk1x) then
         sram_ready <= '0';
         if sram_req = '1' and sram_ready = '0' then
            cnt := cnt + 1;
            if cnt = 3 then
               cnt := 0;
               if sram_rnw = '1' then
                  sram_rdata <= mem(to_integer(unsigned(sram_addr(19 downto 2))));
               else
                  w := mem(to_integer(unsigned(sram_addr(19 downto 2))));
                  for b in 0 to 3 loop
                     if sram_be(b) = '1' then w(8*b+7 downto 8*b) := sram_wdata(8*b+7 downto 8*b); end if;
                  end loop;
                  mem(to_integer(unsigned(sram_addr(19 downto 2)))) := w;
               end if;
               sram_ready <= '1';
            end if;
         end if;
      end if;
   end process;


   -- debug: DDR3 writes to the start of NAND0 page 0x20 (image 0x4200)
   process (clk2x)
   begin
      if rising_edge(clk2x) then
         if d_req = '1' and d_we = '1' and d_ack = '1' and unsigned(d_addr) >= x"2004200" and unsigned(d_addr) < x"2004240" then
            report "DDRW " & to_hstring(d_addr) & " " & to_hstring(d_din) & " be " & to_hstring(d_be);
         end if;
         if d_req = '1' and d_rd = '1' and d_ack = '1' and unsigned(d_addr) >= x"2004200" and unsigned(d_addr) < x"2004210" then
            report "DDRR req " & to_hstring(d_addr) & " burst " & to_hstring(d_burst);
            rd_dbg <= '1';
         elsif d_req = '1' and d_rd = '1' and d_ack = '1' then
            rd_dbg <= '0';
         end if;
         if DDRAM_DOUT_READY = '1' and rd_dbg = '1' then
            report "DDRR data " & to_hstring(DDRAM_DOUT);
         end if;
      end if;
   end process;
   ildr : s10_loader
      port map (
         clk => clk1x, clk2 => clk2x,
         ioctl_download => ioctl_download, ioctl_index => x"01", ioctl_wr => ioctl_wr,
         ioctl_addr => ioctl_addr, ioctl_dout => ioctl_dout, ioctl_wait => open,
         board_memn => b_memn, crypt_type => b_crypt, nand_count => b_nand_count, nand_big => b_nand_big,
         data_xor => b_data_xor, perm => b_perm, exio_ident => b_exio, save_base => b_save_base,
         t2_row_we => b_t2_row_we, t2_row_addr => b_t2_row_addr, t2_row_lane => b_t2_row_lane,
         t2_row_data => b_t2_row_data, t2_xmask => b_t2_xmask, t2_nl_out => b_t2_nl_out, t2_nterms => b_t2_nterms, record_ok => b_record_ok,
         nl_table => b_nl_table, light_gun => b_light_gun, cdrom => open, exio_mcu => open, exio_analog => open, memp3 => open, in1_layout => open, nl_bits => b_nl_bits,
         dl_req => open, dl_addr => open, dl_data => open, dl_done => '0',
         fill_start => open, fill_base => open, fill_words => open, fill_value => open, fill_busy => '0',
         ddr_own => open, ddr_we => open, ddr_addr => open, ddr_din => open, ddr_be => open, ddr_busy => '0'
      );

   process
      type cfile is file of character;
      file f : cfile;
      file fr : cfile;
      variable st : file_open_status;
      variable c : character;
      variable ty : integer;
      variable a, d, mk : std_logic_vector(31 downto 0);
      variable n, reads, errs, waitc, skew : integer := 0;
      variable lanes : std_logic_vector(3 downto 0);
      variable l : line;
      variable c0, c1 : character;
      variable ra : integer := 0;
      variable dmaw, dmawords : integer := 0;

      procedure get32(variable v : out std_logic_vector(31 downto 0)) is
         variable ch : character;
      begin
         for b in 0 to 3 loop
            read(f, ch);
            v(8*b+7 downto 8*b) := std_logic_vector(to_unsigned(character'pos(ch), 8));
         end loop;
      end procedure;
   begin
      -- board record (MRA index 1)
      file_open(st, fr, REC_IMG, read_mode);
      assert st = open_ok report "cannot open " & REC_IMG severity failure;
      wait until rising_edge(clk1x);
      ioctl_download <= '1';
      wait until rising_edge(clk1x); wait until rising_edge(clk1x);
      while not endfile(fr) loop
         read(fr, c0); read(fr, c1);
         ioctl_addr <= std_logic_vector(to_unsigned(ra, 27));
         ioctl_dout <= std_logic_vector(to_unsigned(character'pos(c1), 8)) & std_logic_vector(to_unsigned(character'pos(c0), 8));
         ioctl_wr <= '1'; wait until rising_edge(clk1x); ioctl_wr <= '0'; wait until rising_edge(clk1x);
         ra := ra + 2;
      end loop;
      ioctl_download <= '0';
      for i in 0 to 9 loop wait until rising_edge(clk1x); end loop;
      assert b_record_ok = '1' report "record not accepted" severity failure;
      hwrite(l, b_t2_nl_out);
      write(l, string'(" xor ")); hwrite(l, b_data_xor); write(l, string'(" perm ")); hwrite(l, b_perm); writeline(output, l);
      if MAXERR < 0 then std.env.finish; end if;
      reset <= '0';
      for i in 0 to 9 loop wait until rising_edge(clk1x); end loop;

      file_open(st, f, CAP_IMG, read_mode);
      assert st = open_ok report "cannot open " & CAP_IMG severity failure;
      while not endfile(f) loop
         read(f, c); ty := character'pos(c);
         get32(a); get32(d); get32(mk);
         for b in 0 to 3 loop lanes(b) := mk(8*b); end loop;
         n := n + 1;
         if ty = 2 then
            -- channel-5 DMA (MEM(N) NAND -> RAM): words compared with the data MAME's transfer left in RAM
            rdma_start <= '1'; wait until rising_edge(clk1x); rdma_start <= '0';
            rdma_want  <= '1';
            dmaw := to_integer(unsigned(d));
            for w in 0 to dmaw - 1 loop
               read(f, c); get32(a); get32(d); get32(mk);
               n := n + 1;
               waitc := 0;
               loop
                  wait until rising_edge(clk1x);
                  exit when rdma_valid = '1';
                  waitc := waitc + 1;
                  assert waitc < 100000 report "DMA word never arrives" severity failure;
               end loop;
               if w = dmaw - 1 then rdma_want <= '0'; end if;   -- the DMA stops wanting with its last word
               rdma_pop <= '1'; wait until rising_edge(clk1x); rdma_pop <= '0';
               dmawords := dmawords + 1;
               if rdma_data /= d then
                  errs := errs + 1;
                  if errs <= MAXERR then
                     write(l, string'("DMA MISMATCH #")); write(l, n); write(l, string'(" RAM "));
                     hwrite(l, a); write(l, string'(" MAME ")); hwrite(l, d); write(l, string'(" core ")); hwrite(l, rdma_data);
                     writeline(output, l);
                  end if;
               end if;
            end loop;
            rdma_want <= '0';
            for i in 0 to 7 loop wait until rising_edge(clk1x); end loop;
         elsif ty = 0 then
            addr  <= a(23 downto 2) & "00";
            wdata <= d;
            wmask <= lanes;
            size  <= "10";
            wr <= '1'; wait until rising_edge(clk1x); wr <= '0';
            for i in 0 to 3 loop wait until rising_edge(clk1x); end loop;
         else
            -- byte address and size as the memory mux presents a load
            if lanes = "1111" then size <= "10"; addr <= a(23 downto 2) & "00";
            elsif lanes = "0011" then size <= "01"; addr <= a(23 downto 2) & "00";
            elsif lanes = "1100" then size <= "01"; addr <= a(23 downto 2) & "10";
            else
               size <= "00";
               if    lanes(0) = '1' then addr <= a(23 downto 2) & "00";
               elsif lanes(1) = '1' then addr <= a(23 downto 2) & "01";
               elsif lanes(2) = '1' then addr <= a(23 downto 2) & "10";
               else                      addr <= a(23 downto 2) & "11"; end if;
            end if;
            rd <= '1'; wait until rising_edge(clk1x); rd <= '0';
            wait until rising_edge(clk1x);
            waitc := 0;
            while stall = '1' loop
               wait until rising_edge(clk1x);
               waitc := waitc + 1;
               assert waitc < 100000 report "read never completes" severity failure;
            end loop;
            reads := reads + 1;
            if (rdata and mk) /= (d and mk) and (d and mk) = x"00000000" and (rdata and mk) = (x"00800080" and mk) then
               -- flash erase busy window: MAME reports busy for 1 s of emulated time; the replay runs
               -- MAME's polls faster than a real CPU, so the core's 1 s timer ends after fewer polls
               skew := skew + 1;
            elsif (rdata and mk) /= (d and mk) then
               errs := errs + 1;
               if errs <= MAXERR then
                  write(l, string'("MISMATCH #")); write(l, n); write(l, string'(" R "));
                  hwrite(l, a); write(l, string'(" mask ")); hwrite(l, mk);
                  write(l, string'(" MAME ")); hwrite(l, d); write(l, string'(" core ")); hwrite(l, rdata);
                  writeline(output, l);
               end if;
            end if;
         end if;
         if n mod 200000 = 0 then
            write(l, string'("records ")); write(l, n); write(l, string'(" reads ")); write(l, reads);
            write(l, string'(" errors ")); write(l, errs); writeline(output, l);
         end if;
      end loop;
      write(l, string'("DONE records ")); write(l, n); write(l, string'(" reads ")); write(l, reads);
      write(l, string'(" erase-busy polls (timing) ")); write(l, skew);
      write(l, string'(" dma words ")); write(l, dmawords);
      write(l, string'(" errors ")); write(l, errs); writeline(output, l);
      if errs = 0 then report "PASS"; else report "FAIL" severity error; end if;
      std.env.finish;
   end process;
end architecture;
