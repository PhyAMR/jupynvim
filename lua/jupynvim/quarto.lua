-- Quarto (.qmd) cell-execution support.
--
-- Unlike .ipynb, .qmd files are real markdown on disk — the user edits the
-- source directly. We do NOT hijack the buffer, rewrite cell separators, or
-- intercept :w. Instead we treat the buffer as a read-only chunk container:
-- parse ```{lang} ... ``` fenced blocks, register one backend cell per chunk,
-- and render outputs as ephemeral virtual lines below each chunk's closing
-- fence. Outputs vanish on buffer close — they never touch the file.
--
-- The backend doesn't need a .qmd parser: we open a session bound to a
-- non-existent temp .ipynb path (`Notebook::read` returns `empty()` for
-- non-existent paths) and feed it cells via `replace_cells` on each run.
-- Save is never called, so the temp .ipynb stays nonexistent.

local M = {}

local Image = require("jupynvim.image")
local Log   = require("jupynvim.log")

-- buf -> state
local quartos = {}

-- ---------- chunk parsing ----------

-- Match: ```{python}   or   ```{r, echo=FALSE}   or   ```{julia} ...
-- Reject:  ```python (plain code block, not a Quarto executable chunk)
local CHUNK_OPEN_PAT  = "^%s*```{([%w_+%-]+)[^}]*}%s*$"
local CHUNK_CLOSE_PAT = "^%s*```%s*$"

local function parse_chunks(lines)
  local chunks = {}
  local i = 1
  while i <= #lines do
    local lang = lines[i] and lines[i]:match(CHUNK_OPEN_PAT)
    if lang then
      local open_line = i
      local close_line = nil
      for j = i + 1, #lines do
        if lines[j]:match(CHUNK_CLOSE_PAT) then close_line = j; break end
      end
      if close_line then
        table.insert(chunks, {
          lang        = lang:lower(),
          fence_open  = open_line,   -- 1-based line of ```{lang}
          fence_close = close_line,  -- 1-based line of closing ```
          code_start  = open_line + 1,
          code_stop   = close_line - 1,
        })
        i = close_line + 1
      else
        -- unterminated chunk — skip past the opening fence
        i = i + 1
      end
    else
      i = i + 1
    end
  end
  return chunks
end

local function chunk_source(buf, ch)
  if ch.code_start > ch.code_stop then return "" end
  local lines = vim.api.nvim_buf_get_lines(buf, ch.code_start - 1, ch.code_stop, false)
  return table.concat(lines, "\n")
end

function M.get(buf) return quartos[buf] end
function M.all() return quartos end

-- Public: which chunk does line `lnum` (1-based) belong to? Returns index +
-- chunk table, or nil if the cursor isn't inside any chunk's code body.
function M.chunk_at_line(buf, lnum)
  local st = quartos[buf]
  if not st then return nil end
  for i, ch in ipairs(st.chunks) do
    if lnum >= ch.fence_open and lnum <= ch.fence_close then
      return i, ch
    end
  end
  return nil
end

-- ---------- output rendering ----------

local function as_str(v)
  if type(v) == "table" then return table.concat(v, "") end
  if type(v) == "string" then return v end
  return ""
end

local function strip_ansi(s)
  s = s:gsub("\27%[[?]?[%d;]*[a-zA-Z]", "")
  s = s:gsub("\27%][^\27]*\27\\", "")
  s = s:gsub("\27.", "")
  return s
end

local function process_cr(s)
  local out = {}
  for chunk in (s .. "\n"):gmatch("([^\n]*)\n") do
    local segs = {}
    for seg in (chunk .. "\r"):gmatch("([^\r]*)\r") do
      table.insert(segs, seg)
    end
    table.insert(out, segs[#segs] or "")
  end
  if out[#out] == "" then table.remove(out) end
  return table.concat(out, "\n")
end

local function split_lines(s)
  local out = {}
  for line in (s .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(out, line)
  end
  if out[#out] == "" then table.remove(out) end
  return out
end

-- Build a virt_lines table for a single backend cell's collected state.
-- Each virt_line is `{ {text, hl}, ... }`. We render plain text with a
-- left-margin pipe so output reads as a quoted block.
local HL_OUTPUT  = "Comment"
local HL_STREAM  = "Comment"
local HL_RESULT  = "String"
local HL_ERROR   = "ErrorMsg"
local HL_BADGE   = "Special"
local HL_GUTTER  = "NonText"

local GUTTER = "  │ "

local function gutter(text, hl)
  return { { GUTTER, HL_GUTTER }, { text, hl or HL_OUTPUT } }
end

local function build_virt_lines(buf, st, idx, cell_state)
  local out = {}
  if not cell_state then return out end
  local ec = cell_state.execution_count
  local badge = ec and ("Out[" .. tostring(ec) .. "]") or "Out[*]"
  if cell_state.exec_state == "busy" and not ec then
    badge = "Out[*]"
  end
  table.insert(out, { { "  ", HL_GUTTER }, { badge, HL_BADGE } })

  for _, o in ipairs(cell_state.outputs or {}) do
    local t = o.output_type
    if t == "stream" then
      local txt = strip_ansi(process_cr(as_str(o.text)))
      for _, line in ipairs(split_lines(txt)) do
        table.insert(out, gutter(line, HL_STREAM))
      end
    elseif t == "execute_result" or t == "display_data" then
      local data = o.data or {}
      local txt = as_str(data["text/plain"])
      if txt ~= "" then
        for _, line in ipairs(split_lines(strip_ansi(process_cr(txt)))) do
          table.insert(out, gutter(line, HL_RESULT))
        end
      end
      -- Images: piggyback on image.lua's transmitted placement. If the cell
      -- has been transmitted (image_ids[idx] is set), image.placeholder_virt_lines
      -- builds the Unicode-placeholder rows that Kitty/Ghostty replace with
      -- the real image at draw time.
      if st.image_ids[idx] then
        local cell_id_for_img = st.cell_ids[idx]
        local rows = cell_id_for_img and Image.placeholder_virt_lines(cell_id_for_img)
        if rows then
          for _, row in ipairs(rows) do
            -- row is { {text, hl} }; prefix our gutter so it visually aligns.
            local prefixed = { { GUTTER, HL_GUTTER } }
            for _, chunk in ipairs(row) do table.insert(prefixed, chunk) end
            table.insert(out, prefixed)
          end
        end
      elseif data["image/png"] or data["image/jpeg"] or data["image/gif"] then
        table.insert(out, gutter("[image — transmitting…]", HL_OUTPUT))
      end
    elseif t == "error" then
      table.insert(out, gutter(as_str(o.ename) .. ": " .. as_str(o.evalue), HL_ERROR))
      for _, tb in ipairs(o.traceback or {}) do
        local txt = strip_ansi(process_cr(as_str(tb)))
        for _, line in ipairs(split_lines(txt)) do
          table.insert(out, gutter(line, HL_ERROR))
        end
      end
    end
  end
  return out
end

local function clear_output_marks(buf)
  local st = quartos[buf]
  if not st then return end
  pcall(vim.api.nvim_buf_clear_namespace, buf, st.output_ns, 0, -1)
end

function M.render(buf)
  local st = quartos[buf]
  if not st then return end
  clear_output_marks(buf)
  local line_count = vim.api.nvim_buf_line_count(buf)
  for idx, ch in ipairs(st.chunks) do
    local cell_id = st.cell_ids[idx]
    local cell_state = cell_id and st.cell_state[cell_id]
    if cell_state then
      local virt = build_virt_lines(buf, st, idx, cell_state)
      if #virt > 0 then
        local row = ch.fence_close - 1  -- 0-based
        if row >= line_count then row = line_count - 1 end
        if row >= 0 then
          pcall(vim.api.nvim_buf_set_extmark, buf, st.output_ns, row, 0, {
            virt_lines = virt,
            virt_lines_above = false,
            priority = 100,
          })
        end
      end
    end
  end
end

-- ---------- backend sync ----------

-- Push current chunk list to backend via replace_cells. Returns updated cell
-- id list (parallel to st.chunks). Synchronous so callers can immediately
-- execute the right backend cell.
local function sync_cells(st, ensure_client)
  local cl = ensure_client()
  local incoming = {}
  for i, ch in ipairs(st.chunks) do
    local id = st.cell_ids[i] or ("new_qmd_" .. tostring(vim.loop.hrtime()) .. "_" .. i)
    table.insert(incoming, {
      id = id,
      cell_type = "code",
      source = chunk_source(st.buf, ch),
    })
  end
  -- Empty file: still call replace_cells to keep backend state consistent;
  -- a 1-cell backend notebook is fine even if no chunks exist on screen.
  if #incoming == 0 then
    incoming[1] = { id = "new_qmd_empty", cell_type = "code", source = "" }
  end
  local err, res = cl:call_sync("replace_cells",
    { session_id = st.session_id, cells = incoming }, 5000)
  if err then
    vim.notify("jupynvim quarto: replace_cells failed: " .. tostring(err),
      vim.log.levels.ERROR)
    return nil
  end
  if res and res.ids then
    -- Drop old per-cell state for ids that have been removed
    local kept = {}
    for _, id in ipairs(res.ids) do kept[id] = true end
    for old_id in pairs(st.cell_state) do
      if not kept[old_id] then
        st.cell_state[old_id] = nil
      end
    end
    -- Refresh st.cell_ids to match current chunks (truncate any extra returned)
    local new_ids = {}
    for i = 1, #st.chunks do
      new_ids[i] = res.ids[i]
    end
    st.cell_ids = new_ids
  end
  return st.cell_ids
end

-- ---------- kernel ----------

-- Map a chunk language to a kernelspec language identifier.
local LANG_ALIASES = {
  py = "python", python = "python",
  r = "r",
  jl = "julia", julia = "julia",
  js = "javascript", javascript = "javascript",
  ts = "typescript", typescript = "typescript",
}

-- Read YAML front-matter jupyter:/engine: hint, if any. Lightweight regex
-- scan — only looks at the first front-matter block.
local function read_yaml_lang(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, 60, false)
  if not lines[1] or not lines[1]:match("^%-%-%-%s*$") then return nil end
  for i = 2, #lines do
    if lines[i]:match("^%-%-%-%s*$") then break end
    -- jupyter: python3        or   jupyter: { kernel: python3 }
    local k = lines[i]:match("^%s*jupyter:%s*([%w_%-%.]+)%s*$")
    if k then return k end
    local k2 = lines[i]:match("kernel:%s*([%w_%-%.]+)")
    if k2 then return k2 end
  end
  return nil
end

local function default_lang_for_buf(buf)
  local st = quartos[buf]
  if st and st.chunks[1] then return st.chunks[1].lang end
  return "python"
end

function M.start_kernel(buf, api, kernel_name)
  local st = quartos[buf]
  if not st then return end
  if st.kernel_started and not kernel_name then return end
  local cl = api._ensure_client()

  -- Prefer YAML-declared kernel; otherwise pick by chunk language.
  local explicit = kernel_name or read_yaml_lang(buf)
  local lang = default_lang_for_buf(buf)
  st.kernel_lang = lang

  -- For Python, try auto-venv just like the .ipynb path.
  local python_path = nil
  if not explicit and lang == "python" and api.config.auto_venv ~= false then
    local nb_dir = vim.fn.fnamemodify(st.path, ":h")
    python_path = api._find_local_venv_python and api._find_local_venv_python(nb_dir)
    if python_path then
      Log.info("quarto auto_venv: using " .. python_path)
    end
  end

  -- If no explicit kernel, pick by language from installed kernelspecs.
  if not explicit then
    cl:call("list_kernels", {}, function(err, kernels)
      if err or not kernels then
        explicit = "python3"
      else
        for _, k in ipairs(kernels) do
          if (k.language or ""):lower() == lang then
            explicit = k.name
            break
          end
        end
      end
      M._do_start_kernel(buf, api, explicit or "python3", python_path)
    end)
    return
  end
  M._do_start_kernel(buf, api, explicit, python_path)
end

function M._do_start_kernel(buf, api, kernel_name, python_path)
  local st = quartos[buf]
  if not st then return end
  local cl = api._ensure_client()
  cl:call("start_kernel", {
    session_id  = st.session_id,
    kernel_name = kernel_name,
    python_path = python_path,
  }, function(err, res)
    if err then
      vim.notify("quarto start_kernel: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    st.kernel_started = true
    vim.notify("jupynvim qmd: kernel '" .. (res.kernel_name or "?") .. "' started",
      vim.log.levels.INFO)
    -- Auto-inject inline matplotlib magic for python.
    if (res.kernel_name or ""):lower():find("python") or st.kernel_lang == "python" then
      cl:call("execute_silent", {
        session_id = st.session_id,
        code = "try:\n    get_ipython().run_line_magic('matplotlib', 'inline')\nexcept Exception:\n    pass\n",
      }, function() end)
    end
  end)
end

function M.stop_kernel(buf, api)
  local st = quartos[buf]
  if not st then return end
  st.kernel_started = false
  api._ensure_client():call("stop_kernel",
    { session_id = st.session_id }, function() end)
end

function M.interrupt_kernel(buf, api)
  local st = quartos[buf]
  if not st then return end
  api._ensure_client():call("interrupt_kernel",
    { session_id = st.session_id }, function() end)
end

function M.restart_kernel(buf, api)
  local st = quartos[buf]
  if not st then return end
  api._ensure_client():call("restart_kernel",
    { session_id = st.session_id }, function(err)
    if err then vim.notify("quarto restart: " .. tostring(err), vim.log.levels.ERROR); return end
    vim.notify("jupynvim qmd: kernel restarted", vim.log.levels.INFO)
  end)
end

function M.kernel_picker(buf, api)
  local st = quartos[buf]
  if not st then return end
  api._ensure_client():call("list_kernels", {}, function(err, kernels)
    if err then vim.notify("list_kernels: " .. err, vim.log.levels.ERROR); return end
    vim.ui.select(kernels, {
      prompt = "Select kernel:",
      format_item = function(k) return k.display_name .. "  (" .. k.name .. ")" end,
    }, function(choice)
      if not choice then return end
      M.stop_kernel(buf, api)
      vim.defer_fn(function() M.start_kernel(buf, api, choice.name) end, 200)
    end)
  end)
end

-- ---------- execution ----------

local function ensure_kernel_then(buf, api, fn)
  local st = quartos[buf]
  if not st then return end
  if st.kernel_started then fn(); return end
  -- Lazy start. start_kernel is async (callbacks); we poll briefly.
  M.start_kernel(buf, api, nil)
  local tries = 0
  local timer = vim.loop.new_timer()
  timer:start(150, 150, vim.schedule_wrap(function()
    tries = tries + 1
    if st.kernel_started then
      timer:stop(); timer:close()
      fn()
    elseif tries > 60 then  -- ~9s
      timer:stop(); timer:close()
      vim.notify("jupynvim qmd: kernel didn't start", vim.log.levels.WARN)
    end
  end))
end

function M.run_cell(buf, api, opts)
  opts = opts or {}
  local st = quartos[buf]
  if not st then return end
  M.refresh_chunks(buf, { skip_render = true })
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local idx = M.chunk_at_line(buf, lnum)
  if not idx then
    vim.notify("jupynvim qmd: cursor is not inside a code chunk", vim.log.levels.INFO)
    return
  end

  ensure_kernel_then(buf, api, function()
    local ids = sync_cells(st, api._ensure_client)
    if not ids then return end
    local cell_id = ids[idx]
    if not cell_id then return end
    -- Reset visible state so a fresh run shows Out[*]
    st.cell_state[cell_id] = { outputs = {}, execution_count = nil, exec_state = "busy" }
    st.image_ids[idx] = nil
    pcall(Image.clear_for_cell, cell_id)
    M.render(buf)
    api._ensure_client():call("execute",
      { session_id = st.session_id, cell_id = cell_id }, function(err)
      if err then
        vim.notify("execute: " .. tostring(err), vim.log.levels.ERROR)
      end
    end)
    if opts.advance then
      vim.schedule(function() M.jump_chunk(buf, 1) end)
    end
  end)
end

local function run_range(buf, api, from_idx, to_idx)
  local st = quartos[buf]
  if not st then return end
  ensure_kernel_then(buf, api, function()
    local ids = sync_cells(st, api._ensure_client)
    if not ids then return end
    local cl = api._ensure_client()
    local i = from_idx
    local function step()
      if i > to_idx then return end
      local cell_id = ids[i]
      if not cell_id then i = i + 1; return step() end
      st.cell_state[cell_id] = { outputs = {}, execution_count = nil, exec_state = "busy" }
      st.image_ids[i] = nil
      pcall(Image.clear_for_cell, cell_id)
      M.render(buf)
      local this_idx = i
      cl:call("execute", { session_id = st.session_id, cell_id = cell_id }, function()
        i = this_idx + 1
        step()
      end)
    end
    step()
  end)
end

function M.run_all(buf, api)
  M.refresh_chunks(buf, { skip_render = true })
  local st = quartos[buf]
  if not st or #st.chunks == 0 then return end
  run_range(buf, api, 1, #st.chunks)
end

function M.run_above(buf, api)
  M.refresh_chunks(buf, { skip_render = true })
  local st = quartos[buf]
  if not st or #st.chunks == 0 then return end
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local cur = M.chunk_at_line(buf, lnum)
  if not cur then
    -- Run everything before the cursor line
    cur = 1
    for i, ch in ipairs(st.chunks) do
      if ch.fence_open > lnum then cur = i; break end
      if i == #st.chunks then cur = i + 1 end
    end
  end
  if cur <= 1 then return end
  run_range(buf, api, 1, cur - 1)
end

function M.run_below(buf, api)
  M.refresh_chunks(buf, { skip_render = true })
  local st = quartos[buf]
  if not st or #st.chunks == 0 then return end
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local cur = M.chunk_at_line(buf, lnum)
  if not cur then
    for i, ch in ipairs(st.chunks) do
      if ch.fence_open >= lnum then cur = i; break end
    end
  end
  if not cur then return end
  run_range(buf, api, cur, #st.chunks)
end

-- ---------- navigation ----------

function M.jump_chunk(buf, delta)
  local st = quartos[buf]
  if not st or #st.chunks == 0 then return end
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local cur = M.chunk_at_line(buf, lnum)
  local target
  if delta > 0 then
    if cur then
      target = cur + 1
    else
      for i, ch in ipairs(st.chunks) do
        if ch.fence_open > lnum then target = i; break end
      end
    end
  else
    if cur then
      target = cur - 1
    else
      for i = #st.chunks, 1, -1 do
        if st.chunks[i].fence_close < lnum then target = i; break end
      end
    end
  end
  if not target or target < 1 or target > #st.chunks then
    vim.notify("jupynvim qmd: no " .. (delta > 0 and "next" or "prev") .. " chunk",
      vim.log.levels.INFO)
    return
  end
  local ch = st.chunks[target]
  -- Land on the first line of code inside the chunk
  local row = ch.code_start
  if row > vim.api.nvim_buf_line_count(buf) then row = ch.fence_open end
  pcall(vim.api.nvim_win_set_cursor, 0, { row, 0 })
end

-- ---------- clear outputs ----------

function M.clear_outputs(buf, api)
  local st = quartos[buf]
  if not st then return end
  for cid in pairs(st.cell_state) do
    pcall(Image.clear_for_cell, cid)
  end
  st.cell_state = {}
  st.image_ids = {}
  clear_output_marks(buf)
  api._ensure_client():call("clear_outputs",
    { session_id = st.session_id }, function() end)
end

function M.clear_cell_output(buf, api)
  local st = quartos[buf]
  if not st then return end
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local idx = M.chunk_at_line(buf, lnum)
  if not idx then return end
  local cell_id = st.cell_ids[idx]
  if not cell_id then return end
  pcall(Image.clear_for_cell, cell_id)
  st.cell_state[cell_id] = nil
  st.image_ids[idx] = nil
  M.render(buf)
  api._ensure_client():call("clear_cell_output",
    { session_id = st.session_id, cell_id = cell_id }, function() end)
end

-- ---------- chunk refresh ----------

function M.refresh_chunks(buf, opts)
  opts = opts or {}
  local st = quartos[buf]
  if not st then return end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local new_chunks = parse_chunks(lines)
  -- If the count changed, we drop the per-index image cache (chunk reshuffles
  -- invalidate position-based image ids; the per-cell ones in cell_state are
  -- keyed by cell_id and survive).
  if #new_chunks ~= #st.chunks then
    st.image_ids = {}
  end
  st.chunks = new_chunks
  if not opts.skip_render then
    M.render(buf)
  end
end

-- ---------- cell_event handler ----------

-- Mirrors init.lua's Notebook.apply_cell_event but operates on the quarto
-- state store. Called from init.lua's _handle_cell_event fallthrough.
function M._handle_cell_event(p)
  if not p or not p.session_id then return false end
  for buf, st in pairs(quartos) do
    if st.session_id == p.session_id then
      local cell_id = p.cell_id
      if not cell_id then return true end
      local cs = st.cell_state[cell_id] or { outputs = {}, execution_count = nil }
      st.cell_state[cell_id] = cs
      local ev = p.event or {}
      local kind = ev.kind
      if kind == "execute_input" then
        cs.execution_count = ev.execution_count
        cs.outputs = {}
        cs.exec_state = "busy"
        -- Drop any cached image placement for this chunk
        local idx_for_cell
        for i, id in ipairs(st.cell_ids) do
          if id == cell_id then idx_for_cell = i; break end
        end
        if idx_for_cell then st.image_ids[idx_for_cell] = nil end
      elseif kind == "stream" then
        local last = cs.outputs[#cs.outputs]
        if last and last.output_type == "stream" and last.name == ev.name then
          last.text = (last.text or "") .. ev.text
        else
          table.insert(cs.outputs, { output_type = "stream", name = ev.name, text = ev.text })
        end
      elseif kind == "execute_result" then
        table.insert(cs.outputs, {
          output_type = "execute_result",
          execution_count = ev.execution_count,
          data = ev.data, metadata = ev.metadata or {},
        })
        cs.execution_count = ev.execution_count
      elseif kind == "display_data" then
        table.insert(cs.outputs, {
          output_type = "display_data",
          data = ev.data, metadata = ev.metadata or {},
        })
      elseif kind == "error" then
        table.insert(cs.outputs, {
          output_type = "error",
          ename = ev.ename, evalue = ev.evalue, traceback = ev.traceback,
        })
      elseif kind == "status" then
        cs.exec_state = ev.state
      elseif kind == "clear_output" then
        if not ev.wait then cs.outputs = {} end
      end

      -- Image transmission (eager) — same pattern as init.lua does for ipynb.
      if (kind == "display_data" or kind == "execute_result") and ev.data then
        local b64, mime
        for _, m in ipairs({ "image/gif", "image/png", "image/jpeg" }) do
          local v = ev.data[m]
          if type(v) == "table" then v = table.concat(v, "") end
          if type(v) == "string" and v ~= "" then b64, mime = v, m; break end
        end
        if b64 and Image.supported() then
          local jn = require("jupynvim")
          local renderer = (jn.config and jn.config.image_renderer) or "placeholder"
          Image.ensure_transmitted(cell_id, b64, function(id)
            if id then
              local idx_for_cell
              for i, cid in ipairs(st.cell_ids) do
                if cid == cell_id then idx_for_cell = i; break end
              end
              if idx_for_cell then
                st.image_ids[idx_for_cell] = id
                vim.schedule(function() M.render(buf) end)
              end
            end
          end, { renderer = renderer, mime = mime })
        end
      end

      vim.schedule(function() M.render(buf) end)
      return true
    end
  end
  return false
end

-- ---------- attach / detach ----------

function M.attach(buf, api)
  if quartos[buf] then return end
  local abs = vim.api.nvim_buf_get_name(buf)
  if abs == "" then
    -- Unnamed buffer (e.g. nvim with no file) — defer until name is set.
    return
  end

  -- Open a backend session bound to a nonexistent temp .ipynb path. The
  -- backend's Notebook::read returns Notebook::empty() when the file doesn't
  -- exist, so we get a clean session with no on-disk dependency. We never
  -- call `save`, so nothing is written to disk.
  local cl = api._ensure_client()
  local tmp = vim.fn.tempname() .. ".jupynvim-qmd.ipynb"
  local err, result = cl:call_sync("open", { path = tmp }, 5000)
  if err then
    vim.notify("jupynvim quarto: open failed: " .. tostring(err), vim.log.levels.ERROR)
    return
  end

  -- Use the configured grid size, with smaller defaults — chunk outputs
  -- usually don't need a full-cell-sized plot.
  local cfg = api.config or {}
  local img_rows = math.min(cfg.image_rows or 32, 24)
  local img_cols = math.min(cfg.image_cols or 96, 80)

  quartos[buf] = {
    buf            = buf,
    path           = abs,
    tmp_path       = tmp,
    session_id     = result.session_id,
    chunks         = {},
    cell_ids       = {},
    cell_state     = {},
    image_ids      = {},
    output_ns      = vim.api.nvim_create_namespace("jupynvim.qmd.output." .. buf),
    kernel_started = false,
    kernel_lang    = nil,
    image_rows     = img_rows,
    image_cols     = img_cols,
  }

  M.refresh_chunks(buf)

  -- Keymaps. We pass the public `api` (init.lua's M); the action builders in
  -- keymaps.lua call api.run_cell etc, and those functions detect the .qmd
  -- buffer and dispatch back to us.
  require("jupynvim.keymaps").attach(buf, api)

  -- Autocmds
  local group = vim.api.nvim_create_augroup("JupynvimQmd_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group, buffer = buf,
    callback = function() M.refresh_chunks(buf) end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group, buffer = buf,
    callback = function() M.detach(buf, api) end,
  })

  Log.info("jupynvim qmd: attached buf=" .. buf .. " session=" .. result.session_id)
end

function M.detach(buf, api)
  local st = quartos[buf]
  if not st then return end
  if st.session_id then
    pcall(function()
      api._ensure_client():call("close",
        { session_id = st.session_id }, function() end)
    end)
  end
  if st.cell_ids then
    for _, cid in ipairs(st.cell_ids) do
      pcall(Image.clear_for_cell, cid)
    end
  end
  pcall(vim.api.nvim_buf_clear_namespace, buf, st.output_ns, 0, -1)
  quartos[buf] = nil
end

return M
