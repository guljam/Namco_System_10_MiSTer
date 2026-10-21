-- ============================================================================
-- tb_exio_serial -- s10_exio's NFL Classic Football control-panel board (SC0) as the game drives it
-- Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later
-- ----------------------------------------------------------------------------
-- Sequence from the game's driver (main CPU 0x800A19F0, 0x800A1B80, 0x800A1D20): start the MCU, UART set-up
-- (0x374E-0x3750, 0x3751 = 0x17, wait for 0x3751 = 0), then packets {B1, ..., sum} (10 bytes at 0x375E, length
-- 0x375B, 0x3752 = 0x17) and the reply read from the ring at 0x379E up to the write index 0x3758; one
-- handshake {A0, 0 x 8, A0} that must come back unchanged. EXIO_IN1 is checked too.
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_exio_serial is
end entity;

architecture sim of tb_exio_serial is
   component s10_exio is
      port (
         clk : in std_logic; reset : in std_logic; enable : in std_logic;
         addr : in std_logic_vector(23 downto 0); wdata : in std_logic_vector(31 downto 0);
         wmask : in std_logic_vector(3 downto 0); size : in std_logic_vector(1 downto 0);
         rd : in std_logic; wr : in std_logic; rdata : out std_logic_vector(31 downto 0);
         drum : in std_logic_vector(7 downto 0); analog_en : in std_logic; analog : in std_logic_vector(79 downto 0);
         serial_en : in std_logic; tb : in std_logic_vector(63 downto 0); exio_in1 : in std_logic_vector(15 downto 0)
      );
   end component;

   signal clk   : std_logic := '0';
   signal reset : std_logic := '1';
   signal addr  : std_logic_vector(23 downto 0) := (others => '0');
   signal wdata : std_logic_vector(31 downto 0) := (others => '0');
   signal wmask : std_logic_vector(3 downto 0) := "0000";
   signal rd, wr : std_logic := '0';
   signal rdata : std_logic_vector(31 downto 0);
   signal tb    : std_logic_vector(63 downto 0) := x"8877665544332211";
begin
   clk <= not clk after 14.76 ns;

   dut : s10_exio port map (
      clk => clk, reset => reset, enable => '1', addr => addr, wdata => wdata, wmask => wmask, size => "01",
      rd => rd, wr => wr, rdata => rdata, drum => x"00", analog_en => '0', analog => (others => '0'),
      serial_en => '1', tb => tb, exio_in1 => x"FFAE");

   process
      variable L : line;
      variable errors : natural := 0;
      variable rptr : natural := 0;
      variable v : natural;
      type bytes is array (0 to 9) of natural;
      variable pkt, got : bytes;
      variable sum : natural;

      -- shared byte k (MCU 0x3000 + k) is the main CPU 16-bit location E00000 + 2 (k + 0x3000)
      function ka(k : natural) return natural is begin return 16#E00000# + 2 * (k + 16#3000#); end function;

      procedure w16(a : natural; d : natural) is
      begin
         wait until rising_edge(clk);
         addr <= std_logic_vector(to_unsigned(a, 24)); wr <= '1';
         if (a / 2) mod 2 = 1 then wmask <= "1100"; wdata <= std_logic_vector(to_unsigned(d, 16)) & x"0000";
         else wmask <= "0011"; wdata <= x"0000" & std_logic_vector(to_unsigned(d, 16)); end if;
         wait until rising_edge(clk); wr <= '0';
      end procedure;

      procedure r16(a : natural; d : out natural) is
      begin
         wait until rising_edge(clk);
         addr <= std_logic_vector(to_unsigned(a, 24)); rd <= '1';
         wait until rising_edge(clk); rd <= '0';
         wait until rising_edge(clk);
         if (a / 2) mod 2 = 1 then d := to_integer(unsigned(rdata(31 downto 16)));
         else d := to_integer(unsigned(rdata(15 downto 0))); end if;
      end procedure;

      procedure send_and_check(p : bytes; echo : boolean) is
         variable idx, b : natural;
      begin
         for i in 0 to 9 loop w16(ka(16#375E# + i), p(i)); end loop;
         w16(ka(16#375B#), 10);
         w16(ka(16#3752#), 16#17#);
         wait for 4 ms;
         r16(ka(16#3752#), b);
         if b /= 0 then errors := errors + 1; report "send request not cleared" severity error; end if;
         r16(ka(16#3758#), idx);
         if (idx - rptr + 64) mod 64 /= 10 then
            errors := errors + 1; report "reply length " & integer'image((idx - rptr + 64) mod 64) severity error;
         end if;
         for i in 0 to 9 loop
            r16(ka(16#379E# + (rptr + i) mod 64), got(i));
         end loop;
         rptr := idx;
         write(L, string'("reply"));
         for i in 0 to 9 loop write(L, string'(" ") & to_hstring(to_unsigned(got(i), 8))); end loop;
         writeline(output, L);
         if echo then
            for i in 0 to 9 loop if got(i) /= p(i) then errors := errors + 1; end if; end loop;
         else
            sum := 0;
            for i in 0 to 8 loop sum := sum + got(i); end loop;
            if got(0) /= 16#B1# or got(9) /= sum mod 256 then errors := errors + 1; report "header / sum" severity error; end if;
            for i in 1 to 8 loop
               if got(i) /= to_integer(unsigned(tb(8 * i - 1 downto 8 * i - 8))) then
                  errors := errors + 1; report "counter byte " & integer'image(i) severity error;
               end if;
            end loop;
         end if;
      end procedure;
   begin
      wait for 100 ns; reset <= '0';
      w16(16#E10000#, 1);                                  -- start the MCU
      wait for 2 ms;
      -- UART set-up
      w16(ka(16#374E#), 8); w16(ka(16#374F#), 9); w16(ka(16#3750#), 0);
      w16(ka(16#3751#), 16#17#);
      wait for 1 ms;
      r16(ka(16#3751#), v);
      if v /= 0 then errors := errors + 1; report "set-up request not cleared" severity error; end if;
      -- handshake
      pkt := (16#A0#, 0, 0, 0, 0, 0, 0, 0, 0, 16#A0#);
      send_and_check(pkt, true);
      -- seven play packets, the counters changing between them; enough to wrap the 64-byte ring
      for n in 0 to 6 loop
         pkt := (16#B1#, 16#3F#, 16#06#, n, 0, 0, 0, 0, 0, 0);
         sum := 0; for i in 0 to 8 loop sum := sum + pkt(i); end loop; pkt(9) := sum mod 256;
         tb <= std_logic_vector(unsigned(tb) + x"0303030303030303");
         send_and_check(pkt, false);
      end loop;
      r16(16#E50000#, v);
      if v /= 16#FFAE# then errors := errors + 1; report "EXIO_IN1" severity error; end if;
      if errors = 0 then write(L, string'("PASS")); else write(L, string'("FAIL ") & integer'image(errors)); end if;
      writeline(output, L);
      std.env.finish;
   end process;
end architecture;
