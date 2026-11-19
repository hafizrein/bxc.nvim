-- Commands are defined on load so :Bxc works even when the user never called setup().
if vim.g.loaded_bxc then
  return
end
vim.g.loaded_bxc = true

require("bxc").commands()
