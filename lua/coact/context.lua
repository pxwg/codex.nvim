local M = {}

local hooks = {}
local image_exts = {
  bmp = true,
  gif = true,
  heic = true,
  jpeg = true,
  jpg = true,
  png = true,
  tif = true,
  tiff = true,
  webp = true,
}
local selection_state = {
  by_bufnr = {},
  latest = nil,
}
local selection_augroup = nil
local blockwise_visual_mode = "\022"

local function normalize_bufnr(bufnr)
  if bufnr == nil or bufnr == 0 then
    return vim.api.nvim_get_current_buf()
  end
  return bufnr
end

function M.is_coact_buffer(bufnr)
  bufnr = normalize_bufnr(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  local filetype = vim.bo[bufnr].filetype
  return vim.b[bufnr].coact_thread_id ~= nil
    or filetype == "coact"
    or filetype == "coact-history"
    or filetype == "coact-input"
    or name:match("^coact://") ~= nil
end

function M.is_context_buffer(bufnr)
  bufnr = normalize_bufnr(bufnr)
  return vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) and not M.is_coact_buffer(bufnr)
end

function M.capture_thread_buffer(thread, bufnr, winid)
  if not thread then
    return
  end
  bufnr = normalize_bufnr(bufnr)
  if not M.is_context_buffer(bufnr) then
    return
  end
  thread.context_bufnr = bufnr
  if winid and vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
    thread.context_winid = winid
  else
    local current_win = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_is_valid(current_win) and vim.api.nvim_win_get_buf(current_win) == bufnr then
      thread.context_winid = current_win
    end
  end
end

local function active_thread()
  local state = require("coact.state")
  return state.thread_for_buf(0) or state.get_thread(state.active_thread_id)
end

function M.target_buffer(thread)
  thread = thread or active_thread()
  if thread and thread.context_bufnr and M.is_context_buffer(thread.context_bufnr) then
    return thread.context_bufnr
  end

  local current = vim.api.nvim_get_current_buf()
  if M.is_context_buffer(current) then
    return current
  end

  return current
end

function M.window_for_buffer(bufnr, thread)
  bufnr = normalize_bufnr(bufnr)
  if thread and thread.context_winid and vim.api.nvim_win_is_valid(thread.context_winid) then
    if vim.api.nvim_win_get_buf(thread.context_winid) == bufnr then
      return thread.context_winid
    end
  end

  local current_win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_is_valid(current_win) and vim.api.nvim_win_get_buf(current_win) == bufnr then
    return current_win
  end

  for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
      return winid
    end
  end
  return nil
end

function M.cursor_for_buffer(bufnr, thread)
  bufnr = normalize_bufnr(bufnr)
  local winid = M.window_for_buffer(bufnr, thread)
  if winid then
    return vim.api.nvim_win_get_cursor(winid)
  end
  return { 1, 0 }
end

function M.buffer_label(bufnr)
  bufnr = normalize_bufnr(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  return name ~= "" and name or "[No Name]"
end

function M.display_path(path)
  path = vim.fs.normalize(vim.fn.expand(tostring(path or "")))
  local rel = vim.fn.fnamemodify(path, ":.")
  if rel ~= "" and rel ~= path and not rel:match("^%.%./") then
    path = rel
  end
  if path:find("%s") then
    return "`" .. path:gsub("`", "\\`") .. "`"
  end
  return path
end

local function selection_type(mode)
  local first = tostring(mode or ""):sub(1, 1)
  if first == "v" or first == "V" or first == blockwise_visual_mode then
    return first
  end
  return nil
end

local function selection_marks(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil, nil
  end
  local start_mark = vim.api.nvim_buf_get_mark(bufnr, "<")
  local end_mark = vim.api.nvim_buf_get_mark(bufnr, ">")
  if start_mark[1] == 0 or end_mark[1] == 0 then
    return nil, nil
  end
  return start_mark, end_mark
end

local function mark_copy(mark)
  return { mark[1], mark[2] }
end

local function mark_equal(left, right)
  return left and right and left[1] == right[1] and left[2] == right[2]
end

local function cached_marks_equal(selection, start_mark, end_mark)
  return mark_equal(selection and selection.mark_start, start_mark)
    and mark_equal(selection and selection.mark_end, end_mark)
end

local function ordered_marks(start_mark, end_mark)
  if start_mark[1] > end_mark[1] or (start_mark[1] == end_mark[1] and start_mark[2] > end_mark[2]) then
    return end_mark, start_mark
  end
  return start_mark, end_mark
end

local function call_in_buffer_window(bufnr, winid, callback)
  if winid and vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
    return pcall(vim.api.nvim_win_call, winid, callback)
  end
  local found = M.window_for_buffer(bufnr)
  if found then
    return pcall(vim.api.nvim_win_call, found, callback)
  end
  return pcall(callback)
end

local function visualmode_for_buffer(bufnr, winid)
  local ok, mode = call_in_buffer_window(bufnr, winid, function()
    return vim.fn.visualmode()
  end)
  if ok then
    return selection_type(mode)
  end
  return nil
end

local function line_range(start_mark, end_mark)
  local start_line = start_mark[1]
  local end_line = end_mark[1]
  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end
  return start_line, end_line
end

local function full_line_region(bufnr, start_line, end_line)
  local ok, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, start_line - 1, end_line, false)
  if ok and #lines > 0 then
    return lines
  end
  return nil
end

local function buffer_line(bufnr, lnum)
  local ok, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, lnum - 1, lnum, false)
  if ok then
    return lines[1] or ""
  end
  return ""
end

local function manual_get_text(bufnr, start_line, start_col, end_line, end_col)
  local ok, lines = pcall(vim.api.nvim_buf_get_text, bufnr, start_line - 1, start_col, end_line - 1, end_col, {})
  if ok and #lines > 0 then
    return lines
  end
  return nil
end

local function manual_region_lines(bufnr, start_mark, end_mark, kind)
  if kind == "V" then
    local start_line, end_line = start_mark[1], end_mark[1]
    if start_line > end_line then
      start_line, end_line = end_line, start_line
    end
    return full_line_region(bufnr, start_line, end_line)
  end

  if kind == blockwise_visual_mode then
    local start_line, end_line = start_mark[1], end_mark[1]
    if start_line > end_line then
      start_line, end_line = end_line, start_line
    end
    local start_col = math.min(start_mark[2], end_mark[2])
    local end_col = math.max(start_mark[2], end_mark[2]) + 1
    local lines = {}
    for lnum = start_line, end_line do
      local line = buffer_line(bufnr, lnum)
      local clamped_start = math.min(start_col, #line)
      local clamped_end = math.max(clamped_start, math.min(end_col, #line))
      local segment = manual_get_text(bufnr, lnum, clamped_start, lnum, clamped_end)
      table.insert(lines, segment and segment[1] or "")
    end
    return lines
  end

  if kind == "v" then
    local range_start, range_end = ordered_marks(start_mark, end_mark)
    local start_line_text = buffer_line(bufnr, range_start[1])
    local end_line_text = buffer_line(bufnr, range_end[1])
    local start_col = math.min(range_start[2], #start_line_text)
    local end_col = math.min(range_end[2] + 1, #end_line_text)
    if range_start[1] == range_end[1] then
      end_col = math.max(start_col, end_col)
    end
    return manual_get_text(bufnr, range_start[1], start_col, range_end[1], end_col)
  end

  return nil
end

local function region_lines(bufnr, start_mark, end_mark, mode, winid)
  local kind = selection_type(mode)
  if not kind then
    return nil
  end
  if vim.fn.exists("*getregion") == 1 then
    local start_pos = { bufnr, start_mark[1], start_mark[2] + 1, 0 }
    local end_pos = { bufnr, end_mark[1], end_mark[2] + 1, 0 }
    local ok, lines = call_in_buffer_window(bufnr, winid, function()
      return vim.fn.getregion(start_pos, end_pos, { type = kind })
    end)
    if ok and type(lines) == "table" and #lines > 0 then
      return lines
    end
  end
  return manual_region_lines(bufnr, start_mark, end_mark, kind)
end

local function blank_text(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "") == ""
end

local function selection_from_marks(bufnr, mode, winid)
  bufnr = normalize_bufnr(bufnr)
  if not M.is_context_buffer(bufnr) then
    return nil
  end

  local start_mark, end_mark = selection_marks(bufnr)
  if not start_mark or not end_mark then
    return nil
  end

  local start_line, end_line = line_range(start_mark, end_mark)
  local lines = region_lines(bufnr, start_mark, end_mark, mode, winid) or full_line_region(bufnr, start_line, end_line)
  if not lines then
    return nil
  end

  local content = table.concat(lines, "\n")
  if blank_text(content) then
    return nil
  end

  local range_start, range_end = ordered_marks(start_mark, end_mark)
  return {
    bufnr = bufnr,
    start_line = start_line,
    end_line = end_line,
    start_col = range_start[2] + 1,
    end_col = range_end[2] + 1,
    mark_start = mark_copy(start_mark),
    mark_end = mark_copy(end_mark),
    mode = selection_type(mode),
    filename = M.buffer_label(bufnr),
    filetype = vim.bo[bufnr].filetype,
    changedtick = vim.b[bufnr].changedtick,
    content = content,
  }
end

local function clone_selection(selection)
  if not selection then
    return nil
  end
  return vim.deepcopy(selection)
end

local function clear_selection(bufnr)
  bufnr = normalize_bufnr(bufnr)
  selection_state.by_bufnr[bufnr] = nil
  if selection_state.latest and selection_state.latest.bufnr == bufnr then
    selection_state.latest = nil
  end
end

local function remember_selection(selection)
  if not selection or not selection.bufnr then
    return nil
  end
  local cached = clone_selection(selection)
  selection_state.by_bufnr[selection.bufnr] = cached
  selection_state.latest = clone_selection(selection)
  return cached
end

local function capture_selection(bufnr, mode, winid)
  local selected = selection_from_marks(bufnr, mode, winid)
  if selected then
    remember_selection(selected)
    return selected
  end
  clear_selection(bufnr)
  return nil
end

local function cached_selection(bufnr)
  local selected = selection_state.by_bufnr[bufnr]
  if selected and M.is_context_buffer(bufnr) then
    return selected
  end
  selection_state.by_bufnr[bufnr] = nil
  if selection_state.latest and selection_state.latest.bufnr == bufnr then
    selection_state.latest = nil
  end
  return nil
end

function M.selection_for_buffer(bufnr)
  bufnr = normalize_bufnr(bufnr)
  if not M.is_context_buffer(bufnr) then
    return nil
  end

  local start_mark, end_mark = selection_marks(bufnr)
  local cached = cached_selection(bufnr)
  if cached then
    local changedtick = vim.b[bufnr].changedtick
    if not start_mark or cached_marks_equal(cached, start_mark, end_mark) or changedtick ~= cached.changedtick then
      return clone_selection(cached)
    end
  end

  local selected = selection_from_marks(bufnr, visualmode_for_buffer(bufnr), nil)
  if selected then
    remember_selection(selected)
    return clone_selection(selected)
  end
  return nil
end

function M._latest_selection()
  local selected = selection_state.latest
  if selected and M.is_context_buffer(selected.bufnr) then
    return clone_selection(selected)
  end
  return nil
end

function M._capture_selection(bufnr, mode, winid)
  return clone_selection(capture_selection(bufnr, mode, winid))
end

local function workspace_files(kind)
  local config = require("coact.config")
  local cwd = config.cwd()
  local files = {}
  if vim.fn.executable("rg") == 1 and vim.system then
    local result = vim.system({ "rg", "--files", "--hidden", "-g", "!.git" }, { cwd = cwd, text = true }):wait()
    if result and result.code == 0 then
      files = vim.split(result.stdout or "", "\n", { plain = true, trimempty = true })
    end
  end
  if #files == 0 then
    for _, path in ipairs(vim.fn.globpath(cwd, "**/*", false, true)) do
      if vim.fn.filereadable(path) == 1 then
        table.insert(files, vim.fn.fnamemodify(path, ":."))
      end
    end
  end
  if kind == "image" then
    files = vim.tbl_filter(function(path)
      local ext = tostring(path):match("%.([^./\\]+)$")
      return ext and image_exts[ext:lower()] or false
    end, files)
  end
  table.sort(files)
  return files
end

local function token_before_cursor()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local line = vim.api.nvim_get_current_line()
  local before = line:sub(1, col)
  local start_col, end_col, token, name, arg = before:find("(@([%w_./~%-]+):(.*))$")
  if not name and col < #line then
    before = line:sub(1, col + 1)
    start_col, end_col, token, name, arg = before:find("(@([%w_./~%-]+):(.*))$")
  end
  if not name then
    return nil
  end
  return {
    token = token,
    name = name,
    arg = arg or "",
    row = row,
    start_col = start_col - 1,
    end_col = end_col,
  }
end

local function replace_context_token(bufnr, range, text)
  vim.api.nvim_buf_set_text(bufnr, range.row - 1, range.start_col, range.row - 1, range.end_col, { text })
  for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(winid) then
      vim.api.nvim_win_set_cursor(winid, { range.row, range.start_col + #text })
      return
    end
  end
end

local function context_replacement(payload, path)
  if payload.name == "image" then
    return "@image:" .. M.display_path(path)
  end
  return "@" .. M.display_path(path)
end

local function snacks_item_path(item, cwd)
  if not item then
    return nil
  end
  local ok, picker_util = pcall(require, "snacks.picker.util")
  if ok and picker_util.path then
    local path = picker_util.path(item)
    if path and path ~= "" then
      return path
    end
  end
  local file = item.file or item.path or item.text
  if not file or file == "" then
    return nil
  end
  if file:match("^/") or file:match("^%a:[/\\]") then
    return file
  end
  return vim.fs.joinpath(item.cwd or cwd, file)
end

local function snacks_pick_path(payload)
  local ok, snacks = pcall(require, "snacks")
  if not (ok and snacks.picker and snacks.picker.files) then
    return false
  end

  local cwd = require("coact.config").cwd()
  local opts = {
    cwd = cwd,
    hidden = true,
    title = payload.name == "image" and "Coact Image Context" or "Coact File Context",
    confirm = function(picker, item)
      picker:close()
      local path = snacks_item_path(item, cwd)
      if not path then
        return
      end
      replace_context_token(payload.bufnr, payload.range, context_replacement(payload, path))
    end,
  }
  if payload.name == "image" then
    opts.ft = vim.tbl_keys(image_exts)
  end
  snacks.picker.files(opts)
  return true
end

local function select_pick_path(payload)
  local files = workspace_files(payload.name)
  if #files == 0 then
    vim.notify("No files found for Coact context", vim.log.levels.WARN, { title = "coact.nvim" })
    return
  end
  vim.ui.select(files, {
    prompt = payload.name == "image" and "Coact image context" or "Coact file context",
  }, function(choice)
    if not choice then
      return
    end
    replace_context_token(payload.bufnr, payload.range, context_replacement(payload, choice))
  end)
end

local function pick_path(payload)
  if snacks_pick_path(payload) then
    return
  end
  select_pick_path(payload)
end

hooks.file = pick_path
hooks.image = pick_path

function M.register_hook(name, callback)
  hooks[name] = callback
end

function M.trigger_hook()
  local token = token_before_cursor()
  if not token then
    return false
  end
  local callback = hooks[token.name]
  if not callback then
    return false
  end
  local payload = {
    name = token.name,
    arg = token.arg,
    bufnr = vim.api.nvim_get_current_buf(),
    range = {
      row = token.row,
      start_col = token.start_col,
      end_col = token.end_col,
    },
  }
  vim.schedule(function()
    callback(payload)
  end)
  return true
end

function M.setup()
  selection_augroup = vim.api.nvim_create_augroup("coact.nvim.context", { clear = true })
  vim.api.nvim_create_autocmd("ModeChanged", {
    group = selection_augroup,
    callback = function()
      local event = vim.v.event or {}
      local old_mode = event.old_mode
      local new_mode = event.new_mode
      local mode = selection_type(old_mode)
      if not mode or selection_type(new_mode) then
        return
      end

      local bufnr = vim.api.nvim_get_current_buf()
      if not M.is_context_buffer(bufnr) then
        return
      end
      local winid = vim.api.nvim_get_current_win()
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
          capture_selection(bufnr, mode, winid)
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = selection_augroup,
    callback = function(event)
      if event and event.buf then
        clear_selection(event.buf)
      end
    end,
  })
end

M._workspace_files = workspace_files
M._token_before_cursor = token_before_cursor
M._snacks_item_path = snacks_item_path

return M
