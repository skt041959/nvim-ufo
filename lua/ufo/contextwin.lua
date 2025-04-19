local api = vim.api
local fn = vim.fn
local cmd = vim.cmd

local utils = require('ufo.utils')
local fold = require('ufo.fold')
local extmark = require('ufo.render.extmark')
local treesitter = require('ufo.render.treesitter')
local log = require('ufo.lib.log')
local disposable = require('ufo.lib.disposable')

local FoldTree = {}

---@class UfoFoldTreeNode
---@field startLine number 0-based
---@field endLine number 0-based
---@field kind? UfoFoldingRangeKind
---@field children UfoFoldTreeNode[] List of child nodes
---@field parent? UfoFoldTreeNode Reference to the parent node

--- Builds a fold tree from sorted fold ranges.
--- Assumes ranges are sorted primarily by startLine descending, then endLine ascending.
---@param foldRanges UfoFoldingRange[] The sorted list of fold ranges.
---@param lineCount number Total lines in the buffer.
---@return UfoFoldTreeNode root The root node of the fold tree.
function FoldTree.build_fold_tree(foldRanges, lineCount)
    table.sort(foldRanges, function(a, b)
        return a.startLine == b.startLine and a.endLine < b.endLine or a.startLine < b.startLine
    end)

    ---@type UfoFoldTreeNode
    local root = {
        startLine = -1, -- Virtual root covers before the buffer start
        endLine = lineCount, -- Virtual root covers until the buffer end
        children = {},
        kind = 'root',
        parent = nil, -- Root has no parent
    }

    -- Stack holds the potential parent nodes encountered so far.
    -- Starts with the virtual root.
    ---@type UfoFoldTreeNode[]
    local stack = { root }

    -- Iterate through the ranges as they are sorted (startLine ascending)
    for _, range in ipairs(foldRanges) do
        -- Create the node for the current range
        ---@type UfoFoldTreeNode
        local node = {
            startLine = range.startLine,
            endLine = range.endLine,
            kind = range.kind,
            children = {},
            parent = nil -- Will be set shortly
        }

        -- Find the correct parent from the stack.
        -- Pop nodes from the stack whose endLine is <= the current node's endLine.
        -- This means the current node cannot be a child of the popped nodes.
        -- We check <= because a fold cannot be a child of another fold ending on the same line.
        if stack[#stack].startLine == node.startLine and stack[#stack].endLine == node.endLine then
            -- If the last node on the stack is the same as the current node, skip it.
            log.debug('FoldTree: Skipping duplicate node:', node.startLine, node.endLine)
            goto continue
        end
        while stack[#stack].endLine <= node.endLine do
            table.remove(stack)
        end

        -- The node at the top of the stack is now the parent.
        local parent = stack[#stack]
        node.parent = parent

        -- Add the current node as a child of the parent.
        table.insert(parent.children, node)

        -- Push the current node onto the stack, it might be a parent for subsequent nodes.
        table.insert(stack, node)

        ::continue::
    end

    return root
end

--- Finds the innermost node containing the given line number.
---@param node UfoFoldTreeNode The node to start searching from (usually the root).
---@param lnum number The 1-based line number to find.
---@return UfoFoldTreeNode? node The innermost node containing the line, or nil.
function FoldTree.find_node_containing_line(node, lnum)
    log.debug('FoldTree.find_node_containing_line:', node.startLine, node.endLine, #node.children, lnum)
    local target_line_zero_based = lnum - 1

    -- Check if the line is within the current node's range (exclusive end for containment check)
    if target_line_zero_based == node.startLine then
        -- If the line is exactly at the start of this node, return this node
        return node
    elseif target_line_zero_based >= node.startLine and target_line_zero_based <= node.endLine then
        -- Check children first (depth-first)
        for _, child in ipairs(node.children) do
            local found_in_child = FoldTree.find_node_containing_line(child, lnum)
            if found_in_child then
                return found_in_child -- Return the deeper node
            end
        end
        -- If not found in any child, and the line is within this node, then this node is the innermost
        return node
    end
    -- Line is not within this node or its children
    return nil
end

--- Gets the parent and preceding siblings of a target node.
---@param targetNode UfoFoldTreeNode
---@return UfoFoldTreeNode? parent, UfoFoldTreeNode[] preceding_siblings
function FoldTree.get_parent_and_preceding_siblings(targetNode)
    if not targetNode or not targetNode.parent then
        return nil, {} -- No parent (might be top-level or root)
    end

    local parent = targetNode.parent
    local siblings = parent.children
    local preceding_siblings = {}
    for _, sibling in ipairs(siblings) do
        if sibling == targetNode then
            break -- Stop when we reach the target node itself
        end
        table.insert(preceding_siblings, sibling)
    end

    return parent, preceding_siblings
end

-- Optional: Caching mechanism
local tree_cache = {} -- { [bufnr] = { version = number, root = UfoFoldTreeNode } }

--- Gets the fold tree, building it if necessary or using a cached version.
---@param fb UfoFoldBuffer
---@return UfoFoldTreeNode? root
function FoldTree.get_fold_tree(fb)
    local bufnr = fb.bufnr
    local current_version = fb.version

    if tree_cache[bufnr] and tree_cache[bufnr].version == current_version then
        return tree_cache[bufnr].root -- Return cached tree
    end

    -- Need to build/rebuild the tree
    if not fb.foldRanges or #fb.foldRanges == 0 then
        return nil -- No ranges to build a tree from
    end

    local lineCount = fb:lineCount()
    local root = FoldTree.build_fold_tree(fb.foldRanges, lineCount)

    -- Cache the new tree
    tree_cache[bufnr] = { version = current_version, root = root }

    return root
end

-- Clear cache on buffer detach/reload
local function clear_cache(bufnr)
    tree_cache[bufnr] = nil
end

require('ufo.lib.event'):on('BufDetach', clear_cache)
require('ufo.lib.event'):on('BufReload', clear_cache)


---@class UfoContextWin
---@field private ns number
---@field private config table
---@field private winid number|nil
---@field private bufnr number|nil
---@field private bufferName string
---@field private width number
---@field private height number
---@field private border string|string[]
---@field private disposables UfoDisposable[] | nil
---@field private originalWinid number | nil
local ContextWin = {}
ContextWin.__index = ContextWin

-- Reuse border definitions if needed
local defaultBorder = {
    none    = {'', '', '', '', '', '', '', ''},
    single  = {'┌', '─', '┐', '│', '┘', '─', '└', '│'},
    double  = {'╔', '═', '╗', '║', '╝', '═', '╚', '║'},
    rounded = {'╭', '─', '╮', '│', '╯', '─', '╰', '│'},
    solid   = {' ', ' ', ' ', ' ', ' ', ' ', ' ', ' '},
    shadow  = {'', '', {' ', 'FloatShadowThrough'}, {' ', 'FloatShadow'},
        {' ', 'FloatShadow'}, {' ', 'FloatShadow'}, {' ', 'FloatShadowThrough'}, ''},
}

local function borderHasLine(border, index)
    -- Simplified check from floatwin.lua
    local s = border[index]
    return type(s) == 'string' and s ~= '' or type(s) == 'table' and s[1] ~= ''
end

--- Finds the innermost fold containing the cursor and its preceding siblings at the same level.
---@param fb UfoFoldBuffer
---@param cursorLnum number 1-based cursor line number
---@return table[]? list of {lnum: number, text: string} or nil
function ContextWin:_findContextLines(fb, cursorLnum)
    -- Get the fold tree (builds/caches as necessary)
    local foldTree = FoldTree.get_fold_tree(fb)
    if not foldTree then
        log.debug('ContextWin: Could not get or build fold tree for bufnr', fb.bufnr)
        return nil
    end

    local target_node = FoldTree.find_node_containing_line(foldTree, cursorLnum)
    log.debug('target_node:', target_node)

    if target_node and target_node.startLine == cursorLnum - 1 then
        -- If the target node starts at the cursor line, we need to go to its parent
        target_node = target_node.parent
    end

    if not target_node or target_node == foldTree then
        log.debug('ContextWin: Could not find specific fold node containing line', cursorLnum)
        return nil -- Didn't find a specific fold node
    end

    local contextLines = {{lnum = target_node.startLine + 1}} -- Start with the target node's start line
    local maxLines = self.config.max_lines or 5 -- Example limit

    local parent = target_node.parent
    while parent do
        -- Get parent and preceding siblings
        local p, preceding_siblings = FoldTree.get_parent_and_preceding_siblings(target_node)
        if not p then
            break
        end
        log.debug('ContextWin: Found target node:', target_node.startLine, 'parent:', p.startLine)
        table.insert(contextLines, {lnum = p.startLine + 1})

        for _, sibling in ipairs(preceding_siblings) do
            -- Add the start line of each preceding sibling
            table.insert(contextLines, {lnum = sibling.startLine + 1})
            log.debug('ContextWin: Found target node:', target_node.startLine, 'Preceding siblings:', sibling.startLine)
        end
        target_node = parent
        parent = target_node.parent

        -- Limit the number of lines (optional, add config later)
        if #contextLines > maxLines then
            -- table.sort(contextLines, function(a, b) return a.lnum < b.lnum end)
            -- contextLines = vim.list_slice(contextLines, #contextLines - maxLines + 1, #contextLines)
            break
        end
    end

    -- Sort by line number
    table.sort(contextLines, function(a, b) return a.lnum < b.lnum end)

    -- Fetch text content
    if #contextLines > 0 then
        for _, lineInfo in ipairs(contextLines) do
            lineInfo.text = fb:lines(lineInfo.lnum)[1] -- Fetch line text
            if lineInfo.text == nil then
                log.warn('ContextWin: Failed to get text for line', lineInfo.lnum)
                return nil -- Or handle error appropriately
            end
        end
        return contextLines
    else
        return nil
    end
end

--- Builds the floating window configuration options.
---@param mainWinid number The original window ID.
---@param numLines number Number of lines to display.
---@return table Neovim float window options.
function ContextWin:_buildOpts(mainWinid, numLines)
    local mainWinfo = utils.getWinInfo(mainWinid)
    local border_cfg = type(self.border) == 'string' and defaultBorder[self.border] or self.border

    local winWidth = mainWinfo.width - mainWinfo.textoff
    local winHeight = math.min(numLines, self.config.max_height or 10) -- Use config or default max height

    -- Adjust width/height based on border
    local borderLeft = borderHasLine(border_cfg, 8)
    local borderRight = borderHasLine(border_cfg, 4)
    local borderTop = borderHasLine(border_cfg, 2)
    local borderBottom = borderHasLine(border_cfg, 6)

    if borderLeft then winWidth = winWidth - 1 end
    if borderRight then winWidth = winWidth - 1 end
    if borderTop then winHeight = winHeight - 1 end
    if borderBottom then winHeight = winHeight - 1 end
    winWidth = math.max(1, winWidth)
    winHeight = math.max(1, winHeight)

    self.width = winWidth
    self.height = winHeight

    -- Calculate position (above cursor)
    local row = -self.height
    if borderTop then row = row - 1 end
    if borderBottom then row = row - 1 end -- This seems counter-intuitive for 'SW' anchor but might be needed depending on how border affects height calc. Test needed.
    -- Let's assume the height already accounts for borders for positioning initially.
    row = -numLines                        -- Place top border just above cursor line
    if borderTop then row = row - 1 end

    local col = 0
    if borderLeft then col = col - 1 end

    return {
        relative = 'cursor',
        anchor = 'SW',     -- South-West: Bottom-left corner relative to cursor
        width = self.width,
        height = numLines, -- Use actual numLines for initial height request
        row = row,
        col = col,
        border = border_cfg,
        style = 'minimal',
        focusable = false, -- Usually context windows aren't focusable
        zindex = self.config.zindex or 100,
        noautocmd = true,
    }
end

--- Creates or retrieves the buffer for the context window.
function ContextWin:_getBufnr()
    if self.bufnr and utils.isBufLoaded(self.bufnr) then
        return self.bufnr
    end
    local bufnr = fn.bufnr('^' .. self.bufferName .. '$')
    if bufnr > 0 then
        self.bufnr = bufnr
    else
        self.bufnr = api.nvim_create_buf(false, true) -- no list, scratch
        api.nvim_buf_set_name(self.bufnr, self.bufferName)
        vim.bo[self.bufnr].bufhidden = 'hide'
        vim.bo[self.bufnr].swapfile = false
        vim.bo[self.bufnr].buftype = 'nofile'
        vim.bo[self.bufnr].filetype = 'ufo-context' -- Set a unique filetype if needed
    end
    return self.bufnr
end

--- Opens or updates the context window.
---@param originalWinid number
---@param linesInfo table[] list of {lnum: number, text: string}
function ContextWin:open(originalWinid, linesInfo)
    self:close() -- Close existing first
    self.originalWinid = originalWinid
    local originalBufnr = api.nvim_win_get_buf(originalWinid)

    local numLines = #linesInfo
    if numLines == 0 then return end

    local opts = self:_buildOpts(originalWinid, numLines)
    local contextBufnr = self:_getBufnr()

    -- Set buffer content
    local linesText = vim.tbl_map(function(info) return info.text end, linesInfo)
    vim.bo[contextBufnr].modifiable = true
    api.nvim_buf_set_lines(contextBufnr, 0, -1, true, linesText)
    vim.bo[contextBufnr].modifiable = false

    -- Open the window
    self.winid = api.nvim_open_win(contextBufnr, false, opts) -- false: do not enter

    if not self.winid then
        log.error('ContextWin: Failed to open window.')
        return
    end

    -- Apply window options
    local wo = vim.wo[self.winid]
    wo.wrap = false
    wo.spell = false
    wo.list = false
    wo.number = false
    wo.relativenumber = false
    wo.cursorline = false
    wo.cursorcolumn = false
    wo.signcolumn = 'no'
    wo.colorcolumn = ''
    wo.foldenable = false
    wo.winblend = self.config.winblend or 0
    wo.winhighlight = self.config.winhighlight or 'Normal:Normal' -- Example config

    -- Copy relevant options from original buffer/window
    vim.bo[contextBufnr].tabstop = vim.bo[originalBufnr].tabstop
    vim.bo[contextBufnr].shiftwidth = vim.bo[originalBufnr].shiftwidth
    vim.bo[contextBufnr].expandtab = vim.bo[originalBufnr].expandtab

    -- Apply highlighting
    self:_applyHighlight(originalBufnr, linesInfo)

    -- Setup autocmds for closing
    self:_setupAutoClose()
end

--- Applies highlighting from original buffer to context window.
---@param originalBufnr number
---@param linesInfo table[] list of {lnum: number, text: string}
function ContextWin:_applyHighlight(originalBufnr, linesInfo)
    if not self.winid or not self.bufnr then return end

    api.nvim_buf_clear_namespace(self.bufnr, self.ns, 0, -1)

    local nss = {} -- Namespaces to copy highlights from
    for _, namespace in pairs(api.nvim_get_namespaces()) do
        -- Maybe exclude UFO's own main namespace if it causes issues?
        -- if ns ~= namespace then
        table.insert(nss, namespace)
        -- end
    end

    local concealLevel = vim.wo[self.originalWinid].conceallevel
    local syntaxEnabled = vim.bo[originalBufnr].syntax ~= ''

    for contextLineIdx, lineInfo in ipairs(linesInfo) do
        local originalLnum = lineInfo.lnum    -- 1-based
        local contextRow = contextLineIdx - 1 -- 0-based row in context buffer
        local lineText = lineInfo.text
        local lineLen = #lineText

        if lineLen == 0 then goto continue end -- Skip empty lines

        -- Capture highlights (adapting render.captureVirtText logic)
        local extMarks, inlayMarks = extmark.getHighlightsAndInlayByRange(
            originalBufnr,
            {originalLnum - 1, 0},
            {originalLnum - 1, lineLen}, nss)
        local tsMarks = treesitter.getHighlightsByRange(
            originalBufnr,
            {originalLnum - 1, 0},
            {originalLnum - 1, lineLen})

        -- Combine and apply Extmark/Treesitter highlights
        local allMarks = {}
        vim.list_extend(allMarks, extMarks)
        vim.list_extend(allMarks, tsMarks)

        for _, markInfo in ipairs(allMarks) do
            local sr, sc, er, ec, hlGroup, priority, conceal = markInfo[1], markInfo[2], markInfo[3], markInfo[4],
                markInfo[5], markInfo[6], markInfo[7]
            if sr == originalLnum - 1 then -- Only apply if the mark starts on the correct line
                -- Adjust row/col for context buffer
                local contextEndRow = contextRow + (er - sr)
                extmark.setHighlight(self.bufnr, self.ns, contextRow, sc, contextEndRow, ec, hlGroup, priority)
            end
        end

        -- Apply Syntax highlights (simplified)
        if syntaxEnabled then
            api.nvim_buf_call(originalBufnr, function()
                local synID = fn.synID(originalLnum, 1, false) -- Get ID at start of line
                local synGroupName = synID > 0 and fn.synIDattr(synID, 'name') or nil
                if synGroupName then
                    -- Apply to whole line in context buffer for simplicity
                    extmark.setHighlight(self.bufnr, self.ns, contextRow, 0, contextRow, -1, synGroupName, 10) -- Low priority
                end
                -- A more accurate approach would iterate cols like captureVirtText,
                -- but might be overkill for context display.
            end)
        end

        -- Apply Inlay hints (might look weird, consider omitting)
        if self.config.show_inlay_hints then -- Add config option
            for _, inlayInfo in ipairs(inlayMarks) do
                local sr, sc, virtText, priority = inlayInfo[1], inlayInfo[2], inlayInfo[3], inlayInfo[4]
                if sr == originalLnum - 1 then
                    extmark.setVirtText(self.bufnr, self.ns, contextRow, sc, virtText,
                        {priority = priority, virt_text_pos = 'inline'})
                end
            end
        end

        ::continue::
    end
end

--- Sets up autocommands to automatically close the context window.
function ContextWin:_setupAutoClose()
    if self.disposables then
        disposable.disposeAll(self.disposables) -- Clear previous autocmds
    end
    self.disposables = {}

    local group = api.nvim_create_augroup('UfoContextWinAutoClose', {clear = true})

    -- Close on cursor move in original window
    api.nvim_create_autocmd('CursorMoved', {
        group = group,
        buffer = api.nvim_win_get_buf(self.originalWinid),
        callback = function()
            self:close()
        end,
    })

    -- Close if original window is closed
    api.nvim_create_autocmd('WinClosed', {
        group = group,
        pattern = tostring(self.originalWinid),
        callback = function()
            self:close()
        end,
    })

    -- Close if original buffer is left/hidden/deleted
    api.nvim_create_autocmd({'BufLeave', 'BufHidden', 'BufDelete'}, {
        group = group,
        buffer = api.nvim_win_get_buf(self.originalWinid),
        callback = function()
            self:close()
        end,
    })

    -- Ensure group is deleted when object is disposed
    table.insert(self.disposables, disposable:create(function()
        pcall(api.nvim_del_augroup_by_id, group)
    end))
end

--- Checks if the context window is currently valid.
---@return boolean
function ContextWin:isActive()
    return self.winid and utils.isWinValid(self.winid)
end

--- Closes the context window.
function ContextWin:close()
    if self:isActive() then
        pcall(api.nvim_win_close, self.winid, true) -- true: force close
    end
    if self.disposables then
        disposable.disposeAll(self.disposables)
        self.disposables = nil
    end
    self.winid = nil
    self.originalWinid = nil
    -- Don't delete the buffer immediately, it might be reused.
    -- Consider adding cleanup logic if buffer becomes unused for a while.
end

--- Initializes the ContextWin manager.
---@param ns number Namespace ID for highlights.
---@param cfg table Configuration table.
function ContextWin:initialize(ns, cfg)
    self.ns = ns
    self.config = cfg or {}                      -- Store user config
    self.bufferName = 'UfoContextWindow'
    self.border = self.config.border or 'single' -- Default border
    self.winid = nil
    self.bufnr = nil
    self.originalWinid = nil
    self.disposables = nil
    log.debug('ContextWin initialized')
    return self
end

--- Cleans up resources.
function ContextWin:dispose()
    self:close()
    if self.bufnr then
        -- Optional: Force delete buffer if no longer needed
        -- pcall(api.nvim_buf_delete, self.bufnr, { force = true })
        self.bufnr = nil
    end
    log.debug('ContextWin disposed')
end

-- Singleton instance
local instance = nil

--- Get the singleton instance or create it.
---@param ns? number
---@param cfg? table
---@return UfoContextWin
function ContextWin.get_instance(ns, cfg)
    if not instance then
        instance = setmetatable({}, ContextWin)
        instance:initialize(ns, cfg)
    end
    -- Update config if provided later
    if cfg and instance.config ~= cfg then
        instance.config = cfg
        instance.border = instance.config.border or 'single'
    end
    return instance
end

return ContextWin
