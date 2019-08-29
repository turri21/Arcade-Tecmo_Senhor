-- Copyright (c) 2019 Josh Bassett
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.types.all;

-- The character layer is the part of the graphics pipeline that handles things
-- like the logo, score, playfield, and other static graphics.
--
-- It consists of a 32x32 grid of 8x8 tiles.
entity char is
  port (
    -- clock signals
    clk   : in std_logic;
    cen_6 : in std_logic;

    -- char RAM
    ram_cs   : in std_logic;
    ram_addr : in unsigned(CHAR_RAM_ADDR_WIDTH-1 downto 0);
    ram_din  : in byte_t;
    ram_dout : out byte_t;
    ram_we   : in std_logic;

    -- tile ROM
    rom_addr : out unsigned(CHAR_ROM_ADDR_WIDTH-1 downto 0);
    rom_data : in std_logic_vector(CHAR_ROM_DATA_WIDTH-1 downto 0);

    -- video signals
    video : in video_t;

    -- graphics data
    data : out byte_t
  );
end char;

architecture arch of char is
  -- represents the position of a pixel in a 8x8 tile
  type tile_pos_t is record
    x : unsigned(2 downto 0);
    y : unsigned(2 downto 0);
  end record tile_pos_t;

  -- char RAM (port B)
  signal char_ram_addr_b : unsigned(CHAR_RAM_ADDR_WIDTH-1 downto 0);
  signal char_ram_dout_b : byte_t;

  -- tile signals
  signal tile_data  : byte_t;
  signal tile_code  : tile_code_t;
  signal tile_color : tile_color_t;
  signal tile_row   : tile_row_t;
  signal tile_pixel : tile_pixel_t;

  -- aliases to extract the components of the horizontal and vertical position
  alias col      : unsigned(4 downto 0) is video.pos.x(7 downto 3);
  alias row      : unsigned(4 downto 0) is video.pos.y(7 downto 3);
  alias offset_x : unsigned(2 downto 0) is video.pos.x(2 downto 0);
  alias offset_y : unsigned(2 downto 0) is video.pos.y(2 downto 0);
begin
  -- The character RAM (2kB) contains the code and colour of each tile in the
  -- tilemap.
  --
  -- Each tile in the tilemap is represented by two bytes in the character RAM,
  -- a high byte and a low byte, which contains the tile colour and code.
  --
  -- It has been implemented as a dual-port RAM because both the CPU and the
  -- graphics pipeline need to access the RAM concurrently. Ports A and B are
  -- identical.
  --
  -- This differs from the original arcade hardware, which only contains
  -- a single-port character RAM. Using a dual-port RAM instead simplifies
  -- things, because we don't need all the additional logic required to
  -- coordinate RAM access.
  char_ram : entity work.true_dual_port_ram
  generic map (
    ADDR_WIDTH_A => CHAR_RAM_ADDR_WIDTH,
    ADDR_WIDTH_B => CHAR_RAM_ADDR_WIDTH
  )
  port map (
    -- port A (CPU)
    clk_a  => clk,
    cs_a   => ram_cs,
    addr_a => ram_addr,
    din_a  => ram_din,
    dout_a => ram_dout,
    we_a   => ram_we,

    -- port B (GPU)
    clk_b  => clk,
    addr_b => char_ram_addr_b,
    dout_b => char_ram_dout_b
  );

  -- Load tile data from the character RAM.
  --
  -- While the current tile is being rendered, we need to fetch data for the
  -- next tile ahead, so that it is loaded in time to render it on the screen.
  --
  -- The 16-bit tile data words aren't stored contiguously in RAM, instead they
  -- are split into high and low bytes. The high bytes are stored in the
  -- upper-half of the RAM, while the low bytes are stored in the lower-half.
  --
  -- We latch the tile code well before the end of the row, to allow the GPU
  -- enough time to fetch pixel data from the tile ROM.
  tile_data_pipeline : process (clk)
  begin
    if rising_edge(clk) then
      if cen_6 = '1' then
        case to_integer(offset_x) is
          when 0 =>
            -- load high byte
            char_ram_addr_b <= '1' & row & (col+1);

          when 1 =>
            -- latch high byte
            tile_data <= char_ram_dout_b;

            -- load low byte
            char_ram_addr_b <= '0' & row & (col+1);

          when 2 =>
            -- latch tile code
            tile_code <= unsigned(tile_data(1 downto 0) & char_ram_dout_b);

          when 7 =>
            -- latch colour
            tile_color <= tile_data(7 downto 4);

          when others => null;
        end case;
      end if;
    end if;
  end process;

  -- latch the next row from the tile ROM when rendering the last pixel in
  -- every row
  latch_tile_row : process (clk)
  begin
    if rising_edge(clk) then
      if cen_6 = '1' then
        if video.pos.x(2 downto 0) = 7 then
          tile_row <= rom_data;
        end if;
      end if;
    end if;
  end process;

  -- Set the tile ROM address.
  --
  -- This address points to a row of an 8x8 tile.
  rom_addr <= tile_code & offset_y(2 downto 0);

  -- decode the pixel from the tile row data
  with to_integer(video.pos.x(2 downto 0)) select
    tile_pixel <= tile_row(31 downto 28) when 0,
                  tile_row(27 downto 24) when 1,
                  tile_row(23 downto 20) when 2,
                  tile_row(19 downto 16) when 3,
                  tile_row(15 downto 12) when 4,
                  tile_row(11 downto 8)  when 5,
                  tile_row(7 downto 4)   when 6,
                  tile_row(3 downto 0)   when 7,
                  (others => '0')        when others;

  -- set graphics data
  data <= tile_color & tile_pixel;
end architecture arch;