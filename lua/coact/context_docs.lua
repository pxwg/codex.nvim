local M = {}

local parser = require("coact.parser")
local state = require("coact.state")

local function input_preview(input)
  if type(input) ~= "table" then
    return nil
  end
  if input.type == "text" then
    return input.text
  end
  if input.type == "localImage" then
    return table.concat({
      "Image context that will be attached:",
      "- type: localImage",
      "- path: " .. tostring(input.path or ""),
    }, "\n")
  end
  if input.type == "image" then
    return table.concat({
      "Image context that will be attached:",
      "- type: image",
      "- url: " .. tostring(input.url or ""),
    }, "\n")
  end
  return vim.inspect(input)
end

function M.documentation_for_token(token, opts)
  token = tostring(token or "")
  if token == "" then
    return nil
  end

  opts = opts or {}
  local thread = opts.thread or (opts.bufnr and state.thread_for_buf(opts.bufnr)) or nil
  local resolved_ok, payload = pcall(parser._resolve_context_payload, token, { thread = thread })
  if not resolved_ok or type(payload) ~= "table" or type(payload.inputs) ~= "table" or #payload.inputs == 0 then
    return nil
  end
  if type(payload.documentation) == "string" and payload.documentation ~= "" then
    return payload.documentation
  end

  local lines = {
    "Context preview for " .. token,
    "",
    "This is what coact.nvim will inject when this token is submitted:",
    "",
  }
  for index, input in ipairs(payload.inputs) do
    if index > 1 then
      table.insert(lines, "")
    end
    table.insert(lines, input_preview(input) or vim.inspect(input))
  end
  return table.concat(lines, "\n")
end

local function scan_context_tokens(line)
  local tokens = {}
  local index = 1
  while index <= #line do
    local char = line:sub(index, index)
    if char == "@" or char == ">" then
      local token_start = index
      local cursor = index
      local in_backtick = false
      while cursor <= #line do
        local current = line:sub(cursor, cursor)
        if current == "`" then
          in_backtick = not in_backtick
        elseif not in_backtick and current:match("%s") then
          break
        end
        cursor = cursor + 1
      end
      local token = line:sub(token_start, cursor - 1)
      if parser._parse_context_token(token) then
        table.insert(tokens, {
          token = token,
          start_col = token_start - 1,
          end_col = cursor - 1,
        })
      end
      index = math.max(cursor, token_start + 1)
    else
      index = index + 1
    end
  end
  return tokens
end

function M.token_under_cursor(winid)
  winid = winid or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(winid) then
    return nil
  end
  local bufnr = vim.api.nvim_win_get_buf(winid)
  local row, col = unpack(vim.api.nvim_win_get_cursor(winid))
  local line = (vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false) or {})[1] or ""
  for _, entry in ipairs(scan_context_tokens(line)) do
    if col >= entry.start_col and col < entry.end_col then
      return entry.token, entry
    end
  end
  return nil
end

function M.hover(opts)
  opts = opts or {}
  local winid = opts.winid or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(winid) then
    return false
  end
  local bufnr = opts.bufnr or vim.api.nvim_win_get_buf(winid)
  local token = opts.token or M.token_under_cursor(winid)
  if not token then
    return false
  end

  local documentation = M.documentation_for_token(token, {
    bufnr = bufnr,
    thread = opts.thread,
  })
  if not documentation or documentation == "" then
    return false
  end

  local lines = vim.split(documentation, "\n", { plain = true })
  local float_opts = vim.tbl_deep_extend("force", opts.float or {}, {
    focus_id = "textDocument/hover",
  })
  vim.lsp.util.open_floating_preview(lines, "markdown", float_opts)
  return true
end

M._scan_context_tokens = scan_context_tokens

return M
