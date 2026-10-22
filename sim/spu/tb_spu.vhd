-- tb_spu -- replays a MAME capture (local/mame spucap.lua via prep.py) into rtl/spu.vhd: SPU register writes and
-- DMA4 (RAM -> SPU) transfers at their emulated CPU cycle, SPU RAM in an ideal DDR3 model. Every SPU interrupt
-- (irqOut) is logged with its cycle to irq.txt, to compare with the interrupts MAME's game acknowledged.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;
library psx;

entity tb_spu is
   generic (
      TEND   : integer := 0;      -- stop at this CPU cycle (0 = end of the event file)
      TSTART : integer := 0;      -- events before this cycle are applied back to back (fast-forward to the window)
      DLAT   : integer := 4       -- DDR3 ack latency in clk2x (large = SPU RAM waiting behind the GPU on hardware)
   );
end entity;

architecture sim of tb_spu is
   signal clk1x, clk2x : std_logic := '0';
   signal clk2xIndex, clk1xToggle, clk1xToggle2x : std_logic := '0';
   signal reset : std_logic := '1';
   signal cyc : integer := 0;

   signal bus_addr  : unsigned(9 downto 0) := (others => '0');
   signal bus_dw    : std_logic_vector(15 downto 0) := (others => '0');
   signal bus_wr, bus_rd : std_logic := '0';
   signal bus_dr    : std_logic_vector(15 downto 0);
   signal dma_req, dma_we : std_logic := '0';
   signal dma_wd    : std_logic_vector(15 downto 0) := (others => '0');
   signal irq       : std_logic;

   signal mem_request, mem_WE, mem_RD : std_logic;
   signal mem_BURSTCNT, mem_BE : std_logic_vector(7 downto 0);
   signal mem_ADDR  : std_logic_vector(19 downto 0);
   signal mem_DIN   : std_logic_vector(63 downto 0);
   signal mem_ack, mem_rdy : std_logic := '0';
   signal mem_DOUT  : std_logic_vector(63 downto 0) := (others => '0');
   signal snd_l, snd_r : std_logic_vector(15 downto 0);
   signal nirq : integer := 0;
begin
   clk1x <= not clk1x after 14763 ps;
   clk2x <= not clk2x after  7381.5 ps;
   process (clk1x) begin
      if rising_edge(clk1x) then
         clk1xToggle <= not clk1xToggle;
         if reset = '0' then cyc <= cyc + 1; end if;
      end if;
   end process;
   process (clk2x) begin
      if rising_edge(clk2x) then
         clk1xToggle2x <= clk1xToggle;
         clk2xIndex <= '0';
         if clk1xToggle2x = clk1xToggle then clk2xIndex <= '1'; end if;
      end if;
   end process;

   ispu : entity psx.spu
      port map (
         clk1x => clk1x, clk2x => clk2x, clk2xIndex => clk2xIndex, ce => '1', reset => reset,
         SPUon => '1', SPUIRQTrigger => '0', useSDRAM => '0', REPRODUCIBLESPUIRQ => '1', REPRODUCIBLESPUDMA => '0',
         REVERBOFF => '0', cpuPaused => '0', spu_tick => open, cd_left => (others => '0'), cd_right => (others => '0'),
         irqOut => irq, sound_timeout => open, sound_out_left => snd_l, sound_out_right => snd_r,
         bus_addr => bus_addr, bus_dataWrite => bus_dw, bus_read => bus_rd, bus_write => bus_wr, bus_dataRead => bus_dr,
         spu_dmaRequest => dma_req, dma_read => '0', dma_readdata => open, dma_write => dma_we, dma_writedata => dma_wd,
         sdram_dataWrite => open, sdram_Adr => open, sdram_be => open, sdram_rnw => open, sdram_ena => open,
         sdram_dataRead => (others => '0'), sdram_done => '0',
         mem_request => mem_request, mem_BURSTCNT => mem_BURSTCNT, mem_ADDR => mem_ADDR, mem_DIN => mem_DIN,
         mem_BE => mem_BE, mem_WE => mem_WE, mem_RD => mem_RD, mem_ack => mem_ack, mem_DOUT => mem_DOUT,
         mem_DOUT_READY => mem_rdy,
         SS_reset => '0', loading_savestate => '0', SS_DataWrite => (others => '0'), SS_Adr => (others => '0'),
         SS_wren => '0', SS_rden => '0', SS_DataRead => open, SS_idle => open,
         SS_RAM_dataWrite => (others => '0'), SS_RAM_Adr => (others => '0'), SS_RAM_request => '0', SS_RAM_rnw => '0',
         SS_RAM_dataRead => open, SS_RAM_done => open);

   -- ideal DDR3 for the 512 KB sound RAM (64-bit words, byte address in mem_ADDR)
   process
      type t_ram is array (0 to 65535) of std_logic_vector(63 downto 0);
      variable ram : t_ram := (others => (others => '0'));
      variable a : integer;
   begin
      wait until rising_edge(clk2x);
      if mem_request = '1' then
         a := to_integer(unsigned(mem_ADDR(18 downto 3)));
         for i in 1 to DLAT loop wait until rising_edge(clk2x); end loop;
         mem_ack <= '1';
         wait until rising_edge(clk2x);
         mem_ack <= '0';
         if mem_WE = '1' then
            for b in 0 to 7 loop
               if mem_BE(b) = '1' then ram(a)(8 * b + 7 downto 8 * b) := mem_DIN(8 * b + 7 downto 8 * b); end if;
            end loop;
            wait until rising_edge(clk2x);
         else
            for i in 1 to 8 loop wait until rising_edge(clk2x); end loop;
            for k in 0 to to_integer(unsigned(mem_BURSTCNT)) - 1 loop
               mem_DOUT <= ram((a + k) mod 65536); mem_rdy <= '1';
               wait until rising_edge(clk2x);
            end loop;
            mem_rdy <= '0';
            wait until rising_edge(clk2x);
         end if;
      end if;
   end process;

   -- output energy per 10 ms of SPU time: mean |L| + |R| (energy.txt: cycle, energy)
   process
      file fo : text open write_mode is "energy.txt";
      variable l : line;
      variable acc : integer := 0;
      variable k : integer := 0;
      variable smax : integer := 0;
      alias stash is << signal .tb_spu.ispu.stashedSamples : integer >>;
   begin
      wait until rising_edge(clk1x);
      acc := acc + abs(to_integer(signed(snd_l))) / 64 + abs(to_integer(signed(snd_r))) / 64;
      if stash > smax then smax := stash; end if;
      k := k + 1;
      if k = 338688 then
         -- cycle, mean output, max stashed samples (SPU behind) in the window
         write(l, cyc); write(l, string'(" ")); write(l, acc / 5292); write(l, string'(" ")); write(l, smax); writeline(fo, l);
         acc := 0; k := 0; smax := 0;
      end if;
   end process;

   -- interrupt log
   process
      file fo : text open write_mode is "irq.txt";
      variable l : line;
   begin
      wait until rising_edge(clk1x);
      if irq = '1' then
         write(l, cyc); writeline(fo, l);
         nirq <= nirq + 1;
      end if;
   end process;

   -- replay
   process
      file f : text;
      variable l : line;
      variable c : character;
      variable t, r, n, d : integer;
      variable w : std_logic_vector(31 downto 0);
      variable h : std_logic_vector(15 downto 0);
      variable nev : integer := 0;
      variable tbase : integer := 0;
      alias fifo_full is << signal .tb_spu.ispu.FifoIn_Full : std_logic >>;
   begin
      wait for 1 us;
      wait until rising_edge(clk1x);
      reset <= '0';
      file_open(f, "events.txt", read_mode);
      while not endfile(f) loop
         readline(f, l);
         read(l, c); read(l, t);
         exit when TEND > 0 and t > TEND;
         if t >= TSTART then
            if cyc < t - TSTART + tbase then
               while cyc < t - TSTART + tbase loop wait until rising_edge(clk1x); end loop;
            end if;
         else
            for i in 1 to 64 loop wait until rising_edge(clk1x); end loop;   -- fast-forward: give the SPU time per write
            tbase := cyc + 64;
         end if;
         if c = 'W' then
            read(l, r); hread(l, h);
            bus_addr <= to_unsigned(r, 10); bus_dw <= h; bus_wr <= '1';
            wait until rising_edge(clk1x);
            bus_wr <= '0';
         elsif c = 'R' then
            read(l, r);
            bus_addr <= to_unsigned(r, 10); bus_rd <= '1';
            wait until rising_edge(clk1x);
            bus_rd <= '0';
         elsif c = 'D' then
            read(l, n);
            for i in 0 to n - 1 loop
               readline(f, l); hread(l, w);
               for half in 0 to 1 loop
                  loop
                     wait until rising_edge(clk1x);
                     exit when fifo_full = '0';
                  end loop;
                  if half = 0 then dma_wd <= w(15 downto 0); else dma_wd <= w(31 downto 16); end if;
                  dma_we <= '1';
                  wait until rising_edge(clk1x);
                  dma_we <= '0';
               end loop;
            end loop;
         end if;
         nev := nev + 1;
         if nev mod 20000 = 0 then
            report "events " & integer'image(nev) & " cycle " & integer'image(cyc) & " irqs " & integer'image(nirq);
         end if;
      end loop;
      report "DONE events " & integer'image(nev) & " cycle " & integer'image(cyc) & " irqs " & integer'image(nirq);
      std.env.finish;
   end process;
end architecture;
