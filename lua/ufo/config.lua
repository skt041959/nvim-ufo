local utils = require('ufo.utils')

---@class UfoContextWindowConfig
---@field border? string|string[] Border style (e.g., 'single', 'rounded', or custom array)
---@field winblend? number Window transparency (0-100)
---@field winhighlight? string Highlighting for the window background (e.g., "Normal:MyContextBg")
---@field max_lines? number Maximum number of context lines to show
---@field max_height? number Maximum height of the floating window
---@field zindex? number Stacking order
---@field show_inlay_hints? boolean Whether to attempt showing inlay hints (default false)

---@class UfoConfig
---@field provider_selector? function
---@field open_fold_hl_timeout? number
---@field close_fold_kinds_for_ft? table<string, UfoFoldingRangeKind[]>
---@field fold_virt_text_handler? UfoFoldVirtTextHandler A global virtual text handler, reference to `ufo.setFoldVirtTextHandler`
---@field enable_get_fold_virt_text? boolean
---@field preview? table
---@field context_window? UfoContextWindowConfig
local def = {
    open_fold_hl_timeout = 400,
    provider_selector = nil,
    close_fold_kinds_for_ft = {default = {}},
    fold_virt_text_handler = nil,
    enable_get_fold_virt_text = false,
    preview = {
        win_config = {
            border = 'rounded',
            winblend = 12,
            winhighlight = 'Normal:Normal',
            maxheight = 20
        },
        mappings = {
            scrollB = '',
            scrollF = '',
            scrollU = '',
            scrollD = '',
            scrollE = '<C-E>',
            scrollY = '<C-Y>',
            jumpTop = '',
            jumpBot = '',
            close = 'q',
            switch = '<Tab>',
            trace = '<CR>'
        }
    },
    context_window = { -- Defaults for the new context window
        border = 'single',
        winblend = 0,
        winhighlight = 'Normal:NormalFloat', -- Example: Use NormalFloat background
        max_lines = 5,
        max_height = 10,
        zindex = 100,
        show_inlay_hints = false,
    }
}

---@type UfoConfig
local Config = {}


---@alias UfoProviderEnum
---| 'lsp'
---| 'treesitter'
---| 'indent'

---
---@param bufnr number
---@param filetype string file type
---@param buftype string buffer type
---@return UfoProviderEnum|string[]|function|nil
---return a string type use ufo providers
---return a string in a table like a string type
---return empty string '' will disable any providers
---return `nil` will use default value {'lsp', 'indent'}
---@diagnostic disable-next-line: unused-function, unused-local
function Config.provider_selector(bufnr, filetype, buftype) end

local function init()
    local ufo = require('ufo')
    ---@type UfoConfig
    Config = vim.tbl_deep_extend('keep', ufo._config or {}, def)
    utils.validate("open_fold_hl_timeout", Config.open_fold_hl_timeout, 'number')
    utils.validate('provider_selector' , Config.provider_selector, 'function', true)
    utils.validate('close_fold_kinds_for_ft', Config.close_fold_kinds_for_ft, 'table')
    utils.validate('fold_virt_text_handler', Config.fold_virt_text_handler, 'function', true)
    utils.validate('preview_mappings', Config.preview.mappings, 'table')

    -- Validation for new context_window options (optional but good practice)
    if Config.context_window then
         utils.validate('context_window.border', Config.context_window.border, {'string', 'table'}, true)
         utils.validate('context_window.winblend', Config.context_window.winblend, 'number', true)
         utils.validate('context_window.winhighlight', Config.context_window.winhighlight, 'string', true)
         utils.validate('context_window.max_lines', Config.context_window.max_lines, 'number', true)
         utils.validate('context_window.max_height', Config.context_window.max_height, 'number', true)
         utils.validate('context_window.zindex', Config.context_window.zindex, 'number', true)
         utils.validate('context_window.show_inlay_hints', Config.context_window.show_inlay_hints, 'boolean', true)
    end

    local preview = Config.preview
    for msg, key in pairs(preview.mappings) do
        if key == '' then
            preview.mappings[msg] = nil
        end
    end
    if Config.close_fold_kinds and not vim.tbl_isempty(Config.close_fold_kinds) then
        vim.notify('Option `close_fold_kinds` in `nvim-ufo` is deprecated, use `close_fold_kinds_for_ft` instead.',
            vim.log.levels.WARN)
        if not Config.close_fold_kinds_for_ft.default then
            Config.close_fold_kinds_for_ft.default = Config.close_fold_kinds
        end
    end
    ufo._config = nil
end

init()

return Config
