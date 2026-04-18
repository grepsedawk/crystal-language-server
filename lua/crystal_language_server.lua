-- Neovim glue for crystal-language-server. When this repo is installed
-- as a plugin (packer / lazy.nvim / etc.), the companion
-- `plugin/crystal_language_server.lua` calls `setup()` on startup. Call
-- it yourself if you want to pass options.
--
-- Everything routes through nvim's native LSP (`vim.lsp.config` +
-- `vim.lsp.enable`, requires nvim 0.11+).

local M = {}

-- Directory containing *this* file, so we can find a plugin-local
-- `bin/crystal-language-server` that the build step produced.
local function script_dir()
  return vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
end

local function default_cmd()
  local plugin_root = vim.fn.fnamemodify(script_dir(), ":h")
  local candidates = {
    plugin_root .. "/bin/crystal-language-server",          -- built via plugin `build` hook
    vim.fn.expand("~/.bin/crystal-language-server"),        -- manual install
    vim.fn.expand("~/.local/bin/crystal-language-server"),  -- xdg-ish install
    "crystal-language-server",                               -- PATH
  }
  for _, path in ipairs(candidates) do
    if vim.fn.executable(path) == 1 then
      return { path }
    end
  end
  return nil
end

-- Options (all optional):
--   cmd           table  {binary, arg, ...}; defaults to first resolvable candidate
--   filetypes     table  defaults to { "crystal" }
--   root_markers  table  defaults to { "shard.yml", ".git" }
--   settings      table  forwarded verbatim as LSP init settings
--   log_level     string "trace"|"debug"|"info"|"warn"|"error" — sets CRYSTAL_LANGUAGE_SERVER_LOG_LEVEL
--   log_path      string sets CRYSTAL_LANGUAGE_SERVER_LOG
--   crystal_bin   string sets CRYSTAL_LANGUAGE_SERVER_CRYSTAL
function M.setup(opts)
  opts = opts or {}

  if not vim.lsp.config then
    vim.notify(
      "crystal-language-server: requires Neovim 0.11+ (vim.lsp.config). Skipping.",
      vim.log.levels.WARN
    )
    return
  end

  local cmd = opts.cmd or default_cmd()
  if not cmd then
    -- Stay quiet: fresh clone before the build hook has run is a very
    -- common state. Users who want a loud failure can pass `cmd`.
    return
  end

  local env = {}
  if opts.log_level then env.CRYSTAL_LANGUAGE_SERVER_LOG_LEVEL = opts.log_level end
  if opts.log_path  then env.CRYSTAL_LANGUAGE_SERVER_LOG       = opts.log_path  end
  if opts.crystal_bin then env.CRYSTAL_LANGUAGE_SERVER_CRYSTAL = opts.crystal_bin end

  local config = {
    cmd          = cmd,
    filetypes    = opts.filetypes    or { "crystal" },
    root_markers = opts.root_markers or { "shard.yml", ".git" },
    settings     = opts.settings     or {},
  }
  if next(env) then config.cmd_env = env end

  vim.lsp.config("crystal_ls", config)
  vim.lsp.enable("crystal_ls")
end

-- Command: :CrystalLspBuild — rebuilds the plugin-local binary.
-- Handy when iterating on the server from a plugin checkout.
function M.build()
  local plugin_root = vim.fn.fnamemodify(script_dir(), ":h")
  local cmd = { "shards", "build", "--release", "--no-debug" }
  vim.notify("crystal-language-server: building in " .. plugin_root, vim.log.levels.INFO)
  vim.fn.jobstart(cmd, {
    cwd = plugin_root,
    on_exit = function(_, code)
      if code == 0 then
        vim.notify("crystal-language-server: build succeeded", vim.log.levels.INFO)
      else
        vim.notify("crystal-language-server: build failed (exit " .. code .. ")", vim.log.levels.ERROR)
      end
    end,
  })
end

return M
