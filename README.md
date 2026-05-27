# codex.nvim

`codex.nvim` is a Neovim client for Codex app-server. It keeps the Codex chat surface inside Neovim: each Codex thread has a buffer, thread navigation can use a picker, prompt tokens complete through `blink.cmp`, and file edits are reviewed as patch proposals in an editor-native approval window.

The plugin talks to Codex through:

```sh
codex app-server --listen stdio://
```

Codex app-server is experimental upstream, so this plugin keeps the transport layer small and explicit.

## Features

- Buffer-per-thread chat UI at `codex://thread/<id>`.
- `:Codex new`, `:Codex pick`, `:Codex resume`, `:Codex submit`, and `:Codex stop`.
- Streaming render for agent messages, reasoning, plans, command output, tool calls, and file changes.
- Patch review window for `item/fileChange/requestApproval` and legacy `applyPatchApproval`.
- Basic command and permission approval prompts.
- Optional dynamic tools exposed to Codex under the `nvim` namespace:
  - `nvim.current_buffer`
  - `nvim.diagnostics`
  - `nvim.quickfix`
- `blink.cmp` source for `/`, `$`, `@`, and `>` prompt tokens.
- Thread picker via `snacks.picker` when available, with `vim.ui.select` fallback.

## Requirements

- Neovim 0.10 or newer.
- A working `codex` executable with `app-server` support.
- Optional: `snacks.nvim` for thread picking.
- Optional: `blink.cmp` for prompt completions.

## Installation

Use your plugin manager of choice. With `lazy.nvim`:

```lua
{
  "path/to/codex.nvim",
  config = function()
    require("codex").setup()
  end,
}
```

## Setup

Default configuration:

```lua
require("codex").setup({
  app_server = {
    command = { "codex", "app-server", "--listen", "stdio://" },
    initialize_timeout_ms = 10000,
  },
  thread = {
    model = nil,
    model_provider = nil,
    service_tier = nil,
    approval_policy = "on-request",
    approvals_reviewer = "user",
    sandbox = "workspace-write",
    permissions = nil,
    developer_instructions = nil,
    base_instructions = nil,
    personality = nil,
    ephemeral = false,
  },
  ui = {
    layout = "float",
    width = 0.82,
    height = 0.82,
    sidebar_width = 0.42,
    render_delay_ms = 35,
    auto_scroll = true,
  },
  completion = {
    enabled = true,
    ttl_ms = 30000,
  },
  dynamic_tools = {
    enabled = true,
  },
})
```

## Commands

```vim
:Codex new [initial prompt]
:Codex open [thread-id]
:Codex resume <thread-id>
:Codex pick
:Codex list
:Codex submit
:Codex stop
:Codex health
:Codex restart
```

Inside a Codex thread buffer, write below `## Prompt` and press `<C-s>` to submit.

## Prompt Tokens

`codex.nvim` treats the chat buffer as the main UI surface. Prompt token completions are available through the `blink.cmp` source:

- `/new`, `/pick`, `/resume`, `/stop`, `/submit`
- `$model:<id>`, `$skill:<name>`, `$reasoning:high`
- `@file:`, `@buffer`, `@diagnostics`
- `>buffer`, `>selection`, `>diagnostics`, `>quickfix`

Configure `blink.cmp` with:

```lua
require("blink.cmp").setup({
  sources = {
    default = { "lsp", "path", "snippets", "buffer", "codex" },
    providers = {
      codex = {
        name = "Codex",
        module = "codex.completion.blink",
      },
    },
  },
})
```

`>buffer`, `>diagnostics`, and `>quickfix` are expanded into extra Codex text inputs. `$skill:<name>` is converted to a Codex skill input when the skill has been loaded into the local catalog.

## Patch Review

Codex app-server sends file edits as file-change approval requests. `codex.nvim` normalizes these into a single patch proposal model and opens a review window.

Review keys:

- `a`: accept
- `A`: accept for session
- `d`: decline
- `c`: cancel
- `q`: close the review window without answering

For modern app-server file changes, Codex still owns the final patch application after approval. For future custom editor tools, the same patch review UI can be reused with Neovim owning the final apply step.

## Architecture

The plugin follows the same shape as a native Neovim chat client:

- `lua/codex/rpc.lua`: stdio JSONL app-server client.
- `lua/codex/state.lua`: thread, turn, item, pending-request, and cache state.
- `lua/codex/core.lua`: app-server notification and server-request reducer.
- `lua/codex/buffers.lua`: `codex://thread/<id>` buffers and prompt collection.
- `lua/codex/ui/render.lua`: markdown-like rendering for thread items.
- `lua/codex/patch_review.lua`: patch proposal review UI.
- `lua/codex/completion/blink.lua`: `blink.cmp` source.
- `lua/codex/dynamic_tools.lua`: Neovim-backed dynamic tools.

## Verification

Run the smoke test:

```sh
nvim --headless -u NONE -c 'set rtp+=.' -l scripts/smoke.lua
```

The smoke test loads the plugin, exercises parser/completion behavior, and verifies app-server initialization and empty thread creation when the local `codex` executable supports it.
