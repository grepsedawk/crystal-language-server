-- Auto-loaded by Neovim at startup. Registers crystal-language-server
-- with the native LSP client if a binary can be found, otherwise stays
-- silent (common state before the plugin's build hook runs).
--
-- Opt out by setting `vim.g.crystal_language_server_no_autosetup = 1`
-- before the plugin loads, and call `require("crystal_language_server")
-- .setup({...})` yourself when you're ready.

if vim.g.loaded_crystal_language_server == 1 then return end
vim.g.loaded_crystal_language_server = 1

if vim.g.crystal_language_server_no_autosetup == 1 then return end

-- Defer a tick — lets users who configure via `require(...).setup()`
-- override filetypes/cmd before we register.
vim.schedule(function()
  local ok, mod = pcall(require, "crystal_language_server")
  if ok then mod.setup() end
end)

vim.api.nvim_create_user_command("CrystalLspBuild", function()
  require("crystal_language_server").build()
end, { desc = "Rebuild the crystal-language-server binary in the plugin directory" })
