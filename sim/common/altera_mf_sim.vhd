-- ============================================================================
-- Minimal behavioural altsyncram for NVC simulation (subset used by this core)
-- Supports operation_mode SINGLE_PORT, DUAL_PORT, BIDIR_DUAL_PORT, single clock
-- (clock0; clock1 is honoured for port B when given), byte enables, registered or
-- unregistered outputs (outdata_reg_x "CLOCK0"/"CLOCK1" adds one stage),
-- read-during-write returns the new data. init_file: hex .mif with a single
-- "[a..b] : v;" range or "addr : value;" lines is parsed, anything else ignored.
-- Mixed widths are not supported (width_a must equal width_b).
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package altera_mf_components is
   component altsyncram
      generic (
         address_aclr_a, address_aclr_b, address_reg_b, byteena_aclr_a, byteena_aclr_b,
         byteena_reg_b, clock_enable_core_a, clock_enable_core_b, clock_enable_input_a,
         clock_enable_input_b, clock_enable_output_a, clock_enable_output_b,
         intended_device_family, ecc_pipeline_stage_enabled, enable_ecc, implement_in_les,
         indata_aclr_a, indata_aclr_b, indata_reg_b, init_file, init_file_layout,
         lpm_hint, lpm_type, maximum_depth_unused, operation_mode, outdata_aclr_a, outdata_aclr_b,
         outdata_reg_a, outdata_reg_b, power_up_uninitialized, ram_block_type,
         rdcontrol_aclr_b, rdcontrol_reg_b, read_during_write_mode_mixed_ports,
         read_during_write_mode_port_a, read_during_write_mode_port_b, wrcontrol_aclr_a,
         wrcontrol_aclr_b, wrcontrol_wraddress_reg_b : string := "UNUSED";
         byte_size        : natural := 8;
         numwords_a       : natural := 0;
         numwords_b       : natural := 0;
         width_a          : natural := 8;
         width_b          : natural := 1;
         width_byteena_a  : natural := 1;
         width_byteena_b  : natural := 1;
         widthad_a        : natural := 1;
         widthad_b        : natural := 1;
         width_eccstatus  : natural := 3;
         maximum_depth    : natural := 0
      );
      port (
         aclr0, aclr1 : in std_logic := '0';
         address_a    : in std_logic_vector(widthad_a-1 downto 0);
         address_b    : in std_logic_vector(widthad_b-1 downto 0) := (others => '1');
         addressstall_a, addressstall_b : in std_logic := '0';
         byteena_a    : in std_logic_vector(width_byteena_a-1 downto 0) := (others => '1');
         byteena_b    : in std_logic_vector(width_byteena_b-1 downto 0) := (others => '1');
         clock0       : in std_logic := '1';
         clock1       : in std_logic := '1';
         clocken0, clocken1, clocken2, clocken3 : in std_logic := '1';
         data_a       : in std_logic_vector(width_a-1 downto 0) := (others => '1');
         data_b       : in std_logic_vector(width_b-1 downto 0) := (others => '1');
         eccstatus    : out std_logic_vector(width_eccstatus-1 downto 0);
         q_a          : out std_logic_vector(width_a-1 downto 0);
         q_b          : out std_logic_vector(width_b-1 downto 0);
         rden_a, rden_b : in std_logic := '1';
         wren_a, wren_b : in std_logic := '0'
      );
   end component;
end package;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity altsyncram is
   generic (
      address_aclr_a, address_aclr_b, address_reg_b, byteena_aclr_a, byteena_aclr_b,
      byteena_reg_b, clock_enable_core_a, clock_enable_core_b, clock_enable_input_a,
      clock_enable_input_b, clock_enable_output_a, clock_enable_output_b,
      intended_device_family, ecc_pipeline_stage_enabled, enable_ecc, implement_in_les,
      indata_aclr_a, indata_aclr_b, indata_reg_b, init_file, init_file_layout,
      lpm_hint, lpm_type, maximum_depth_unused, operation_mode, outdata_aclr_a, outdata_aclr_b,
      outdata_reg_a, outdata_reg_b, power_up_uninitialized, ram_block_type,
      rdcontrol_aclr_b, rdcontrol_reg_b, read_during_write_mode_mixed_ports,
      read_during_write_mode_port_a, read_during_write_mode_port_b, wrcontrol_aclr_a,
      wrcontrol_aclr_b, wrcontrol_wraddress_reg_b : string := "UNUSED";
      byte_size        : natural := 8;
      numwords_a       : natural := 0;
      numwords_b       : natural := 0;
      width_a          : natural := 8;
      width_b          : natural := 1;
      width_byteena_a  : natural := 1;
      width_byteena_b  : natural := 1;
      widthad_a        : natural := 1;
      widthad_b        : natural := 1;
      width_eccstatus  : natural := 3;
      maximum_depth    : natural := 0
   );
   port (
      aclr0, aclr1 : in std_logic := '0';
      address_a    : in std_logic_vector(widthad_a-1 downto 0);
      address_b    : in std_logic_vector(widthad_b-1 downto 0) := (others => '1');
      addressstall_a, addressstall_b : in std_logic := '0';
      byteena_a    : in std_logic_vector(width_byteena_a-1 downto 0) := (others => '1');
      byteena_b    : in std_logic_vector(width_byteena_b-1 downto 0) := (others => '1');
      clock0       : in std_logic := '1';
      clock1       : in std_logic := '1';
      clocken0, clocken1, clocken2, clocken3 : in std_logic := '1';
      data_a       : in std_logic_vector(width_a-1 downto 0) := (others => '1');
      data_b       : in std_logic_vector(width_b-1 downto 0) := (others => '1');
      eccstatus    : out std_logic_vector(width_eccstatus-1 downto 0);
      q_a          : out std_logic_vector(width_a-1 downto 0);
      q_b          : out std_logic_vector(width_b-1 downto 0);
      rden_a, rden_b : in std_logic := '1';
      wren_a, wren_b : in std_logic := '0'
   );
end entity;

architecture sim of altsyncram is
   constant DEPTH : natural := 2**widthad_a;
   type mem_t is array(0 to DEPTH-1) of std_logic_vector(width_a-1 downto 0);

   impure function load return mem_t is
      variable m    : mem_t := (others => (others => '0'));
      file     f    : text;
      variable st   : file_open_status;
      variable l    : line;
      variable c    : character;
      variable txt  : string(1 to 200);
      variable n    : integer;
      variable lo, hi, v : integer;
      function hexval(s : string; a, b : integer) return integer is
         variable r : integer := 0;
         variable d : integer;
      begin
         for i in a to b loop
            case s(i) is
               when '0' to '9' => d := character'pos(s(i)) - 48;
               when 'A' to 'F' => d := character'pos(s(i)) - 55;
               when 'a' to 'f' => d := character'pos(s(i)) - 87;
               when others => d := -1;
            end case;
            if d >= 0 then r := r * 16 + d; end if;
         end loop;
         return r;
      end function;
   begin
      if init_file = "UNUSED" or init_file'length = 0 then
         return m;
      end if;
      file_open(st, f, init_file, read_mode);
      if st /= open_ok then
         return m;
      end if;
      while not endfile(f) loop
         readline(f, l);
         n := 0;
         while l'length > 0 and n < 200 loop
            read(l, c);
            n := n + 1;
            txt(n) := c;
         end loop;
         -- "[a..b] : v;"
         if n > 0 and txt(1) = ' ' then
            null;
         end if;
         for i in 1 to n loop
            if txt(i) = '[' then
               for j in i to n - 1 loop
                  if txt(j) = '.' and txt(j+1) = '.' then
                     lo := hexval(txt, i+1, j-1);
                     for k in j+2 to n loop
                        if txt(k) = ']' then
                           hi := hexval(txt, j+2, k-1);
                           for q in k to n loop
                              if txt(q) = ':' then
                                 v := 0;
                                 for z in q+1 to n loop
                                    exit when txt(z) = ';';
                                 end loop;
                                 for a in lo to hi loop
                                    if a < DEPTH then
                                       m(a) := (others => '1');
                                    end if;
                                 end loop;
                                 exit;
                              end if;
                           end loop;
                           exit;
                        end if;
                     end loop;
                     exit;
                  end if;
               end loop;
               exit;
            end if;
         end loop;
      end loop;
      file_close(f);
      return m;
   end function;

   shared variable mem : mem_t := load;
   signal qa_r, qb_r : std_logic_vector(width_a-1 downto 0) := (others => '0');
   signal qa_r2, qb_r2 : std_logic_vector(width_a-1 downto 0) := (others => '0');
   constant BYTES_A : natural := width_byteena_a;
begin

   pa : process (clock0)
      variable w : std_logic_vector(width_a-1 downto 0);
      variable bw : natural;
   begin
      if rising_edge(clock0) then
         if clocken0 = '1' then
            if wren_a = '1' then
               w  := mem(to_integer(unsigned(address_a)));
               bw := width_a / BYTES_A;
               for i in 0 to BYTES_A-1 loop
                  if byteena_a(i) = '1' then
                     w(i*bw+bw-1 downto i*bw) := data_a(i*bw+bw-1 downto i*bw);
                  end if;
               end loop;
               mem(to_integer(unsigned(address_a))) := w;
            end if;
            qa_r <= mem(to_integer(unsigned(address_a)));
            qa_r2 <= qa_r;
         end if;
      end if;
   end process;

   pb : process (clock0, clock1)
      variable w  : std_logic_vector(width_a-1 downto 0);
      variable bw : natural;
      variable clk_ev : boolean;
   begin
      if address_reg_b = "CLOCK1" then
         clk_ev := rising_edge(clock1);
      else
         clk_ev := rising_edge(clock0);
      end if;
      if clk_ev and operation_mode /= "SINGLE_PORT" then
         if wren_b = '1' and operation_mode = "BIDIR_DUAL_PORT" then
            w  := mem(to_integer(unsigned(address_b)));
            bw := width_b / width_byteena_b;
            for i in 0 to width_byteena_b-1 loop
               if byteena_b(i) = '1' then
                  w(i*bw+bw-1 downto i*bw) := data_b(i*bw+bw-1 downto i*bw);
               end if;
            end loop;
            mem(to_integer(unsigned(address_b))) := w;
         end if;
         qb_r <= mem(to_integer(unsigned(address_b)));
         qb_r2 <= qb_r;
      end if;
   end process;

   q_a <= qa_r2 when outdata_reg_a = "CLOCK0" or outdata_reg_a = "CLOCK1" else qa_r;
   gqb : if width_b = width_a generate
      q_b <= qb_r2 when outdata_reg_b = "CLOCK0" or outdata_reg_b = "CLOCK1" else qb_r;
   end generate;
   gqb0 : if width_b /= width_a generate
      q_b <= (others => '0');
   end generate;
   eccstatus <= (others => '0');

end architecture;
