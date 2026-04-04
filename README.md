# gbc.nvim

A Game Boy / Game Boy Color emulator plugin for Neovim. Play classic games directly in your editor using a native SameBoy bridge with Lua-based UI and rendering.

![License](https://img.shields.io/badge/license-MIT-blue.svg)

## Features

- **Full Game Boy & Game Boy Color support** via [SameBoy](https://github.com/LIJI32/SameBoy)
- **Multiple rendering backends**: Kitty graphics, cell-based terminal, and auto-detection
- **Configurable frame rate** (default 60 FPS)
- **Audio support** (optional)
- **Save states and battery saves** for persistent progress
- **Socket-based architecture** for stability and isolation

## Installation

### Requirements

- Neovim (0.7+)
- C compiler (gcc, clang, or similar)
- Make

### Setup

Using a plugin manager (e.g., [lazy.nvim](https://github.com/folke/lazy.nvim)):

```lua
{
  "kyza0d/gbc.nvim",
  build = "make",
  config = function()
    require("gbc").setup({
      renderer = "auto",        -- "auto", "kitty", or "cell"
      audio = false,            -- enable audio output
      target_fps = 60,          -- target frame rate
    })
  end,
}
```

Or with [packer.nvim](https://github.com/wbthomson/packer.nvim):

```lua
use {
  "kyza0d/gbc.nvim",
  run = "make",
  config = function()
    require("gbc").setup()
  end,
}
```

## Usage

Launch a Game Boy ROM:

```vim
:GB /absolute/path/to/rom.gb
```

Build or verify the native bridge:

```vim
:GBCheck
```

## Configuration

Default configuration:

```lua
require("gbc").setup({
  renderer = "auto",              -- renderer backend ("auto", "kitty", "cell")
  audio = false,                  -- enable audio playback
  target_fps = 60,                -- target frames per second
  kitty_present_delay_ms = 750,   -- delay for kitty graphics
  tmux_passthrough = <auto>,      -- enable tmux passthrough
})
```

## Architecture

gbc.nvim splits concerns across a native bridge and Lua:

- **Native Bridge** (`sameboy-host`): Emulation loop, ROM loading, frame rendering
- **Lua Plugin**: Neovim integration, input handling, UI/window management, rendering transport
- **Protocol**: Binary framed protocol over Unix domain socket

This design keeps the emulator isolated from Neovim's runtime while maintaining fast communication.

## Supported Games

Any Game Boy or Game Boy Color ROM should work. Tested with:
- The Legend of Zelda: Link's Awakening
- Pokémon Red/Blue/Yellow
- Tetris
- Kirby's Dream Land

## Troubleshooting

**White screen after launch:**
- Try a different renderer: `:set gbc_renderer=cell`
- Check the native bridge build: `:GBCheck`

**No input response:**
- Ensure the buffer is in focus
- Check key mappings in your config

**Poor performance:**
- Lower `target_fps` in config
- Try `renderer = "cell"` for lower overhead

## Development

Run tests:

```bash
make test
```

Build the native bridge:

```bash
make
```

Clean build artifacts:

```bash
make clean
```

## License

MIT License — See LICENSE file for details.

## Credits

- Emulation engine: [SameBoy](https://github.com/LIJI32/SameBoy) by Liji32
- Architecture inspired by [actually-doom.nvim](https://github.com/slyth11907/actually-doom.nvim)

Special thanks to the author and contributors of
[actually-doom.nvim](https://github.com/slyth11907/actually-doom.nvim) for the
original Neovim game/engine host pattern that gbc.nvim is built on.
