local M = {}
local util = require("codex.util")

local function label(thread)
  local title = util.value(thread.name) or util.value(thread.preview) or "[untitled]"
  return ("%s  %s"):format(tostring(util.value(thread.id) or ""), tostring(title):gsub("\n", " "))
end

M._label = label

function M.threads()
  require("codex").list_threads(function(threads)
    if #threads == 0 then
      vim.notify("No Codex threads for this workspace", vim.log.levels.INFO, { title = "codex.nvim" })
      return
    end

    local ok, snacks = pcall(require, "snacks")
    if ok and snacks.picker then
      snacks.picker.pick({
        title = "Codex Threads",
        items = vim.tbl_map(function(thread)
          return {
            text = label(thread),
            thread = thread,
          }
        end, threads),
        format = function(item)
          return { { item.text } }
        end,
        confirm = function(picker, item)
          picker:close()
          require("codex").resume(item.thread.id)
        end,
      })
      return
    end

    vim.ui.select(threads, {
      prompt = "Codex threads",
      format_item = label,
    }, function(thread)
      if thread then
        require("codex").resume(thread.id)
      end
    end)
  end)
end

return M
