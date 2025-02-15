-- modified version of:
-- https://github.com/vijaymarupudi/nvim-fzf/blob/master/action_helper.lua
local uv = vim.uv or vim.loop

local _is_win = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1

---@return string
local function windows_pipename()
  local tmpname = vim.fn.tempname()
  tmpname = string.gsub(tmpname, "\\", "")
  return ([[\\.\pipe\%s]]):format(tmpname)
end

local function get_preview_socket()
  local tmp = _is_win and windows_pipename() or vim.fn.tempname()
  local socket = uv.new_pipe(false)
  uv.pipe_bind(socket, tmp)
  return socket, tmp
end

local preview_socket, preview_socket_path = get_preview_socket()

uv.listen(preview_socket, 100, function(_)
  local preview_receive_socket = uv.new_pipe(false)
  -- start listening
  uv.accept(preview_socket, preview_receive_socket)
  preview_receive_socket:read_start(function(err, data)
    assert(not err)
    if not data then
      uv.close(preview_receive_socket)
      uv.close(preview_socket)
      vim.schedule(function()
        vim.cmd([[qall]])
      end)
      return
    end
    io.write(data)
  end)
end)

local function rpc_nvim_exec_lua(opts)
  local success, errmsg = pcall(function()
    -- fzf selection is unpacked as the argument list
    local fzf_selection = {}
    local nargs = vim.fn.argc()
    for i = 0, nargs - 1 do
      -- On Windows, vim.fn.argv() normalizes the path (replaces bslash with fslash)
      -- while vim.v.argv provides access to the raw argument, however, vim.v.argv
      -- contains the headless wrapper arguments so we need to index backwards
      table.insert(fzf_selection,
        _is_win and vim.v.argv[#vim.v.argv - nargs + 1 + i] or vim.fn.argv(i))
    end
    -- for skim compatibility
    local preview_lines = vim.env.FZF_PREVIEW_LINES or vim.env.LINES
    local preview_cols = vim.env.FZF_PREVIEW_COLUMNS or vim.env.COLUMNS
    local chan_id = vim.fn.sockconnect("pipe", opts.fzf_lua_server, { rpc = true })
    vim.rpcrequest(chan_id, "nvim_exec_lua", [[
      local luaargs = {...}
      local function_id = luaargs[1]
      local preview_socket_path = luaargs[2]
      local fzf_selection = luaargs[3]
      local fzf_lines = luaargs[4]
      local fzf_columns = luaargs[5]
      local usr_func = require"fzf-lua.shell".get_func(function_id)
      return usr_func(preview_socket_path, fzf_selection, fzf_lines, fzf_columns)
    ]], {
      opts.fnc_id,
      preview_socket_path,
      fzf_selection,
      tonumber(preview_lines),
      tonumber(preview_cols),
    })
    vim.fn.chanclose(chan_id)
  end)

  -- Avoid dangling temp dir on premature process kills (live grep)
  -- see more complete note in spawn.lua
  local tmpdir = vim.fn.fnamemodify(vim.fn.tempname(), ":h")
  if tmpdir and #tmpdir > 0 then
    vim.fn.delete(tmpdir, "rf")
  end
  if vim.v.servername and #vim.v.servername > 0 then
    pcall(vim.fn.serverstop, vim.v.servername)
  end

  if not success or opts.debug then
    io.stderr:write(("[DEBUG] debug = %s\n"):format(opts.debug))
    io.stderr:write(("[DEBUG] function ID = %d\n"):format(opts.fnc_id))
    io.stderr:write(("[DEBUG] fzf_lua_server = %s\n"):format(opts.fzf_lua_server))
    for i = 1, #vim.v.argv do
      io.stderr:write(("[DEBUG] argv[%d] = %s\n"):format(i, vim.v.argv[i]))
    end
    local nargs = vim.fn.argc()
    for i = 0, nargs - 1 do
      io.stderr:write(("[DEBUG] argv[%d] = %s\n"):format(i, vim.fn.argv(i)))
    end
    for i = 0, nargs - 1 do
      local argv_idx = #vim.v.argv - nargs + 1 + i
      io.stderr:write(("[DEBUG] v:arg[%d:%d] = %s\n"):format(i, argv_idx, vim.v.argv[argv_idx]))
    end
    for _, var in ipairs({ "LINES", "COLUMNS" }) do
      io.stderr:write(("[DEBUG] $%s = %s\n"):format(var, os.getenv(var) or "<null>"))
    end
  end

  if not success then
    io.stderr:write(("FzfLua Error: %s\n"):format(errmsg or "<null>"))
    vim.cmd([[qall]])
  end
end

return {
  rpc_nvim_exec_lua = rpc_nvim_exec_lua,
}
