local M = {}

local Allowlist = {}
Allowlist.__index = Allowlist

local function is_windows()
  return vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
end

local function path_is_absolute(path)
  return path:match("^/") ~= nil or path:match("^%a:[/\\]") ~= nil or path:match("^[/\\][/\\]") ~= nil
end

local function normalize_path(path, base)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  path = vim.fs.normalize(path)
  if not path_is_absolute(path) then
    path = vim.fs.normalize(vim.fs.joinpath(base, path))
  end
  return path
end

local function comparable_path(path, windows)
  path = vim.fs.normalize(path)
  if windows then
    path = path:gsub("\\", "/"):lower()
  end
  if path ~= "/" and not path:match("^%a:/$") then
    path = path:gsub("/+$", "")
  end
  return path
end

local function canonical_path(path, seen)
  path = vim.fs.normalize(path)
  seen = seen or {}
  if seen[path] then
    return nil
  end
  seen[path] = true

  local resolved = vim.uv.fs_realpath(path)
  if resolved then
    return vim.fs.normalize(resolved)
  end

  local suffix = {}
  local cursor = path
  while cursor and cursor ~= "" do
    local stat = vim.uv.fs_lstat(cursor)
    if stat then
      if stat.type == "link" then
        local target = vim.uv.fs_readlink(cursor)
        if not target then
          return nil
        end
        if not path_is_absolute(target) then
          target = vim.fs.joinpath(vim.fs.dirname(cursor), target)
        end
        for _, part in ipairs(suffix) do
          target = vim.fs.joinpath(target, part)
        end
        return canonical_path(target, seen)
      end

      resolved = vim.uv.fs_realpath(cursor)
      if not resolved then
        return nil
      end
      for _, part in ipairs(suffix) do
        resolved = vim.fs.joinpath(resolved, part)
      end
      return vim.fs.normalize(resolved)
    end

    local parent = vim.fs.dirname(cursor)
    if not parent or parent == cursor then
      break
    end
    local name = vim.fs.basename(cursor)
    if name and name ~= "" then
      table.insert(suffix, 1, name)
    end
    cursor = parent
  end

  return nil
end

local function is_within(path, root)
  if path == root then
    return true
  end
  local prefix = root:sub(-1) == "/" and root or (root .. "/")
  return path:sub(1, #prefix) == prefix
end

function Allowlist:add(value)
  if value == nil then
    return self
  end
  if type(value) == "table" then
    for _, path in ipairs(value) do
      self:add(path)
    end
    return self
  end
  if type(value) ~= "string" then
    error("directory allowlist entries must be strings", 2)
  end

  local lexical = normalize_path(value, self._base)
  if not lexical then
    return self
  end
  local canonical = canonical_path(lexical)
  if not canonical then
    error("directory allowlist entries must not traverse unresolved symlinks: " .. lexical, 2)
  end
  local canonical_key = comparable_path(canonical, self._windows)
  if not self._index[canonical_key] then
    local entry = {
      lexical = lexical,
      lexical_key = comparable_path(lexical, self._windows),
      canonical = canonical,
      canonical_key = canonical_key,
    }
    self._index[canonical_key] = entry
    table.insert(self._entries, entry)
  end
  return self
end

function Allowlist:remove(value)
  if value == nil then
    return self
  end
  if type(value) == "table" then
    for _, path in ipairs(value) do
      self:remove(path)
    end
    return self
  end
  if type(value) ~= "string" then
    error("directory allowlist entries must be strings", 2)
  end

  local lexical = normalize_path(value, self._base)
  if not lexical then
    return self
  end
  local lexical_key = comparable_path(lexical, self._windows)
  local canonical = canonical_path(lexical)
  local canonical_key = canonical and comparable_path(canonical, self._windows) or nil
  local kept = {}
  self._index = {}
  for _, entry in ipairs(self._entries) do
    if entry.lexical_key ~= lexical_key and entry.canonical_key ~= canonical_key then
      table.insert(kept, entry)
      self._index[entry.canonical_key] = entry
    end
  end
  self._entries = kept
  return self
end

function Allowlist:clear()
  self._entries = {}
  self._index = {}
  return self
end

function Allowlist:paths()
  local paths = {}
  for _, entry in ipairs(self._entries) do
    table.insert(paths, entry.lexical)
  end
  return paths
end

function Allowlist:contains(path)
  local lexical = normalize_path(path, self._base)
  if not lexical then
    return false
  end
  local canonical = canonical_path(lexical)
  if not canonical then
    return false
  end
  local candidate = comparable_path(canonical, self._windows)
  for _, entry in ipairs(self._entries) do
    if is_within(candidate, entry.canonical_key) then
      return true
    end
  end
  return false
end

function M.new(opts)
  opts = opts or {}
  local base = opts.base or vim.uv.cwd() or "."
  base = vim.fs.normalize(base)
  if not path_is_absolute(base) then
    base = vim.fs.normalize(vim.fs.joinpath(vim.uv.cwd() or ".", base))
  end
  return setmetatable({
    _base = base,
    _windows = is_windows(),
    _entries = {},
    _index = {},
  }, Allowlist)
end

return M
