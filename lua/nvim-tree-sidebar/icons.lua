local M = {}

-- Default icons (requires Nerd Font)
M.ICON_FILE          = string.char(0xEF, 0x85, 0x9B) .. " "  -- nf-fa-file (U+F15B)
M.ICON_FOLDER_CLOSED = string.char(0xEE, 0x97, 0xBF) .. " " -- nf-custom-folder (U+E5FF)
M.ICON_FOLDER_OPEN   = string.char(0xEE, 0x97, 0xBE) .. " " -- nf-custom-folder_open (U+E5FE)

-- Git indicator icons (requires Nerd Font)
M.ICON_GIT_REPO = string.char(0xEE, 0x9C, 0x82) .. " " -- nf-dev-git (U+E702)
M.ICON_GITHUB   = string.char(0xEE, 0x9C, 0x89) .. " " -- nf-dev-github (U+E709)

-- Built-in icon set for files (used when nvim-web-devicons is not available)
local BUILTIN_ICONS = {
  filenames = {
    ["dockerfile"]        = { icon = "󰡨 ", hl = "DevIconDockerfile" },
    [".dockerignore"]     = { icon = "󰡨 ", hl = "DevIconDockerfile" },
    [".gitignore"]        = { icon = "󰊢 ", hl = "DevIconGitignore" },
    [".gitattributes"]    = { icon = "󰊢 ", hl = "DevIconGitignore" },
    [".gitmodules"]       = { icon = "󰊢 ", hl = "DevIconGitignore" },
    ["makefile"]          = { icon = "󱁣 ", hl = "DevIconMake" },
    ["package.json"]      = { icon = "󰌞 ", hl = "DevIconNpm" },
    ["package-lock.json"] = { icon = "󰌞 ", hl = "DevIconNpm" },
    ["yarn.lock"]         = { icon = "󰌞 ", hl = "DevIconNpm" },
    ["pnpm-lock.yaml"]    = { icon = "󰌞 ", hl = "DevIconNpm" },
    ["readme.md"]         = { icon = "󰍛 ", hl = "DevIconReadme" },
    ["readme"]            = { icon = "󰍛 ", hl = "DevIconReadme" },
    ["license"]           = { icon = "󰈔 ", hl = "DevIconLicense" },
    ["license.md"]        = { icon = "󰈔 ", hl = "DevIconLicense" },
    ["license.txt"]       = { icon = "󰈔 ", hl = "DevIconLicense" },
    [".env"]              = { icon = "󰌠 ", hl = "DevIconEnv" },
    [".env.local"]        = { icon = "󰌠 ", hl = "DevIconEnv" },
    [".env.example"]      = { icon = "󰌠 ", hl = "DevIconEnv" },
    ["Cargo.toml"]        = { icon = "󱘗 ", hl = "DevIconCargo" },
    ["Cargo.lock"]        = { icon = "󱘗 ", hl = "DevIconCargo" },
    ["go.mod"]            = { icon = "󰟓 ", hl = "DevIconGo" },
    ["go.sum"]            = { icon = "󰟓 ", hl = "DevIconGo" },
  },
  extensions = {
    ["lua"]    = { icon = "󰢱 ", hl = "DevIconLua" },
    ["js"]     = { icon = "󰌞 ", hl = "DevIconJavascript" },
    ["ts"]     = { icon = "󰛚 ", hl = "DevIconTypescript" },
    ["jsx"]    = { icon = "󰌗 ", hl = "DevIconReact" },
    ["tsx"]    = { icon = "󰛢 ", hl = "DevIconReactTs" },
    ["vue"]    = { icon = "󰡄 ", hl = "DevIconVue" },
    ["svelte"] = { icon = "󰛠 ", hl = "DevIconSvelte" },
    ["py"]     = { icon = "󰌠 ", hl = "DevIconPython" },
    ["rs"]     = { icon = "󱘗 ", hl = "DevIconRust" },
    ["go"]     = { icon = "󰟓 ", hl = "DevIconGo" },
    ["c"]      = { icon = "󰌞 ", hl = "DevIconC" },
    ["cpp"]    = { icon = "󰝙 ", hl = "DevIconCxx" },
    ["h"]      = { icon = "󰌞 ", hl = "DevIconC" },
    ["hpp"]    = { icon = "󰝙 ", hl = "DevIconCxx" },
    ["java"]   = { icon = "󰬇 ", hl = "DevIconJava" },
    ["rb"]     = { icon = "󰴭 ", hl = "DevIconRuby" },
    ["php"]    = { icon = "󰘞 ", hl = "DevIconPhp" },
    ["md"]     = { icon = "󰍛 ", hl = "DevIconMarkdown" },
    ["json"]   = { icon = "󰘦 ", hl = "DevIconJson" },
    ["yaml"]   = { icon = "󰠷 ", hl = "DevIconYaml" },
    ["yml"]    = { icon = "󰠷 ", hl = "DevIconYaml" },
    ["toml"]   = { icon = "󰅭 ", hl = "DevIconToml" },
    ["xml"]    = { icon = "󰗀 ", hl = "DevIconXml" },
    ["html"]   = { icon = "󰌝 ", hl = "DevIconHtml" },
    ["css"]    = { icon = "󰌜 ", hl = "DevIconCss" },
    ["scss"]   = { icon = "󰌶 ", hl = "DevIconSass" },
    ["sass"]   = { icon = "󰌶 ", hl = "DevIconSass" },
    ["less"]   = { icon = "󰌶 ", hl = "DevIconLess" },
    ["sh"]     = { icon = "󰈷 ", hl = "DevIconShell" },
    ["bash"]   = { icon = "󰈷 ", hl = "DevIconShell" },
    ["zsh"]    = { icon = "󰈷 ", hl = "DevIconShell" },
    ["fish"]   = { icon = "󰈷 ", hl = "DevIconShell" },
    ["sql"]    = { icon = "󰆼 ", hl = "DevIconSql" },
    ["txt"]    = { icon = "󰈙 ", hl = "DevIconTxt" },
    ["conf"]   = { icon = "󰌅 ", hl = "DevIconConfig" },
    ["cfg"]    = { icon = "󰌅 ", hl = "DevIconConfig" },
    ["ini"]    = { icon = "󰌅 ", hl = "DevIconConfig" },
    ["gitconfig"] = { icon = "󰊢 ", hl = "DevIconGitignore" },
    ["lock"]   = { icon = "󰌠 ", hl = "DevIconLock" },
    ["log"]    = { icon = "󰌠 ", hl = "DevIconLog" },
  },
  default = { icon = " ", hl = "TreeSidebarFile" },
}

-- Extract file extension from filename (returns lowercase extension or empty string)
function M.get_extension(name)
  local ext = name:match("%.([^%.]+)$")
  return ext and ext:lower() or ""
end

-- Get icon for a file using built-in icons
function M.get_builtin_icon(name, extension)
  local lower_name = name:lower()

  if BUILTIN_ICONS.filenames[lower_name] then
    local icon_data = BUILTIN_ICONS.filenames[lower_name]
    return icon_data.icon, icon_data.hl
  end

  if extension and extension ~= "" and BUILTIN_ICONS.extensions[extension] then
    local icon_data = BUILTIN_ICONS.extensions[extension]
    return icon_data.icon, icon_data.hl
  end

  return BUILTIN_ICONS.default.icon, BUILTIN_ICONS.default.hl
end

-- Get icon for a file (nvim-web-devicons if available, fallback to builtin).
-- `icons_config` is the `config.icons` table from setup.
function M.get_icon_for_file(name, extension, icons_config)
  if icons_config and icons_config.enable == false then
    return M.ICON_FILE, "TreeSidebarFile"
  end

  if icons_config and icons_config.provider == "builtin" then
    return M.get_builtin_icon(name, extension)
  end

  -- Try nvim-web-devicons for "auto" or "nvim-web-devicons" provider
  if not icons_config or icons_config.provider ~= "builtin" then
    local ok, web_devicons = pcall(require, "nvim-web-devicons")
    if ok then
      local icon, hl = web_devicons.get_icon(name, extension, { default = true })
      if icon then
        return icon, hl
      end
    end

    if icons_config and icons_config.provider == "nvim-web-devicons" then
      vim.notify_once("nvim-web-devicons not found, using builtin icons", vim.log.levels.WARN)
    end
  end

  return M.get_builtin_icon(name, extension)
end

-- Define highlight groups for built-in icon types
function M.setup_highlights()
  local links = {
    DevIconLua        = "Statement",
    DevIconJavascript = "Statement",
    DevIconTypescript = "Type",
    DevIconReact      = "Constant",
    DevIconReactTs    = "Type",
    DevIconVue        = "Constant",
    DevIconSvelte     = "Constant",
    DevIconPython     = "Statement",
    DevIconRust       = "Statement",
    DevIconGo         = "Statement",
    DevIconC          = "Statement",
    DevIconCxx        = "Statement",
    DevIconJava       = "Statement",
    DevIconRuby       = "Constant",
    DevIconPhp        = "Statement",
    DevIconMarkdown   = "Title",
    DevIconJson       = "String",
    DevIconYaml       = "String",
    DevIconToml       = "String",
    DevIconXml        = "String",
    DevIconHtml       = "Tag",
    DevIconCss        = "Tag",
    DevIconSass       = "Tag",
    DevIconLess       = "Tag",
    DevIconShell      = "Identifier",
    DevIconSql        = "Statement",
    DevIconTxt        = "Normal",
    DevIconConfig     = "Comment",
    DevIconDockerfile = "Constant",
    DevIconGitignore  = "Comment",
    DevIconMake       = "Statement",
    DevIconNpm        = "Constant",
    DevIconReadme     = "Title",
    DevIconLicense    = "Title",
    DevIconEnv        = "Constant",
    DevIconCargo      = "Constant",
    DevIconLock       = "Comment",
    DevIconLog        = "Comment",
    TreeSidebarFile   = "Normal",
  }

  for name, link in pairs(links) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
end

return M
