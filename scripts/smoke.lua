vim.opt.runtimepath:append(".")

local codex = require("codex")
codex.setup()

local parser = require("codex.parser")
local parsed = parser.parse("hello\n>diagnostics")
assert(#parsed >= 1, "parser should produce user input")

local done = false
require("codex.completion.blink").new():get_completions({
  line = ">dia",
  cursor = { 1, 4 },
}, function(result)
  assert(#result.items == 1, "completion should return >diagnostics")
  done = true
end)
assert(done, "completion callback should run synchronously for static items")

local rpc_done = false
require("codex.rpc").start(function(err)
  assert(err == nil, err and err.message or "app-server should initialize")
  rpc_done = true
end)
vim.wait(3000, function()
  return rpc_done
end, 20)
assert(rpc_done, "app-server initialize timed out")

local thread_done = false
codex.new_thread()
vim.wait(3000, function()
  thread_done = require("codex.state").active_thread_id ~= nil
  return thread_done
end, 20)
assert(thread_done, "thread/start timed out")

require("codex.rpc").stop()
