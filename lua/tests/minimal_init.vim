let g:loaded_netrwPlugin = 1
set runtimepath=$VIMRUNTIME
set packpath=.
set runtimepath+=.

lua _G.__is_log = true
runtime! plugin/octo.nvim

lua << EOF
require("tests/test_utils")
require("octo").setup { picker = "default" }
EOF
