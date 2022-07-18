local ot = {}
local api, lsp = vim.api, vim.lsp
local symbar = require('lspsaga.symbolwinbar')
local cache = symbar.symbol_cache
local kind = require('lspsaga.lspkind')
local hi_prefix = 'LSOutline'
local space = '  '
local window = require('lspsaga.window')
local libs = require('lspsaga.libs')
local group = require('lspsaga').saga_group
local config = require('lspsaga').config_values
local max_preview_lines = config.max_preview_lines
local outline_conf = config.show_outline
local method = 'textDocument/documentSymbol'

local function nodes_with_icon(tbl, nodes, hi_tbl, level)
  local current_buf = api.nvim_get_current_buf()
  local icon, hi, line = '', '', ''

  for _, node in pairs(tbl) do
    level = level or 1
    icon = kind[node.kind][2]
    hi = hi_prefix .. kind[node.kind][1]
    local indent = string.rep(space, level)

    -- I think no need to show function param
    if node.kind ~= 14 then
      line = indent .. icon .. node.name
      table.insert(nodes, line)
      table.insert(hi_tbl, hi)
      if ot[current_buf].preview_contents == nil then
        ot[current_buf].preview_contents = {}
        ot[current_buf].link = {}
        ot[current_buf].details = {}
      end
      local range = node.location ~= nil and node.location.range or node.range
      local _end_line = range['end'].line + 1
      local content = api.nvim_buf_get_lines(current_buf, range.start.line, _end_line, false)
      table.insert(ot[current_buf].preview_contents, content)
      table.insert(ot[current_buf].link, { range.start.line + 1, range.start.character })
      table.insert(ot[current_buf].details, node.detail)
    end

    if node.children ~= nil and next(node.children) ~= nil then
      nodes_with_icon(node.children, nodes, hi_tbl, level + 1)
    end
  end
end

local function get_all_nodes(ctx)
  local symbols = next(ctx) ~= nil and ctx.symbols or {}
  local nodes, hi_tbl = {}, {}
  local current_buf = api.nvim_get_current_buf()
  if cache[current_buf] ~= nil and next(cache[current_buf][2]) ~= nil then
    symbols = cache[current_buf][2]
  end

  nodes_with_icon(symbols, nodes, hi_tbl)

  return nodes, hi_tbl
end

local function set_local()
  local local_options = {
    bufhidden = 'wipe',
    number = false,
    relativenumber = false,
    filetype = 'lspsagaoutline',
    buftype = 'nofile',
    wrap = false,
    signcolumn = 'no',
    matchpairs = '',
    buflisted = false,
    list = false,
    spell = false,
    cursorcolumn = false,
    cursorline = false,
    foldmethod = 'expr',
    foldexpr = "v:lua.require'lspsaga.outline'.set_fold()",
    foldtext = "v:lua.require'lspsaga.outline'.set_foldtext()",
    fillchars = { eob = '-', fold = ' ' },
  }
  for opt, val in pairs(local_options) do
    vim.opt_local[opt] = val
  end
end

local function gen_outline_hi()
  for _, v in pairs(kind) do
    api.nvim_set_hl(0, hi_prefix .. v[1], { fg = v[3] })
  end
end

function ot.set_foldtext()
  local line = vim.fn.getline(vim.v.foldstart)
  return outline_conf.fold_prefix .. line
end

function ot.set_fold()
  local cur_indent = vim.fn.indent(vim.v.lnum)
  local next_indent = vim.fn.indent(vim.v.lnum + 1)

  if cur_indent == next_indent then
    return (cur_indent / vim.bo.shiftwidth) - 1
  elseif next_indent < cur_indent then
    return (cur_indent / vim.bo.shiftwidth) - 1
  elseif next_indent > cur_indent then
    return '>' .. (next_indent / vim.bo.shiftwidth) - 1
  end
end

local virt_id = api.nvim_create_namespace('lspsaga_outline')
local virt_hi = { 'OutlineIndentOdd', 'OutlineIndentEvn' }

function ot:fold_virt_text(tbl)
  local level, col = 0, 0
  local virt_with_hi = {}
  for index, _ in pairs(tbl) do
    level = vim.fn.foldlevel(index)
    if level > 0 then
      for i = 1, level do
        if bit.band(i, 1) == 1 then
          col = i == 1 and i - 1 or col + 2
          virt_with_hi = { { outline_conf.virt_text, virt_hi[1] } }
        else
          col = col + 2
          virt_with_hi = { { outline_conf.virt_text, virt_hi[2] } }
        end

        api.nvim_buf_set_extmark(0, virt_id, index - 1, col, {
          virt_text = virt_with_hi,
          virt_text_pos = 'overlay',
          virt_lines_above = false,
        })
      end
    end
  end
end

function ot:detail_virt_text(bufnr)
  for i, detail in pairs(self[bufnr].details) do
    api.nvim_buf_set_extmark(0, virt_id, i - 1, 0, {
      virt_text = { { detail, 'OutlineDetail' } },
      virt_text_pos = 'eol',
    })
  end
end

function ot:auto_preview(bufnr)
  if self[bufnr] == nil and next(self[bufnr]) == nil then
    return
  end

  local ok, preview_data = pcall(api.nvim_win_get_var, 0, 'outline_preview_win')
  if ok then
    window.nvim_close_valid_window(preview_data[2])
  end

  local current_line = api.nvim_win_get_cursor(0)[1]
  local content = self[bufnr].preview_contents[current_line]

  local WIN_WIDTH = api.nvim_get_option('columns')
  local max_width = math.floor(WIN_WIDTH * 0.5)
  local max_height = #content

  if max_height > max_preview_lines then
    max_height = max_preview_lines
  end

  local opts = {
    relative = 'editor',
    style = 'minimal',
    height = max_height,
    width = max_width,
  }

  local winid = vim.fn.bufwinid(bufnr)
  local _height = vim.fn.winheight(winid)

  if outline_conf.win_position == 'right' then
    opts.anchor = 'NE'
    opts.col = WIN_WIDTH - outline_conf.win_width - 1
    opts.row = vim.fn.winline()
  else
    opts.anchor = 'NW'
    opts.col = outline_conf.win_width + 1
    local win_height = vim.fn.winheight(0)
    if win_height < _height then
      opts.row = (_height - win_height) + vim.fn.winline()
    else
      opts.row = vim.fn.winline()
    end
  end

  local content_opts = {
    contents = content,
    filetype = self[bufnr].ft,
    highlight = 'LSOutlinePreviewBorder',
  }

  local preview_bufnr, preview_winid = window.create_win_with_border(content_opts, opts)
  api.nvim_win_set_var(0, 'outline_preview_win', { preview_bufnr, preview_winid })

  local events = { 'CursorMoved', 'BufLeave' }
  local outline_bufnr = api.nvim_get_current_buf()
  vim.defer_fn(function()
    libs.close_preview_autocmd(outline_bufnr, preview_winid, events)
  end, 0)
end

function ot:jump_to_line(bufnr)
  local current_line = api.nvim_win_get_cursor(0)[1]
  local pos = self[bufnr].link[current_line]
  local win = vim.fn.win_findbuf(bufnr)[1]
  api.nvim_set_current_win(win)
  api.nvim_win_set_cursor(win, pos)
end

function ot:render_status()
  self.winid = api.nvim_get_current_win()
  print(api.nvim_get_current_buf())
  self.winbuf = api.nvim_get_current_buf()
  self.status = true
end

local create_outline_window = function()
  if outline_conf.win_position == 'right' then
    vim.cmd('noautocmd vsplit')
    vim.cmd('vertical resize ' .. config.show_outline.win_width)
    return
  end

  local user_option = vim.opt.splitright:get()

  if user_option then
    vim.opt.splitright = false
  end

  if string.len(outline_conf.left_with) > 0 then
    local ok, sp_buf = libs.find_buffer_by_filetype(outline_conf.left_with)

    if ok then
      local winid = vim.fn.win_findbuf(sp_buf)[1]
      api.nvim_set_current_win(winid)
      vim.cmd('noautocmd sp vnew')
      return
    end
  end

  vim.cmd('noautocmd vsplit')
  vim.cmd('vertical resize ' .. config.show_outline.win_width)
  vim.opt.splitright = user_option
end

---@private
local do_symbol_request = function(ctx)
  ctx = ctx or {}
  local bufnr = ctx ~= nil and ctx.bufnr or api.nvim_get_current_buf()
  local params = { textDocument = lsp.util.make_text_document_params(bufnr) }
  lsp.buf_request_all(0, method, params, function(result)
    if libs.result_isempty(result) then
      return
    end

    local client_id = symbar.get_clientid()

    local symbols = result[client_id].result
    ctx.symbols = symbols
    ot:update_outline(ctx)
  end)
end

function ot:update_outline(ctx)
  ctx = ctx or {}
  local current_buf = api.nvim_get_current_buf()
  self[current_buf] = { ft = vim.bo.filetype }

  local nodes, hi_tbl = get_all_nodes(ctx)
  --   vim.notify(vim.inspect(symbols))

  gen_outline_hi()

  local win, buf

  if self.winid == nil then
    create_outline_window()
    win = vim.api.nvim_get_current_win()
    buf = vim.api.nvim_create_buf(true, true)
    api.nvim_win_set_buf(win, buf)
  else
    win = self.winid
    buf = self.winbuf
  end

  self:render_status()

  set_local()

  api.nvim_buf_set_lines(buf, 0, -1, false, nodes)

  self:fold_virt_text(nodes)

  self:detail_virt_text(current_buf)

  api.nvim_buf_set_option(buf, 'modifiable', false)

  for i, hi in pairs(hi_tbl) do
    api.nvim_buf_add_highlight(buf, 0, hi, i - 1, 0, -1)
  end

  if outline_conf.auto_preview then
    api.nvim_create_autocmd('CursorMoved', {
      group = group,
      buffer = buf,
      callback = function()
        ot:auto_preview(current_buf)
      end,
    })
  end

  vim.keymap.set('n', outline_conf.jump_key, function()
    ot:jump_to_line(current_buf)
  end, {
    buffer = buf,
  })
end

function ot:refresh_events()
  if outline_conf.auto_refresh then
    self.refresh_au = api.nvim_create_augroup('OutlineRefresh', { clear = true })
    api.nvim_create_autocmd('BufWinEnter', {
      group = self.refresh_au,
      callback = function()
        if vim.bo.filetype ~= 'lspsagaoutline' then
          self:auto_refresh()
        end
      end,
      desc = 'Outline refresh',
    })
  end
end

function ot:remove_events()
  if outline_conf.auto_refresh then
    api.nvim_del_augroup_by_id(self.refresh_au)
    self.refresh_au = 0
  end

  if self.close_au_id ~= 0 then
    api.nvim_del_augroup_by_id(self.close_au_id)
    self.close_au_id = 0
  end
end

function ot:close_when_latest()
  self.close_au_id = api.nvim_create_augroup('OutlineCloseEvent',{clear = true})
  api.nvim_create_autocmd('WinEnter',{
    group = self.close_au_id,
    callback = function()
      if vim.bo.filetype == 'lspsagaoutline' and vim.fn.winnr('$') == 1 then
        api.nvim_buf_delete(self.winbuf,{force = true})
      end
    end
  })
end

function ot:render_outline(ctx)
  if self.status ~= nil and self.status then
    window.nvim_close_valid_window(self.winid)
    self.winid = nil
    self.winbuf = nil
    self.status = false
    self:remove_events()
    return
  end

  if not config.symbol_in_winbar.enable and not config.symbol_in_winbar.in_custom then
    do_symbol_request(ctx)
    return
  end

  self:update_outline(ctx)
  self:refresh_events()
  self:close_when_latest()
end

function ot:auto_refresh()
  local ctx = {
    bufnr = api.nvim_get_current_buf(),
  }
  self:update_outline(ctx)
end

return ot
