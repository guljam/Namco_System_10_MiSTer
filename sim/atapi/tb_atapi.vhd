-- tb_atapi -- replays MAME's ATA register accesses (local/mame/atacap.lua via prep.py) into s10_atapi.
-- Reads are compared with MAME. Where the drive is still loading a sector from the SD model (BSY) while MAME's
-- drive was instant, status reads are retried (counted as "busy polls"). After a DMA-mode packet the bench pops
-- the sector through the DMA port and checks it against the disc image (sums.txt).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;

entity tb_atapi is
   generic (MAXERR : integer := 20);
end entity;

architecture sim of tb_atapi is
   component s10_atapi is
      port (
         clk : in std_logic; reset : in std_logic; enable : in std_logic;
         addr : in std_logic_vector(23 downto 0); wdata : in std_logic_vector(31 downto 0);
         wmask : in std_logic_vector(3 downto 0); size : in std_logic_vector(1 downto 0);
         rd : in std_logic; wr : in std_logic; rdata : out std_logic_vector(31 downto 0);
         intrq : out std_logic; dma_pending : out std_logic; rdma_valid : out std_logic;
         rdma_pop : in std_logic; rdma_data : out std_logic_vector(31 downto 0);
         sd_lba : out std_logic_vector(31 downto 0); sd_blk_cnt : out std_logic_vector(5 downto 0);
         sd_rd : out std_logic; sd_ack : in std_logic;
         sd_buff_addr : in std_logic_vector(12 downto 0); sd_buff_dout : in std_logic_vector(15 downto 0);
         sd_buff_wr : in std_logic; img_mounted : in std_logic; img_size : in std_logic_vector(63 downto 0)
      );
   end component;

   constant CLKP : time := 29526 ps;
   signal clk   : std_logic := '1';
   signal reset : std_logic := '1';
   signal addr  : std_logic_vector(23 downto 0) := (others => '0');
   signal wdata : std_logic_vector(31 downto 0) := (others => '0');
   signal wmask : std_logic_vector(3 downto 0) := (others => '0');
   signal size  : std_logic_vector(1 downto 0) := "01";
   signal rd, wr : std_logic := '0';
   signal rdata : std_logic_vector(31 downto 0);
   signal intrq, dma_pending, rdma_valid : std_logic;
   signal rdma_pop : std_logic := '0';
   signal rdma_data : std_logic_vector(31 downto 0);
   signal sd_lba : std_logic_vector(31 downto 0);
   signal sd_rd : std_logic;
   signal sd_ack : std_logic := '0';
   signal sd_buff_addr : std_logic_vector(12 downto 0) := (others => '0');
   signal sd_blk_cnt : std_logic_vector(5 downto 0);
   signal sd_buff_dout : std_logic_vector(15 downto 0) := (others => '0');
   signal sd_buff_wr : std_logic := '0';
   signal img_mounted : std_logic := '0';
   signal img_size : std_logic_vector(63 downto 0) := (others => '0');

   constant NBLK : integer := 8192;
   type t_words is array (0 to 511) of integer;
   type t_store is array (0 to NBLK - 1) of t_words;
   type t_ints  is array (0 to NBLK - 1) of integer;
   shared variable store : t_store;
   shared variable bnum  : t_ints;
   shared variable nb    : integer := 0;
   shared variable slba, ssum : t_ints;
   shared variable ns    : integer := 0;
   signal loaded : std_logic := '0';
begin
   clk <= not clk after CLKP / 2;

   dut : s10_atapi
      port map (clk => clk, reset => reset, enable => '1', addr => addr, wdata => wdata, wmask => wmask, size => size,
                rd => rd, wr => wr, rdata => rdata, intrq => intrq, dma_pending => dma_pending,
                rdma_valid => rdma_valid, rdma_pop => rdma_pop, rdma_data => rdma_data,
                sd_lba => sd_lba, sd_blk_cnt => sd_blk_cnt, sd_rd => sd_rd, sd_ack => sd_ack, sd_buff_addr => sd_buff_addr,
                sd_buff_dout => sd_buff_dout, sd_buff_wr => sd_buff_wr, img_mounted => img_mounted, img_size => img_size);

   -- disc blocks + expected sector sums
   process
      file f : text;
      variable l : line;
      variable b, x : integer;
      variable c : character;
      variable h : std_logic_vector(7 downto 0);
      variable lo : integer;
   begin
      file_open(f, "blocks.txt", read_mode);
      while not endfile(f) loop
         readline(f, l);
         read(l, b); read(l, c);
         bnum(nb) := b;
         for i in 0 to 511 loop
            hread(l, h); lo := to_integer(unsigned(h));
            hread(l, h); store(nb)(i) := lo + 256 * to_integer(unsigned(h));
         end loop;
         nb := nb + 1;
      end loop;
      file_close(f);
      file_open(f, "sums.txt", read_mode);
      while not endfile(f) loop
         readline(f, l); read(l, b); read(l, x);
         slba(ns) := b; ssum(ns) := x; ns := ns + 1;
      end loop;
      file_close(f);
      report "loaded " & integer'image(nb) & " blocks, " & integer'image(ns) & " sector sums";
      loaded <= '1';
      wait;
   end process;

   -- hps_io slot model: 1 KB blocks, 16-bit words; sd_blk_cnt + 1 blocks per request, buffer address counting on
   process
      variable k, blk, nblk : integer;
   begin
      wait until loaded = '1';
      wait until rising_edge(clk);
      img_size <= std_logic_vector(to_unsigned(239976912, 64));
      img_mounted <= '1';
      wait until rising_edge(clk);
      img_mounted <= '0';
      loop
         wait until rising_edge(clk);
         if sd_rd = '1' then
            nblk := to_integer(unsigned(sd_blk_cnt)) + 1;
            for i in 1 to 40 loop wait until rising_edge(clk); end loop;
            sd_ack <= '1';
            for b in 0 to nblk - 1 loop
               blk := to_integer(unsigned(sd_lba)) + b;
               k := -1;
               for i in 0 to nb - 1 loop
                  if bnum(i) = blk then k := i; exit; end if;
               end loop;
               assert k >= 0 report "block " & integer'image(blk) & " not prepared" severity failure;
               for i in 0 to 511 loop
                  wait until rising_edge(clk);
                  sd_buff_addr <= std_logic_vector(to_unsigned(512 * b + i, 13));
                  sd_buff_dout <= std_logic_vector(to_unsigned(store(k)(i), 16));
                  sd_buff_wr <= '1';
                  wait until rising_edge(clk);
                  sd_buff_wr <= '0';
               end loop;
            end loop;
            wait until rising_edge(clk);
            sd_ack <= '0';
         end if;
      end loop;
   end process;

   -- replay
   process
      file f : text;
      variable l : line;
      variable c : character;
      variable a24 : std_logic_vector(23 downto 0);
      variable d32, m32 : std_logic_vector(31 downto 0);
      variable hi : boolean;
      variable got, exp : std_logic_vector(15 downto 0);
      variable nrec, nrd, nerr, nbusy, ndma : integer := 0;
      variable pk : integer := -1;              -- packet bytes collected (-1 = none)
      type t_pk is array (0 to 11) of integer;
      variable pkt : t_pk;
      variable lba, x, want, tries : integer;
      variable off : integer;
   begin
      wait until loaded = '1';
      for i in 1 to 20 loop wait until rising_edge(clk); end loop;
      reset <= '0';
      -- the drive detects the image format (block 0) before the first access
      for i in 1 to 3000 loop wait until rising_edge(clk); end loop;
      file_open(f, "trace.txt", read_mode);
      while not endfile(f) loop
         readline(f, l);
         read(l, c); hread(l, a24); hread(l, d32); hread(l, m32);
         nrec := nrec + 1;
         hi := (m32 = x"FFFF0000");
         off := to_integer(unsigned(a24(3 downto 0))) + 2 * boolean'pos(hi);
         if hi then addr <= a24(23 downto 2) & "10"; else addr <= a24(23 downto 2) & "00"; end if;
         size <= "01";
         if c = 'W' then
            wdata <= d32;
            if hi then wmask <= "1100"; else wmask <= "0011"; end if;
            wait until rising_edge(clk); wr <= '1';
            wait until rising_edge(clk); wr <= '0';
            -- packet bookkeeping (command A0, then 6 data words)
            if off = 14 then
               if hi and d32(23 downto 16) = x"A0" then pk := 0; else pk := -1; end if;
            elsif off = 0 and pk >= 0 then
               pkt(pk) := to_integer(unsigned(d32(7 downto 0))); pkt(pk + 1) := to_integer(unsigned(d32(15 downto 8)));
               pk := pk + 2;
               if pk = 12 then
                  pk := -1;
                  for i in 1 to 4 loop wait until rising_edge(clk); end loop;
                  if dma_pending = '1' then
                     -- DMA channel 5: 512 words of one sector
                     lba := ((pkt(2) * 256 + pkt(3)) * 256 + pkt(4)) * 256 + pkt(5);
                     x := 0;
                     for w in 0 to 511 loop
                        loop
                           wait until rising_edge(clk);
                           exit when rdma_valid = '1';
                        end loop;
                        x := to_integer(unsigned(std_logic_vector(to_unsigned(x, 16)) xor rdma_data(15 downto 0) xor rdma_data(31 downto 16)));
                        rdma_pop <= '1';
                        wait until rising_edge(clk);
                        rdma_pop <= '0';
                     end loop;
                     want := -1;
                     for i in 0 to ns - 1 loop if slba(i) = lba then want := ssum(i); exit; end if; end loop;
                     ndma := ndma + 1;
                     if want /= x then
                        nerr := nerr + 1;
                        report "DMA DATA MISMATCH lba " & integer'image(lba) & " sum " & integer'image(x) & " want " & integer'image(want);
                     end if;
                     for i in 1 to 4 loop wait until rising_edge(clk); end loop;
                  end if;
               end if;
            end if;
         else
            nrd := nrd + 1;
            tries := 0;
            loop
               wait until rising_edge(clk); rd <= '1';
               wait until rising_edge(clk); rd <= '0';
               wait until rising_edge(clk);
               if hi then got := rdata(31 downto 16); exp := d32(31 downto 16);
               else       got := rdata(15 downto 0);  exp := d32(15 downto 0); end if;
               exit when got = exp;
               -- drive still loading the sector (BSY) where MAME's was instant: poll again
               if off = 14 and got(7) = '1' and tries < 20000 then
                  tries := tries + 1; nbusy := nbusy + 1;
                  for i in 1 to 50 loop wait until rising_edge(clk); end loop;
               else
                  nerr := nerr + 1;
                  if nerr <= MAXERR then
                     report "MISMATCH #" & integer'image(nrec) & " R " & to_hstring(a24) & " off " & integer'image(off) &
                            " MAME " & to_hstring(exp) & " core " & to_hstring(got);
                  end if;
                  exit;
               end if;
            end loop;
         end if;
         if nrec mod 2000 = 0 then
            report "records " & integer'image(nrec) & " errors " & integer'image(nerr);
         end if;
      end loop;
      report "DONE records " & integer'image(nrec) & " reads " & integer'image(nrd) & " dma sectors " & integer'image(ndma) &
             " busy polls " & integer'image(nbusy) & " errors " & integer'image(nerr);
      if nerr = 0 then report "PASS"; else report "FAIL" severity error; end if;
      std.env.finish;
   end process;
end architecture;
