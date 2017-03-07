-- 
--    Title:          PBCFM.vhd
--    Author:         René Richard
--    Description:
--        
--    Target Hardware:
--        FM Power Base
-- LICENSE
-- 
--    This file is part of FM Power Base.
--    FM Power Base is free software: you can redistribute it and/or modify
--    it under the terms of the GNU General Public License as published by
--    the Free Software Foundation, either version 3 of the License, or
--    (at your option) any later version.
--    FM Power Base is distributed in the hope that it will be useful,
--    but WITHOUT ANY WARRANTY; without even the implied warranty of
--    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
--    GNU General Public License for more details.
--    You should have received a copy of the GNU General Public License
--    along with FM Power Base.  If not, see <http://www.gnu.org/licenses/>.
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library altera; 
use altera.altera_primitives_components.all;

entity PBCFM is 

	generic(
			-- 0 = no init code, fm always enabled
			-- 1 = regular PBC init code, fm always enabled
			-- 2 = db PBC init code, fm can be disabled by holding up during boot
			mode_g	:	integer := 1;
			
			-- amount of time to wait to enable sound output
			senCount_g : integer := 256
	);

	port (
			--Z80 control signals (from md obviously)
			CLK_p		: in  std_logic;
			nRST_p	: in  std_logic;
			nWR_p		: in  std_logic;
			nRD_p		: in  std_logic;
			nIORQ_p  : in  std_logic;
			nCRTOE_p	: in  std_logic;
			nCART_p	: out std_logic;
			nRSTG_p  : out std_logic;
			nRSTS_p	: out	std_logic;
			
			--non z80 signals
			HSCLK_p	: in  std_logic;
			FMEN_p	: in  std_logic;
			
			--YM2413 control signals
			SEN_p		: out std_logic;
			nYMCS_p	: out std_logic;
			nYMIC_p	: out std_logic;
			
			--address and databus
			ADDR_p	: in  std_logic_vector(7 downto 0);
			DATA_p	: inout  std_logic_vector(7 downto 0)
	);
end entity; 

architecture PBCFM_a of PBCFM is
	--ym2413 signals
	signal 	nkbsel_s 	:	std_logic;
	signal 	nfmcs_s		:  std_logic;
	signal 	nbitcs_s		: 	std_logic;
	--detect bit for Z80 software
	signal 	bitq_s		:  std_logic;
	--internal ym2413 enable signal, disabled by db boot code if up is held on power up
	signal	enym_s		:  std_logic;
	--internal signal to detect when the boot code disables the ym2413
	signal 	disableym_s	:  std_logic;
	
	--internal databus signals
	signal 	datain_s		: 	std_logic_vector(7 downto 0);
	signal   dataout_s	:  std_logic_vector(7 downto 0);
	
	--signal which enables the stack code to be driven onto the databus
	signal 	doBoot_s		:  std_logic;
	--signal which resets the doBoot flipflop
	signal	rstStack_s	:  std_logic;
	signal   endStack_s	:	std_logic;

	-- Power Base Converter stack init code
	-- source http://www.smspower.org/forums/viewtopic.php?t=14084
	--21 01 E1 : LD HL, $E101 
	--25 -- -- : DEC H 
	--F9 -- -- : LD SP,HL 
	--C7 -- -- : RST $00 
	--01 01 -- : LD BC, $xx01 
	-- Array containing boot ROM of orignal PBC 
	type PBCROM_t is array (0 to 7) of std_logic_vector(7 downto 0);
	constant PCBBootROM : PBCROM_t :=
						(x"21",x"01",x"e1",x"25",x"f9",x"c7",x"01",x"01");
	
	-- Array containing ROM of db PBCFM init code
	--;*************************************************************
	--; Boot section
	--;*************************************************************
	--    ld    sp, $e001    ; setup stack pointer to point to DFFF after reset
	--    ld    b, $00       ; clear b as iteration counter = 256
	---:  in    a,(IOPortA)  ; read joypad
	--    bit   0,a          ; check if up is pressed
	--    jr    nz,+         ; if 1, reset and leave FM sound enabled
	--    djnz  -            ; must read 256 times as 0 to disable FM sound
	--    nop                ; nop, hardware will disable the FM chip if this opcode is read
	--+:  rst $00            ; reset, nWR signal will disable this small BIOS and enable the game to boot
	type dbROM_t is array (0 to 15) of std_logic_vector(7 downto 0);
	constant dbBootROM : dbROM_t :=
						(x"31",x"01",x"e0",x"06",x"00",x"db",x"dc",x"cb",
						 x"4f",x"20",x"03",x"10",x"f8",x"00",x"c7",x"00");

--	type dbROM_t is array (0 to 24) of std_logic_vector(7 downto 0);
--	constant dbBootROM : dbROM_t :=
--						(x"f3",x"3e",x"f5",x"d3",x"3f",x"06",x"00",x"e3",
--						 x"10",x"fd",x"31",x"01",x"e0",x"06",x"00",x"db",
--						 x"dc",x"cb",x"47",x"20",x"03",x"10",x"f8",x"00",
--						 x"c7");

--*************************************************************
--LOGIC BEGINS HERE
--*************************************************************
begin

	--output to databus
	--dataout_s driven by process in PBC Stack Init section
	DATA_p <= dataout_s when doBoot_s = '1' and nRD_p = '0' and nCRTOE_p = '0' else --PBC bios code
				"ZZZZZ" & "00" & bitq_s when (nbitcs_s = '0' and nRD_p = '0') else  --FM detect bit
				(others=>'Z');
	
	--read in databus
	datain_s <= DATA_p;
	
	--reset signal from reset generator into HRST of Genesis
	nRSTG_p <= nRST_p;
	nRSTS_p <= nRST_p;

	--*************** YM2413 SECTION ***************
	--YM2413 signals
	nYMIC_p <= nRST_p;
	nYMCS_p <= nfmcs_s when nRST_p = '1' else '1';

	--generate kbsel internally as it does not exist on MD
	nkbsel_s <= '0' when nIORQ_p = '0' and 
								ADDR_p(7 downto 6)="11"
								else '1';
	
	--FM chip at address F0 and F1
	nfmcs_s <= '0' when  ADDR_p(2 downto 1)="00" and 
								nkbsel_s = '0' and
								nWR_p = '0' and
								enym_s = '1'
								else '1';
	
	--FM detect bit at address F2
	--read bit cs generation
	nbitcs_s <= '0' when ADDR_p(2 downto 1)="01" and 
								nkbsel_s = '0' and 
								enym_s = '1'
								else '1';
	
	-- Instantiate DFF for detect bit
	fmcheckFF : DFF
	port map (
			d => datain_s(0), 
			clk => nbitcs_s or nWR_p, -- bnand for clarity
			clrn => nRST_p,
			prn => '1',
			q => bitq_s
			);
	
	-- internal ym2413 enable signal, on by default, off when boot code disables it
	-- by reading the NOP at address 0x0D of the db boot code
	-- this only matters for mode_g = 2
	disableym_s <= '1' when doBoot_s = '1' and 
									nCRTOE_p = '0' and 
									ADDR_p = x"0d" 
									else '0';

	-- sample the pause button (FMEN_p) during reset, hold afterwards									
	process( nRST_p, FMEN_p)
	begin
		if nRST_p = '0' then
			enym_s <= FMEN_p; -- on by default
		else
			enym_s <= enym_s;
		end if;
	end process;
	
	-- after senCount_g amount of nIORQ_p's, enable sound output, not deterministic
	-- but is the longest wait time possible with the least amount of macrocells used
	process( nRST_p, doBoot_s, nIORQ_p, enym_s)
		variable senCount_v	:	integer range 0 to senCount_g;
	begin
		if nRST_p = '0' then
			SEN_p <= '0';
			senCount_v := 0;
		elsif doBoot_s = '1' or enym_s = '0' then
			SEN_p <= '0';
		elsif (rising_edge(nIORQ_p)) then
			senCount_v := senCount_v + 1;
			if senCount_v = senCount_g then
				SEN_p <= '1';
			end if;
		end if;
	end process;
	
	--*************** PBC Stack Init Section ***************
	--Cart output enable, don't gate the CRTOE_p if mode_g = 0
	nCART_p <= nCRTOE_p when doBoot_s = '0' or mode_g = 0 else '1';	
		
	--DFF to determine when to drive stack code onto bus
	--enables the doBoot_s at reset, stops it at the first nWR during stack write mode 1
	--or after encountering RST opcode in mode 2
	process( nRST_p, rstStack_s, doBoot_s)
	begin
		if nRST_p = '0' then
			doBoot_s <= '1';
		elsif rstStack_s = '1' then
			doBoot_s <= '0';
		else
			doBoot_s <= doBoot_s;
		end if;
	end process;
	
	--reset the doBoot flipflop
	--original PBC resets on nWR_p during RST instruction
	process( nRST_p, nWR_p, nCRTOE_p, endStack_s )
	begin
		if nRST_p = '0' then
			rstStack_s <= '0';
		else
			case mode_g is
				when 0 =>
					rstStack_s <= not(nWR_p);
				when 1 =>
					rstStack_s <= not(nWR_p);
				when 2 =>
					rstStack_s <= endStack_s;
				when others =>
					rstStack_s <= '0';
			end case;
		end if;
	end process;
	
	--endStack_s only matters in mode_g = 2
	process( nRST_p, nCRTOE_p, ADDR_p)
	begin
		if nRST_p = '0' then
			endStack_s <= '0';
		elsif (rising_edge(nCRTOE_p)) then
			if ADDR_p = x"0e" then --read the reset instruction in BIOS
				endStack_s <= '1';
			end if;
		end if;
	end process;
	
	--drive stack code (depends on mode_g)
	process( nRST_p, ADDR_p, nRD_p, nCRTOE_p, doBoot_s)
	begin
		if nRST_p = '0' then
			dataout_s <= (others=>'Z');
		elsif doBoot_s = '1' then
			if nRD_p = '0' and nCRTOE_p = '0' then
				case mode_g is
					when 0 =>
						dataout_s <= (others=>'Z');
					when 1 =>
						dataout_s <= PCBBootROM(to_integer(unsigned(ADDR_p(2 downto 0))));
					when 2 =>
						dataout_s <= dbBootROM(to_integer(unsigned(ADDR_p(3 downto 0))));
					when others =>
						dataout_s <= (others=>'Z');
				end case;
			else
				dataout_s <= (others=>'Z');
			end if;
		else
			dataout_s <= (others=>'Z');
		end if;
	end process;
		
end PBCFM_a;