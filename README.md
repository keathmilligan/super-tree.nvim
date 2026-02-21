# nvim-tree-sidebar

A Neovim file explorer sidebar that displays a file tree view of the current directory. This plugin is evolving incrementally toward a full-featured sidebar.

## Features

- **File Tree View**: Displays hierarchical file structure with guide lines connecting parent-child relationships
- **File-Type Icons**: Icons for 30+ file types (Lua, JavaScript, Python, Rust, etc.) with theme-aware colors
- **Special File Icons**: Distinct icons for Dockerfile, .gitignore, Makefile, package.json, README.md, and more
- **Optional nvim-web-devicons**: Full 500+ icon support when `nvim-web-devicons` is installed
- **Folder Icons**: Open/closed folder icons reflecting directory state
- **Directory Highlighting**: Directory names highlighted with theme-aware colors
- **Navigation**: Up/Down arrow keys to navigate through the tree
- **Directory Expansion**: Enter key to expand/collapse directories
- **Non-Buffer UI**: Sidebar behaves like a pure UI element - no insert mode, no editing commands
- **Auto-Scroll**: Content scrolls automatically when navigating beyond visible area
- **Display Modes**: Floating (overlay) or pinned (pushes content) sidebar options

## Roadmap

This plugin is evolving incrementally. Planned features include:
- File operations (create, delete, rename, copy, move)
- File opening in splits and tabs
- Git status indicators
- Filtered view (hide dotfiles, gitignore patterns)
- Search within tree

## Requirements

- Neovim 0.8+
- **Nerd Font** (required for icons)

### Optional Dependencies

- [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons) - Provides 500+ file-type icons with colors (recommended)

## Installation

### LazyVim

Add to your LazyVim config:

```lua
return {
  "yourusername/nvim-tree-sidebar",
  opts = {},
}
```

### Packer

```lua
use {
  "yourusername/nvim-tree-sidebar",
  config = function()
    require("nvim-tree-sidebar").setup()
  end,
}
```

### vim-plug

```vim
Plug 'yourusername/nvim-tree-sidebar'
" Then in your init.lua:
" require("nvim-tree-sidebar").setup()
```

## Commands

| Command | Description |
|---------|-------------|
| `:TreeSidebar` | Toggle sidebar visibility |
| `:TreeSidebarOpen` | Open sidebar |
| `:TreeSidebarClose` | Close sidebar |

## Keybindings

The sidebar only responds to these keys when focused:

| Key | Action |
|-----|--------|
| `<Up>` | Move selection up |
| `<Down>` | Move selection down |
| `<Enter>` | Expand/collapse directory |

All other keys are disabled to prevent buffer-related behaviors.

## Configuration

```lua
require("nvim-tree-sidebar").setup({
  width = 30,        -- Sidebar width in columns
  mode = "floating", -- "floating" or "pinned"
  icons = {
    enable = true,       -- Enable file-type icons
    provider = "auto",   -- "auto", "nvim-web-devicons", or "builtin"
  },
})
```

### Icon Configuration

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `icons.enable` | boolean | `true` | Enable file-type specific icons |
| `icons.provider` | string | `"auto"` | Icon provider: `"auto"` (nvim-web-devicons if available, fallback to builtin), `"nvim-web-devicons"` (require it), `"builtin"` (always use built-in icons) |

### Icon Providers

**auto** (default):
- Uses `nvim-web-devicons` if installed
- Falls back to built-in icons (30+ common file types) if not available

**nvim-web-devicons**:
- Requires `nvim-tree/nvim-web-devicons` to be installed
- Provides 500+ file-type icons with colors
- Shows warning if not found

**builtin**:
- Always uses built-in icon set
- Includes 30+ common file types
- Works without any dependencies

### Display Modes

**Floating** (default):
- Sidebar overlays on top of the current buffer
- No statusline - completely minimal UI
- Press `q` or `<Esc>` to close

**Pinned**:
- Sidebar pushes all window content to the right
- Acts like a split without buffer behaviors
- Has a minimal statusline showing "Tree Sidebar"
- Fixed width that won't resize with `<C-w>=`

### Bufferline Integration

To add an offset in bufferline when the sidebar is open:

```lua
require("bufferline").setup({
  options = {
    offsets = {
      {
        filetype = "tree-sidebar",
        text = "Tree Sidebar",
        highlight = "Directory",
        separator = true,
      }
    }
  }
})
```

The plugin automatically triggers `redrawtabline` and emits `User` events (`TreeSidebarOpen`, `TreeSidebarClose`) for bufferline integration.

## Limitations

This plugin is focused on tree navigation and visualization:

- No file operations (create, delete, rename)
- No file opening
- No mouse support
- No persistent state

## License

MIT