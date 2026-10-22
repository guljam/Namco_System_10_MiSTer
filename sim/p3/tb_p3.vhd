-- ============================================================================
-- tb_p3 -- MEM(P3) board stand-in: s10_p3 (MCU RAM window + command HLE) -> s10_p3audio (.p3a player)
-- Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later
-- ----------------------------------------------------------------------------
-- The MCU RAM (DDR3 model) starts as a MAME dump of the game's 8 MB SDRAM (local scratch, mcudump.lua). For
-- each stream-table entry in SELS the bench writes the game's commands through the board bus exactly as the
-- game does (bank 0x3F, command words at window offset 0, interrupt at 0x300006): 0056 0, 004C sel, 0050 0 0,
-- waits for the first audio frame from the .p3a (test tones: right channel = 1000 + track number), then 0053.
-- Prints "SEL <sel> LEN <len> C0 <crc> TRACK <n>" per entry, for run.sh to compare with the converter.
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_p3 is
   generic (
      MCU_IMG : string := "mcu.bin";
      P3A_IMG : string := "audio.p3a";
      SELS    : string := "10,18";           -- hex table offsets, comma separated
      DBG     : boolean := false;
      HOLD    : natural := 0;               -- frames the right channel must stay on the track value (ring wraps)
      -- replay mode (CAP_IMG set): the MCU RAM starts empty, every captured main-CPU access (local/mame/p3cap.lua) is
      -- presented on the board bus as the PSX memory mux does, GAP clocks apart; play requests are logged and the RAM
      -- is compared with MAME's at the end (REF_IMG)
      CAP_IMG : string := "";
      REF_IMG : string := "";
      GAP     : natural := 6;
      DLAT    : natural := 4                -- DDR3 ack latency (clk2): large values stand for waits behind the GPU
   );
end entity;

architecture sim of tb_p3 is

   component s10_p3 is
      port (
         clk : in std_logic; clk2 : in std_logic; reset : in std_logic; enable : in std_logic;
         mcu_base : in std_logic_vector(27 downto 0);
         addr : in std_logic_vector(23 downto 0); wdata : in std_logic_vector(31 downto 0);
         wmask : in std_logic_vector(3 downto 0); size : in std_logic_vector(1 downto 0);
         rd : in std_logic; wr : in std_logic; rdata : out std_logic_vector(31 downto 0); stall : out std_logic;
         wstall : out std_logic;
         aim_x : in std_logic_vector(9 downto 0); aim_y : in std_logic_vector(9 downto 0);
         play_req : out std_logic; play_len : out std_logic_vector(23 downto 0);
         play_c0 : out std_logic_vector(31 downto 0); play_c1 : out std_logic_vector(31 downto 0);
         play_c2 : out std_logic_vector(31 downto 0); stop_req : out std_logic;
         volume : out std_logic_vector(6 downto 0);
         ddr_request : out std_logic; ddr_ack : in std_logic; ddr_burstcnt : out std_logic_vector(7 downto 0);
         ddr_addr : out std_logic_vector(27 downto 0); ddr_din : out std_logic_vector(63 downto 0);
         ddr_be : out std_logic_vector(7 downto 0); ddr_we : out std_logic; ddr_rd : out std_logic;
         ddr_dout : in std_logic_vector(63 downto 0); ddr_dout_ready : in std_logic
      );
   end component;

   component s10_p3audio is
      port (
         clk : in std_logic; reset : in std_logic; enable : in std_logic;
         play_req : in std_logic; play_len : in std_logic_vector(23 downto 0);
         play_c0 : in std_logic_vector(31 downto 0); play_c1 : in std_logic_vector(31 downto 0);
         play_c2 : in std_logic_vector(31 downto 0); stop_req : in std_logic;
         volume : in std_logic_vector(6 downto 0);
         audio_l : out std_logic_vector(15 downto 0); audio_r : out std_logic_vector(15 downto 0);
         sd_lba : out std_logic_vector(31 downto 0); sd_blk_cnt : out std_logic_vector(5 downto 0);
         sd_rd : out std_logic; sd_ack : in std_logic; sd_buff_addr : in std_logic_vector(12 downto 0);
         sd_buff_dout : in std_logic_vector(15 downto 0); sd_buff_wr : in std_logic;
         img_mounted : in std_logic; img_size : in std_logic_vector(63 downto 0)
      );
   end component;

   component s10_ddr_mux is
      port (
         clk2 : in std_logic; reset : in std_logic;
         a_request : in std_logic; a_ack : out std_logic; a_burstcnt : in std_logic_vector(7 downto 0);
         a_addr : in std_logic_vector(27 downto 0); a_din : in std_logic_vector(63 downto 0);
         a_be : in std_logic_vector(7 downto 0); a_we : in std_logic; a_rd : in std_logic; a_dout_ready : out std_logic;
         b_request : in std_logic; b_ack : out std_logic; b_burstcnt : in std_logic_vector(7 downto 0);
         b_addr : in std_logic_vector(27 downto 0); b_din : in std_logic_vector(63 downto 0);
         b_be : in std_logic_vector(7 downto 0); b_we : in std_logic; b_rd : in std_logic; b_dout_ready : out std_logic;
         ddr_request : out std_logic; ddr_ack : in std_logic; ddr_burstcnt : out std_logic_vector(7 downto 0);
         ddr_addr : out std_logic_vector(27 downto 0); ddr_din : out std_logic_vector(63 downto 0);
         ddr_be : out std_logic_vector(7 downto 0); ddr_we : out std_logic; ddr_rd : out std_logic;
         ddr_dout_ready : in std_logic
      );
   end component;

   constant MCU_BASE : std_logic_vector(27 downto 0) := x"F000000";

   signal clk, clk2 : std_logic := '0';
   signal reset     : std_logic := '1';
   signal addr      : std_logic_vector(23 downto 0) := (others => '0');
   signal wdata     : std_logic_vector(31 downto 0) := (others => '0');
   signal wmask     : std_logic_vector(3 downto 0) := "0000";
   signal rd, wr    : std_logic := '0';
   signal rdata     : std_logic_vector(31 downto 0);
   signal stall     : std_logic;
   signal wstall    : std_logic;

   signal play_req, stop_req : std_logic;
   signal play_len  : std_logic_vector(23 downto 0);
   signal play_c0, play_c1, play_c2 : std_logic_vector(31 downto 0);
   signal volume    : std_logic_vector(6 downto 0);
   signal audio_l, audio_r : std_logic_vector(15 downto 0);

   signal b_request, b_ack, b_we, b_rd, b_dout_ready : std_logic;
   signal b_burstcnt, b_be : std_logic_vector(7 downto 0);
   signal b_addr : std_logic_vector(27 downto 0);
   signal b_din  : std_logic_vector(63 downto 0);
   signal d_request, d_ack, d_we, d_rd, d_dout_ready : std_logic := '0';
   signal d_burstcnt, d_be : std_logic_vector(7 downto 0);
   signal d_addr : std_logic_vector(27 downto 0);
   signal d_din, d_dout : std_logic_vector(63 downto 0) := (others => '0');

   signal sd_lba : std_logic_vector(31 downto 0);
   signal sd_blk_cnt : std_logic_vector(5 downto 0);
   signal sd_rd, sd_ack, sd_buff_wr : std_logic := '0';
   signal sd_buff_addr : std_logic_vector(12 downto 0) := (others => '0');
   signal sd_buff_dout : std_logic_vector(15 downto 0) := (others => '0');
   signal img_mounted : std_logic := '0';
   signal img_size : std_logic_vector(63 downto 0) := (others => '0');

   -- 8 MB of MCU RAM as 64-bit beats
   type mem_t is array (0 to 1048575) of std_logic_vector(63 downto 0);
   shared variable mem : mem_t;
   -- the .p3a file
   type bytes_t is array (natural range <>) of character;
   type bytes_p is access bytes_t;
   shared variable p3a : bytes_p;
   shared variable p3a_len : natural := 0;

   type charfile is file of character;

   function hexval(s : string) return natural is
      variable v : natural := 0;
   begin
      for i in s'range loop
         case s(i) is
            when '0' to '9' => v := v * 16 + character'pos(s(i)) - character'pos('0');
            when 'a' to 'f' => v := v * 16 + character'pos(s(i)) - character'pos('a') + 10;
            when 'A' to 'F' => v := v * 16 + character'pos(s(i)) - character'pos('A') + 10;
            when others => null;
         end case;
      end loop;
      return v;
   end function;

begin
   clk2 <= not clk2 after 7.38 ns;
   process (clk2) begin if rising_edge(clk2) then clk <= not clk; end if; end process;

   ip3 : s10_p3 port map (
      clk => clk, clk2 => clk2, reset => reset, enable => '1', mcu_base => MCU_BASE,
      addr => addr, wdata => wdata, wmask => wmask, size => "01", rd => rd, wr => wr, rdata => rdata, stall => stall, wstall => wstall,
      aim_x => (others => '0'), aim_y => (others => '0'),
      play_req => play_req, play_len => play_len, play_c0 => play_c0, play_c1 => play_c1, play_c2 => play_c2,
      stop_req => stop_req, volume => volume,
      ddr_request => b_request, ddr_ack => b_ack, ddr_burstcnt => b_burstcnt, ddr_addr => b_addr, ddr_din => b_din,
      ddr_be => b_be, ddr_we => b_we, ddr_rd => b_rd, ddr_dout => d_dout, ddr_dout_ready => b_dout_ready);

   imux : s10_ddr_mux port map (
      clk2 => clk2, reset => reset,
      a_request => '0', a_ack => open, a_burstcnt => x"01", a_addr => (others => '0'), a_din => (others => '0'),
      a_be => x"FF", a_we => '0', a_rd => '0', a_dout_ready => open,
      b_request => b_request, b_ack => b_ack, b_burstcnt => b_burstcnt, b_addr => b_addr, b_din => b_din,
      b_be => b_be, b_we => b_we, b_rd => b_rd, b_dout_ready => b_dout_ready,
      ddr_request => d_request, ddr_ack => d_ack, ddr_burstcnt => d_burstcnt, ddr_addr => d_addr, ddr_din => d_din,
      ddr_be => d_be, ddr_we => d_we, ddr_rd => d_rd, ddr_dout_ready => d_dout_ready);

   iaud : s10_p3audio port map (
      clk => clk, reset => reset, enable => '1',
      play_req => play_req, play_len => play_len, play_c0 => play_c0, play_c1 => play_c1, play_c2 => play_c2,
      stop_req => stop_req, volume => volume, audio_l => audio_l, audio_r => audio_r,
      sd_lba => sd_lba, sd_blk_cnt => sd_blk_cnt, sd_rd => sd_rd, sd_ack => sd_ack, sd_buff_addr => sd_buff_addr,
      sd_buff_dout => sd_buff_dout, sd_buff_wr => sd_buff_wr, img_mounted => img_mounted, img_size => img_size);

   -- DDR3 model (psx arbiter protocol as s10_mem sees it): ack after a few clocks, then the read beats
   ddr : process
      variable a, n : natural;
      variable c : character;
      file f : charfile;
      variable w : std_logic_vector(63 downto 0);
   begin
      if CAP_IMG = "" then
         file_open(f, MCU_IMG, read_mode);
         for i in 0 to 1048575 loop
            for b in 0 to 7 loop
               read(f, c); w(8 * b + 7 downto 8 * b) := std_logic_vector(to_unsigned(character'pos(c), 8));
            end loop;
            mem(i) := w;
         end loop;
         file_close(f);
      else
         for i in 0 to 1048575 loop mem(i) := (others => '0'); end loop;
      end if;
      loop
         wait until rising_edge(clk2);
         if d_request = '1' then
            a := to_integer(unsigned(d_addr) - unsigned(MCU_BASE)) / 8;
            n := to_integer(unsigned(d_burstcnt));
            for i in 1 to DLAT loop wait until rising_edge(clk2); end loop;
            d_ack <= '1'; wait until rising_edge(clk2); d_ack <= '0';
            if d_we = '1' then
               for b in 0 to 7 loop
                  if d_be(b) = '1' then mem(a)(8 * b + 7 downto 8 * b) := d_din(8 * b + 7 downto 8 * b); end if;
               end loop;
            else
               for i in 1 to 6 loop wait until rising_edge(clk2); end loop;
               for i in 0 to n - 1 loop
                  d_dout <= mem(a + i); d_dout_ready <= '1'; wait until rising_edge(clk2);
               end loop;
               d_dout_ready <= '0';
            end if;
            while d_request = '1' loop wait until rising_edge(clk2); end loop;
         end if;
      end loop;
   end process;

   -- SD slot 0 (hps_io, 1 KB blocks, 16-bit words)
   sd : process
      file f : charfile;
      variable c, c2 : character;
      variable lba, cnt, base : natural;
   begin
      p3a := new bytes_t(0 to 64 * 1024 * 1024 - 1);
      file_open(f, P3A_IMG, read_mode);
      while not endfile(f) loop read(f, c); p3a(p3a_len) := c; p3a_len := p3a_len + 1; end loop;
      file_close(f);
      img_size <= std_logic_vector(to_unsigned(p3a_len, 64));
      wait until reset = '0';
      wait until rising_edge(clk);
      img_mounted <= '1'; wait until rising_edge(clk); img_mounted <= '0';
      loop
         wait until rising_edge(clk);
         if sd_rd = '1' then
            lba := to_integer(unsigned(sd_lba)); cnt := to_integer(unsigned(sd_blk_cnt)) + 1;
            if DBG then report "SD lba " & integer'image(lba) & " cnt " & integer'image(cnt); end if;
            for i in 1 to 200 loop wait until rising_edge(clk); end loop;
            sd_ack <= '1';
            for i in 0 to cnt * 512 - 1 loop
               base := lba * 1024 + 2 * i;
               if base + 1 < p3a_len then c := p3a(base); c2 := p3a(base + 1); else c := nul; c2 := nul; end if;
               sd_buff_addr <= std_logic_vector(to_unsigned(i, 13));
               sd_buff_dout <= std_logic_vector(to_unsigned(character'pos(c2), 8)) &
                               std_logic_vector(to_unsigned(character'pos(c), 8));
               sd_buff_wr <= '1'; wait until rising_edge(clk); sd_buff_wr <= '0'; wait until rising_edge(clk);
            end loop;
            sd_ack <= '0';
         end if;
      end loop;
   end process;

   -- play requests as they happen, and the track the player finds (test tones: right channel = 1000 + track)
   plays : process
      variable L : line;
   begin
      wait until rising_edge(clk) and play_req = '1';
      write(L, string'("PLAY len ") & integer'image(to_integer(unsigned(play_len))) & string'(" C0 ") & to_hstring(play_c0) &
               string'(" C1 ") & to_hstring(play_c1) & string'(" C2 ") & to_hstring(play_c2) & string'(" vol ") &
               integer'image(to_integer(unsigned(volume))));
      writeline(output, L);
      for t in 0 to 400000 loop
         wait until rising_edge(clk);
         if audio_r /= x"0000" then
            write(L, string'("  -> audio_r ") & integer'image(to_integer(signed(audio_r))));
            writeline(output, L);
            exit;
         end if;
         exit when play_req = '1';
      end loop;
   end process;

   -- the game
   cpu : process
      variable L : line;
      variable plays : natural := 0;
      variable s : natural;
      variable i0 : integer;
      variable got : boolean;
      variable track : integer;
      variable sels_v : string(1 to SELS'length) := SELS;

      procedure w16(a : natural; v : natural) is
         variable ad : std_logic_vector(23 downto 0);
      begin
         ad := std_logic_vector(to_unsigned(a, 24));
         wait until rising_edge(clk);
         addr <= ad(23 downto 2) & "00"; wr <= '1';             -- word-aligned + lanes, as the memory mux
         if ad(1) = '1' then wmask <= "1100"; wdata <= std_logic_vector(to_unsigned(v, 16)) & x"0000";
         else wmask <= "0011"; wdata <= x"0000" & std_logic_vector(to_unsigned(v, 16)); end if;
         wait until rising_edge(clk); wr <= '0';
         for i in 1 to 3 loop wait until rising_edge(clk); end loop;
      end procedure;

      procedure command(c, a1, a2 : natural) is
         variable busy : boolean;
      begin
         w16(16#30000C#, 16#3F#);
         w16(16#320000#, c); w16(16#320002#, a1); w16(16#320004#, a2);
         w16(16#300006#, 0);
         -- poll !busy like the game
         loop
            wait until rising_edge(clk); addr <= x"300006"; rd <= '1';
            wait until rising_edge(clk); rd <= '0';
            wait until rising_edge(clk);
            exit when rdata(16) = '1';
            for i in 1 to 20 loop wait until rising_edge(clk); end loop;
         end loop;
      end procedure;
      procedure replay is
         file f, g : charfile;
         variable c : character;
         variable rb : std_logic_vector(103 downto 0);
         variable o, mk : std_logic_vector(31 downto 0);
         variable t, nrec, nbad : natural := 0;
         variable w : std_logic_vector(63 downto 0);
         variable badblk : natural;
      begin
         file_open(f, CAP_IMG, read_mode);
         while not endfile(f) loop
            for b in 0 to 12 loop
               read(f, c); rb(8 * b + 7 downto 8 * b) := std_logic_vector(to_unsigned(character'pos(c), 8));
            end loop;
            o := rb(39 downto 8); mk := rb(103 downto 72);
            wait until rising_edge(clk);
            if rb(7 downto 0) = x"00" then
               addr <= o(23 downto 2) & "00"; wdata <= rb(71 downto 40);
               for b in 0 to 3 loop wmask(b) <= mk(8 * b); end loop;
               wr <= '1';
               wait until rising_edge(clk); wr <= '0';
               wait until rising_edge(clk);
               while wstall = '1' loop wait until rising_edge(clk); end loop;   -- the memory mux holds the CPU
            else
               if mk = x"FFFF0000" then addr <= o(23 downto 2) & "10"; else addr <= o(23 downto 2) & "00"; end if;
               rd <= '1';
               wait until rising_edge(clk); rd <= '0';
               wait until rising_edge(clk);
               while stall = '1' loop wait until rising_edge(clk); end loop;
               -- the game polls !busy (0x300006) until it reads 1 before its next command: do the same
               if o(23 downto 0) = x"300004" and mk = x"FFFF0000" then
                  while rdata(16) = '0' loop
                     for i in 1 to 20 loop wait until rising_edge(clk); end loop;
                     addr <= x"300006"; rd <= '1';
                     wait until rising_edge(clk); rd <= '0';
                     wait until rising_edge(clk);
                  end loop;
               end if;
            end if;
            for i in 1 to GAP loop wait until rising_edge(clk); end loop;
            nrec := nrec + 1;
            if nrec mod 200000 = 0 then
               write(L, string'("records ") & integer'image(nrec)); writeline(output, L);
            end if;
         end loop;
         file_close(f);
         for i in 1 to 200000 loop wait until rising_edge(clk); end loop;
         -- compare the MCU RAM with MAME's (per 64 KB block: blocks with differences)
         file_open(g, REF_IMG, read_mode);
         badblk := 0;
         for blk in 0 to 127 loop
            nbad := 0;
            for i in 0 to 8191 loop
               for b in 0 to 7 loop
                  read(g, c); w(8 * b + 7 downto 8 * b) := std_logic_vector(to_unsigned(character'pos(c), 8));
               end loop;
               if w /= mem(blk * 8192 + i) then nbad := nbad + 1; end if;
            end loop;
            if nbad /= 0 then
               badblk := badblk + 1;
               write(L, string'("RAM 0x") & to_hstring(to_unsigned(16#800000# + blk * 65536, 24)) &
                        string'(" beats differing: ") & integer'image(nbad));
               writeline(output, L);
            end if;
         end loop;
         file_close(g);
         write(L, string'("records ") & integer'image(nrec) & string'(", RAM blocks differing ") & integer'image(badblk));
         writeline(output, L);
      end procedure;
   begin
      for i in 1 to 20 loop wait until rising_edge(clk); end loop;
      reset <= '0';
      for i in 1 to 2000 loop wait until rising_edge(clk); end loop;
      if CAP_IMG /= "" then
         replay;
         write(L, string'("DONE")); writeline(output, L);
         std.env.finish;
      end if;
      command(16#56#, 0, 0);
      i0 := 1;
      while i0 <= sels_v'length loop
         s := 0;
         while i0 <= sels_v'length and sels_v(i0) /= ',' loop
            s := s * 16 + hexval(sels_v(i0 to i0)); i0 := i0 + 1;
         end loop;
         i0 := i0 + 1;
         command(16#4C#, s, 0);
         command(16#50#, 0, 0);
         got := false; track := -1;
         for t in 0 to 400000 loop
            wait until rising_edge(clk);
            if audio_r /= x"0000" then got := true; track := to_integer(signed(audio_r)); exit; end if;
         end loop;
         write(L, string'("SEL ") & to_hstring(to_unsigned(s, 16)) & " LEN " & integer'image(to_integer(unsigned(play_len))) &
               " C0 " & to_hstring(play_c0) & " C1 " & to_hstring(play_c1) & " C2 " & to_hstring(play_c2) &
               " TRACK " & integer'image(track - 999));
         writeline(output, L);
         if HOLD > 0 and got then
            for t in 1 to HOLD * 768 loop
               wait until rising_edge(clk);
               assert to_integer(signed(audio_r)) = track report "audio broke at clock " & integer'image(t) severity failure;
            end loop;
            write(L, string'("HOLD ok")); writeline(output, L);
         end if;
         command(16#53#, 0, 0);
         for i in 1 to 2000 loop wait until rising_edge(clk); end loop;
         assert audio_r = x"0000" report "audio did not stop" severity error;
      end loop;
      write(L, string'("DONE")); writeline(output, L);
      std.env.finish;
   end process;

end architecture;
