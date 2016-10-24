" Disable vi compatibility
set nocompatible

" Highlight syntax
syntax on

" Intelligently indent new lines
set smartindent
set autoindent

" Set sane tab usage
set shiftwidth=4
set tabstop=4
set expandtab
set smarttab

" Show line & column in bottom right
set ruler

" Show line numbers
set number

" Incremental & smart/case-insensitive search
set incsearch
set smartcase
set ignorecase

filetype plugin on

call plug#begin()

Plug 'fatih/vim-go'
Plug 'wincent/command-t'

call plug#end()

let mapleader=","

