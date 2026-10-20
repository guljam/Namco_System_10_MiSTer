-- GPU-only replay bench: rtl/gpu.vhd + DDR3 VRAM model, GP0 words from gp0.txt via DMA ch2.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
library psx;
library tb;

entity tb_gpu is
   generic (SLOWVRAM : integer := 0; LOADV : std_logic := '0'; LOGV : std_logic := '0');
end entity;

architecture sim of tb_gpu is
   signal clk1x, clk2x, clkvid : std_logic := '0';
   signal clk2xIndex, clk1xToggle, clk1xToggle2x : std_logic := '0';
   signal reset : std_logic := '1';
   signal dma_we, dma_req, dma_on : std_logic := '0';
   signal dma_word : std_logic_vector(31 downto 0) := (others => '0');
   signal bus_addr : unsigned(3 downto 0) := (others => '0');
   signal bus_dw   : std_logic_vector(31 downto 0) := (others => '0');
   signal bus_wr   : std_logic := '0';
   signal gpustat  : std_logic_vector(31 downto 0);
   signal DDRAM_BUSY, DDRAM_DOUT_READY, DDRAM_RD, DDRAM_WE : std_logic;
   signal DDRAM_DOUT, DDRAM_DIN : std_logic_vector(63 downto 0);
   signal DDRAM_BURSTCNT, DDRAM_BE : std_logic_vector(7 downto 0);
   signal DDRAM_ADDR : std_logic_vector(28 downto 0);
   signal vram_ADDR : std_logic_vector(27 downto 0);
   signal fed : std_logic := '0';
   signal npix : integer := 0;
   type t_gp1 is array (natural range <>) of std_logic_vector(31 downto 0);
   constant GP1INIT : t_gp1(0 to 2) := (x"08000027", x"06C8C28C", x"07040010");
begin
   clk1x  <= not clk1x  after 14763 ps;
   clk2x  <= not clk2x  after  7381.5 ps;
   clkvid <= not clkvid after  9311 ps;
   reset  <= '0' after 1 us;

   process (clk1x) begin if rising_edge(clk1x) then clk1xToggle <= not clk1xToggle; end if; end process;
   process (clk2x) begin
      if rising_edge(clk2x) then
         clk1xToggle2x <= clk1xToggle;
         clk2xIndex <= '0';
         if clk1xToggle2x = clk1xToggle then clk2xIndex <= '1'; end if;
      end if;
   end process;

   DDRAM_ADDR <= "0011" & vram_ADDR(27 downto 3);
   process (clk2x) begin
      if rising_edge(clk2x) then
         if << signal .tb_gpu.igpu.pixelWrite : std_logic >> = '1' then npix <= npix + 1; end if;
      end if;
   end process;

   igpu : entity psx.gpu
      port map (
@@GPU_PORTMAP@@
      );

   iddr : entity tb.ddrram_model
      generic map (SLOWTIMING => SLOWVRAM, RANDOMTIMING => '0', LOGVRAM => LOGV, loadVram => LOADV)
      port map (DDRAM_CLK => clk2x, DDRAM_BUSY => DDRAM_BUSY, DDRAM_BURSTCNT => DDRAM_BURSTCNT, DDRAM_ADDR => DDRAM_ADDR,
                DDRAM_DOUT => DDRAM_DOUT, DDRAM_DOUT_READY => DDRAM_DOUT_READY, DDRAM_RD => DDRAM_RD,
                DDRAM_DIN => DDRAM_DIN, DDRAM_BE => DDRAM_BE, DDRAM_WE => DDRAM_WE);

   -- GP1: DMA direction CPU->GP0 (GP1 04000002), like the game before DrawOTag
   process
   begin
      wait until reset = '0';
      wait for 2 us;
      -- optional display setup from gp1.txt (e.g. 08000027 = 640x480 interlaced), then DMA direction
      for i in GP1INIT'range loop
         wait until rising_edge(clk1x);
         bus_addr <= x"4"; bus_dw <= GP1INIT(i); bus_wr <= '1';
         wait until rising_edge(clk1x);
         bus_wr <= '0';
      end loop;
      wait until rising_edge(clk1x);
      bus_addr <= x"4"; bus_dw <= x"04000002"; bus_wr <= '1';
      wait until rising_edge(clk1x);
      bus_wr <= '0';
      wait;
   end process;

   -- DMA channel 2 emulation: one word per clk1x while the GPU requests data
   process
      file f : text;
      variable st : file_open_status;
      variable l : line;
      variable w : std_logic_vector(31 downto 0);
      variable n : integer := 0;
      variable t0 : time;
      variable c : character;
   begin
      wait until reset = '0';
      wait for 5 us;
      file_open(st, f, "gp0.txt", read_mode);
      assert st = open_ok report "gp0.txt missing" severity failure;
      dma_on <= '1';
      t0 := now;
      while not endfile(f) loop
         readline(f, l);
         if l'length = 8 then
            hread(l, w);
            loop
               wait until rising_edge(clk1x);
               exit when dma_req = '1';
               dma_we <= '0';
            end loop;
            dma_we <= '1'; dma_word <= w; n := n + 1;
         end if;
      end loop;
      wait until rising_edge(clk1x);
      dma_we <= '0'; dma_on <= '0';
      report "FED " & integer'image(n) & " words in " & time'image(now - t0);
      fed <= '1';
      -- idle = ready for command (26) and ready for DMA block (28) for 2000 cycles
      loop
         for i in 1 to 2000 loop
            wait until rising_edge(clk1x);
            exit when not (gpustat(26) = '1' and gpustat(28) = '1');
         end loop;
         exit when gpustat(26) = '1' and gpustat(28) = '1';
      end loop;
      report "DONE frame drawn in " & time'image(now - t0 - 2000 * 29526 ps) & " pixels " & integer'image(npix) severity note;
      std.env.stop;
      wait;
   end process;
end architecture;
