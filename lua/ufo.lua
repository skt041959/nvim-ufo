local api = vim.api
local utils = require("ufo.utils")

---Export methods to the users, `require('ufo').method(...)`
---@class Ufo
local M = {}

---Peek the folded line under cursor, any motions in the normal window will close the floating window.
---@param enter? boolean enter the floating window, default value is false
---@param nextLineIncluded? boolean include the next line of last line of closed fold, default is true
---@return number? winid return the winid if successful, otherwise return nil
function M.peekFoldedLinesUnderCursor(enter, nextLineIncluded)
    return require('ufo.preview'):peekFoldedLinesUnderCursor(enter, nextLineIncluded)
end

---Go to previous start fold. Neovim can't go to previous start fold directly, it's an extra motion.
function M.goPreviousStartFold()
    require('ufo.action').goPreviousStartFold()
end

---Go to previous closed fold. It's an extra motion.
function M.goPreviousClosedFold()
    require('ufo.action').goPreviousClosedFold()
end

---Go to next closed fold. It's an extra motion.
function M.goNextClosedFold()
    return require('ufo.action').goNextClosedFold()
end

---Close all folds but keep foldlevel
function M.closeAllFolds()
    return M.closeFoldsWith(0)
end

---Open all folds but keep foldlevel
function M.openAllFolds()
    return require('ufo.action').openFoldsExceptKinds()
end

---Close the folds with a higher level,
---Like execute `set foldlevel=level` but keep foldlevel
---@param level? number fold level, `v:count` by default
function M.closeFoldsWith(level)
    return require('ufo.action').closeFolds(level or vim.v.count)
end

---Open folds except specified kinds
---@param kinds? UfoFoldingRangeKind[] kind in ranges, get default kinds from `config.close_fold_kinds_for_ft`
function M.openFoldsExceptKinds(kinds)
    if not kinds then
        local c = require('ufo.config')
        if c.close_fold_kinds and not vim.tbl_isempty(c.close_fold_kinds) then
            kinds = c.close_fold_kinds
        else
            kinds = c.close_fold_kinds_for_ft[vim.bo.ft] or c.close_fold_kinds_for_ft.default
        end
    end
    return require('ufo.action').openFoldsExceptKinds(kinds)
end

---Inspect ufo information by bufnr
---@param bufnr? number buffer number, current buffer by default
function M.inspect(bufnr)
    bufnr = bufnr or api.nvim_get_current_buf()
    local msg = require('ufo.main').inspectBuf(bufnr)
    if not msg then
        vim.notify(('Buffer %d has not been attached.'):format(bufnr), vim.log.levels.ERROR)
    else
        vim.notify(table.concat(msg, '\n'), vim.log.levels.INFO)
    end
end

---Enable ufo
function M.enable()
    require('ufo.main').enable()
end

---Disable ufo
function M.disable()
    require('ufo.main').disable()
end

---Check whether the buffer has been attached
---@param bufnr? number buffer number, current buffer by default
---@return boolean
function M.hasAttached(bufnr)
    return require('ufo.main').hasAttached(bufnr)
end

---Attach bufnr to enable all features
---@param bufnr? number buffer number, current buffer by default
function M.attach(bufnr)
    require('ufo.main').attach(bufnr)
end

---Detach bufnr to disable all features
---@param bufnr? number buffer number, current buffer by default
function M.detach(bufnr)
    require('ufo.main').detach(bufnr)
end

---Enable to get folds and update them at once
---@param bufnr? number buffer number, current buffer by default
---@return string|'start'|'pending'|'stop' status
function M.enableFold(bufnr)
    return require('ufo.main').enableFold(bufnr)
end

---Disable to get folds
---@param bufnr? number buffer number, current buffer by default
---@return string|'start'|'pending'|'stop' status
function M.disableFold(bufnr)
    return require('ufo.main').disableFold(bufnr)
end

---Get foldingRange from the ufo internal providers by name
---@param bufnr number
---@param providerName string|'lsp'|'treesitter'|'indent'
---@return UfoFoldingRange[]|Promise
function M.getFolds(bufnr, providerName)
    if type(bufnr) == 'string' and type(providerName) == 'number' then
        --TODO signature is changed (swap parameters), notify deprecated in next released
        ---@deprecated
        ---@diagnostic disable-next-line: cast-local-type
        bufnr, providerName = providerName, bufnr
    end
    local func = require('ufo.provider'):getFunction(providerName)
    return func(bufnr)
end

---Apply foldingRange at once.
---ufo always apply folds asynchronously, this function can apply folds synchronously.
---Note: Get ranges from 'lsp' provider is asynchronous.
---@param bufnr number
---@param ranges UfoFoldingRange[]
---@return number winid return the winid if successful, otherwise return -1
function M.applyFolds(bufnr, ranges)
    utils.validate('bufnr', bufnr, 'number', true)
    utils.validate('ranges', ranges, 'table')
    return require('ufo.fold').apply(bufnr, ranges, true)
end

local contextwin -- Defer require

---Setup configuration and enable ufo
---@param opts? UfoConfig
function M.setup(opts)
    opts = opts or {}
    M._config = opts

    local main_enabled = M.enable()
    -- Optional: Pre-initialize contextwin if config exists
    if main_enabled and M._config.context_window then
         contextwin = require('ufo.contextwin')
         local main = require('ufo.main')
         contextwin.get_instance(main.getNamespaceId(), M._config.context_window)
    end
end

---------------------------------------setFoldVirtTextHandler---------------------------------------

---@class UfoFoldVirtTextHandlerContext
---@field bufnr number buffer for closed fold
---@field winid number window for closed fold
---@field text string text for the first line of closed fold
---@field get_fold_virt_text fun(lnum: number): UfoExtmarkVirtTextChunk[] a function to get virtual text by lnum

---@class UfoExtmarkVirtTextChunk
---@field [1] string text
---@field [2] string|number highlight

---Set a fold virtual text handler for a buffer, will override global handler if it's existed.
---Ufo actually uses a virtual text with \`nvim_buf_set_extmark\` to overlap the first line of closed fold
---run \`:h nvim_buf_set_extmark | call search('virt_text')\` for detail.
---Return `{}` will not render folded line but only keep a extmark for providers.
---@diagnostic disable: undefined-doc-param
---Detail for handler function:
---@param virtText UfoExtmarkVirtTextChunk[] contained text and highlight captured by Ufo, export to caller
---@param lnum number first line of closed fold, like \`v:foldstart\` in foldtext()
---@param endLnum number last line of closed fold, like \`v:foldend\` in foldtext()
---@param width number text area width, exclude foldcolumn, signcolumn and numberwidth
---@param truncate fun(str: string, width: number): string truncate the str to become specific width,
---return width of string is equal or less than width (2nd argument).
---For example: '1': 1 cell, '你': 2 cells, '2': 1 cell, '好': 2 cells
---truncate('1你2好', 1) return '1'
---truncate('1你2好', 2) return '1'
---truncate('1你2好', 3) return '1你'
---truncate('1你2好', 4) return '1你2'
---truncate('1你2好', 5) return '1你2'
---truncate('1你2好', 6) return '1你2好'
---truncate('1你2好', 7) return '1你2好'
---@param ctx UfoFoldVirtTextHandlerContext the context used by ufo, export to caller

---@alias UfoFoldVirtTextHandler fun(virtText: UfoExtmarkVirtTextChunk[], lnum: number, endLnum: number, width: number, truncate: fun(str: string, width: number), ctx: UfoFoldVirtTextHandlerContext): UfoExtmarkVirtTextChunk[]

---@param bufnr number
---@param handler UfoFoldVirtTextHandler
function M.setFoldVirtTextHandler(bufnr, handler)
    utils.validate('bufnr', bufnr, 'number', true)
    utils.validate('handler',handler, 'function')
    require('ufo.decorator'):setVirtTextHandler(bufnr, handler)
end

---@diagnostic disable: undefined-doc-param
---------------------------------------setFoldVirtTextHandler---------------------------------------

--- Shows context fold lines above the cursor in a floating window.
function M.showContextAboveCursor()
    if not M.hasAttached() then
        vim.notify("UFO: Buffer not attached.", vim.log.levels.WARN)
        return
    end
    contextwin = contextwin or require('ufo.contextwin')
    local main = require('ufo.main') -- To get config/namespace if needed later
    local current_win = api.nvim_get_current_win()
    local current_buf = api.nvim_get_current_buf()
    local fb = require('ufo.fold').get(current_buf)
    if not fb then
        vim.notify("UFO: FoldBuffer not found.", vim.log.levels.WARN)
        return
    end

    local cursor_pos = api.nvim_win_get_cursor(current_win)
    local cursor_lnum = cursor_pos[1]

    -- Ensure contextwin is initialized (might need refactoring if ns/config change)
    local cfg = require('ufo.config').context_window -- Assuming config structure
    local cw = contextwin.get_instance(main.getNamespaceId(), cfg) -- Need main to expose ns id

    local linesInfo = cw:_findContextLines(fb, cursor_lnum)

    if linesInfo and #linesInfo > 0 then
        cw:open(current_win, linesInfo)
    else
        cw:close() -- Close if no context found or cursor not in fold
        -- Optional: vim.notify("UFO: No fold context found at cursor.", vim.log.levels.INFO)
    end
end

--- Closes the context window if it's open.
function M.closeContextAboveCursor()
   contextwin = contextwin or require('ufo.contextwin')
   local cw = contextwin.get_instance() -- Get existing instance
   cw:close()
end

return M
