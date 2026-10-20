-- ============================================================================
-- s10_ch3 -- SDRAM channel 3 arbiter for the Namco System 10 core
-- Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later
-- ----------------------------------------------------------------------------
-- Channel 3 of rtl/sdram.sv (lowest priority behind the MIPS channels) serves, in priority order:
--   1. download writes (descrambled BIOS from the loader)
--   2. fills: a word range set to a value (BIOS area to 0x55555555 before the BIOS arrives, main RAM to
--      zero after the download - MAME initialises both that way)
--   3. the MEM(N) board SRAM window (s10_mem; SDRAM SRAM_BASE + 1 MB)
-- One transaction is in flight at a time; address/data/rnw are held until ch3_ready. clk = clk_1x.
-- ============================================================================
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity s10_ch3 is
   generic (
      SRAM_BASE   : natural := 16#0800000#
   );
   port (
      clk         : in  std_logic;

      ch3_addr    : out std_logic_vector(26 downto 0) := (others => '0');
      ch3_din     : out std_logic_vector(31 downto 0) := (others => '0');
      ch3_dout    : in  std_logic_vector(31 downto 0);
      ch3_req     : out std_logic := '0';
      ch3_rnw     : out std_logic := '1';
      ch3_be      : out std_logic_vector(3 downto 0) := (others => '1');
      ch3_ready   : in  std_logic;

      dl_req      : in  std_logic := '0';
      dl_addr     : in  std_logic_vector(26 downto 0) := (others => '0');
      dl_data     : in  std_logic_vector(31 downto 0) := (others => '0');
      dl_done     : out std_logic := '0';

      fill_start  : in  std_logic := '0';                                  -- pulse
      fill_base   : in  std_logic_vector(26 downto 0) := (others => '0');  -- byte address, word aligned
      fill_words  : in  std_logic_vector(20 downto 0) := (others => '0');
      fill_value  : in  std_logic_vector(31 downto 0) := (others => '0');
      fill_busy   : out std_logic := '0';

      sram_req    : in  std_logic := '0';
      sram_addr   : in  std_logic_vector(19 downto 0) := (others => '0');
      sram_rnw    : in  std_logic := '1';
      sram_be     : in  std_logic_vector(3 downto 0) := (others => '1');
      sram_wdata  : in  std_logic_vector(31 downto 0) := (others => '0');
      sram_rdata  : out std_logic_vector(31 downto 0) := (others => '0');
      sram_ready  : out std_logic := '0'
   );
end entity;

architecture rtl of s10_ch3 is

   type own_t is (O_DL, O_FILL, O_SRAM);
   signal own        : own_t := O_DL;
   signal busy       : std_logic := '0';

   signal dl_pend    : std_logic := '0';
   signal dl_a       : std_logic_vector(26 downto 0) := (others => '0');
   signal dl_d       : std_logic_vector(31 downto 0) := (others => '0');

   signal fill_act   : std_logic := '0';
   signal fill_addr  : unsigned(26 downto 0) := (others => '0');
   signal fill_left  : unsigned(20 downto 0) := (others => '0');
   signal fill_val   : std_logic_vector(31 downto 0) := (others => '0');

   signal sram_drop  : std_logic := '0';   -- requester still holds req in the cycle after ready

begin

   fill_busy <= fill_act;

   process (clk)
   begin
      if rising_edge(clk) then
         ch3_req    <= '0';
         dl_done    <= '0';
         sram_ready <= '0';

         if dl_req = '1' then
            dl_pend <= '1';
            dl_a    <= dl_addr;
            dl_d    <= dl_data;
         end if;

         if fill_start = '1' then
            fill_act  <= '1';
            fill_addr <= unsigned(fill_base);
            fill_left <= unsigned(fill_words);
            fill_val  <= fill_value;
            if unsigned(fill_words) = 0 then
               fill_act <= '0';
            end if;
         end if;

         if sram_req = '0' then
            sram_drop <= '0';
         end if;

         if busy = '0' then
            if dl_pend = '1' and dl_req = '0' then
               own      <= O_DL;
               ch3_addr <= dl_a;
               ch3_din  <= dl_d;
               ch3_rnw  <= '0';
               ch3_be   <= "1111";
               ch3_req  <= '1';
               dl_pend  <= '0';
               busy     <= '1';
            elsif fill_act = '1' and fill_start = '0' then
               own      <= O_FILL;
               ch3_addr <= std_logic_vector(fill_addr);
               ch3_din  <= fill_val;
               ch3_rnw  <= '0';
               ch3_be   <= "1111";
               ch3_req  <= '1';
               busy     <= '1';
            elsif sram_req = '1' and sram_drop = '0' then
               own      <= O_SRAM;
               ch3_addr <= std_logic_vector(to_unsigned(SRAM_BASE, 27) + resize(unsigned(sram_addr), 27));
               ch3_din  <= sram_wdata;
               ch3_rnw  <= sram_rnw;
               ch3_be   <= sram_be;
               ch3_req  <= '1';
               busy     <= '1';
            end if;
         elsif ch3_ready = '1' then
            busy <= '0';
            case own is
               when O_DL =>
                  dl_done <= '1';
               when O_FILL =>
                  fill_addr <= fill_addr + 4;
                  fill_left <= fill_left - 1;
                  if fill_left = 1 then
                     fill_act <= '0';
                  end if;
               when O_SRAM =>
                  sram_rdata <= ch3_dout;
                  sram_ready <= '1';
                  sram_drop  <= '1';
            end case;
         end if;
      end if;
   end process;

end architecture;
