--
-- My minimal personal configuration
--
vim.g.mapleader = ' '
vim.g.maplocalleader = ' '

vim.o.mouse = ''
vim.wo.wrap = false
vim.keymap.set('n', '<c-f>', '<esc>', { desc = 'sina: escape' })
vim.keymap.set('i', '<c-f>', '<esc>', { desc = 'sina: escape' })
vim.keymap.set('v', '<c-f>', '<esc>', { desc = 'sina: escape' })
vim.keymap.set('c', '<c-f>', '<esc>', { desc = 'Sina: escape' })
vim.keymap.set('t', '<c-f>', '<esc>', { desc = 'Sina: escape' })
vim.keymap.set('s', '<c-f>', '<esc>', { desc = 'Sina: escape' })
vim.keymap.set('n', '<c-j>', '<c-w>j', { desc = 'Sina: navigating windows' })
vim.keymap.set('n', '<c-k>', '<c-w>k', { desc = 'Sina: navigating windows' })
vim.keymap.set('n', '<c-h>', '<c-w>h', { desc = 'Sina: navigating windows' })
vim.keymap.set('n', '<c-l>', '<c-w>l', { desc = 'Sina: navigating windows' })
vim.keymap.set('n', ';w', ':up<cr>', { desc = 'Sina: write/update buffer' })
vim.keymap.set('n', ';q', ':q<cr>', { desc = 'Sina: close window' })

--
-- Install Lazy.nvim
--
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.loop.fs_stat(lazypath) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable", -- latest stable release
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

--
-- Install Shell.nvim
--
require("lazy").setup({
  {
    'nvim-telescope/telescope.nvim', tag = '0.1.x',
    dependencies = { 'nvim-lua/plenary.nvim' }
  },
  {
    "shellpad/shellpad.nvim",
    dev = true,
    dependencies = { "nvim-telescope/telescope.nvim" },
    config = function(opts)
      require('shellpad').setup(opts)
      vim.keymap.set('n', '<leader>sc', require('shellpad').telescope_history_search(), { desc = '[S]earch [C]ommands' })
    end,
  },

  { "siadat/animated-resize.nvim", opts = {} }, -- For asciinema recording
}, { dev = { path = '/work/src/nvim-plugins' } })

