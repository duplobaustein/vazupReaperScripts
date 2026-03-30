-- @description ReaOrganize
-- @author vazupReaperScripts
-- @version 1.44
-- @repository https://github.com/duplobaustein/vazupReaperScripts
-- @links
--   GitHub https://github.com/duplobaustein/vazupReaperScripts
-- @about
--   # ReaOrganize v1.44
--   A powerful session organizer for REAPER.
--
--   Assign tracks to named, colored groups, create folder structures,
--   manage send routing, FX chains, panning and presets — all from one GUI.
--
--   Requires ReaImGui (install via ReaPack, search "ReaImGui").
--
--   See provided ReaOrganize_Manual.pdf for the full manual.
-- @provides
--   ReaOrganize.lua
--   ReaOrganize_Manual.pdf

local r = reaper
math.randomseed(os.time())

-- ── ReaImGui availability check ───────────────────────────────────────────────
if not r.ImGui_CreateContext then
  r.ShowMessageBox(
    "This script requires the ReaImGui extension.\n\nInstall it via ReaPack:\nExtensions > ReaPack > Browse packages > search 'ReaImGui'",
    "Missing Extension", 0)
  return
end

-- ── Version ───────────────────────────────────────────────────────────────────
local VERSION = "v1.44"

-- ── Constants ─────────────────────────────────────────────────────────────────
local MAX_GROUPS   = 100
local MAX_SENDS    = 8   -- max send slots per group
local MAX_GLOBAL_SENDS = 16  -- max global send tracks
local WIN_W, WIN_H = 1750, 720
local NO_GROUP     = 0   -- sentinel: unassigned

-- ── Mutable state (not constants) ───────────────────────────────────────────
local NUM_GROUPS   = 8   -- can grow/shrink at runtime

-- ── Helpers ─────────────────────────────────────────────────────────────────

local function pack_color(r8, g8, b8)
  -- store as 0xRRGGBB
  return (r8 << 16) | (g8 << 8) | b8
end

local function unpack_color(c)
  return (c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF
end

-- HSV ↔ RGB helpers (h: 0–360, s/v: 0–1, returns/takes r8,g8,b8: 0–255)
local function rgb_to_hsv(r8, g8, b8)
  local r, g, b = r8/255, g8/255, b8/255
  local mx = math.max(r,g,b); local mn = math.min(r,g,b); local d = mx - mn
  local h = 0
  if d > 0 then
    if mx == r then h = ((g - b) / d) % 6
    elseif mx == g then h = (b - r) / d + 2
    else h = (r - g) / d + 4 end
    h = h * 60
  end
  local s = mx > 0 and (d / mx) or 0
  return h, s, mx
end

local function hsv_to_rgb(h, s, v)
  h = h % 360
  local c = v * s; local x = c * (1 - math.abs((h/60)%2 - 1)); local m = v - c
  local r,g,b
  if     h < 60  then r,g,b = c,x,0
  elseif h < 120 then r,g,b = x,c,0
  elseif h < 180 then r,g,b = 0,c,x
  elseif h < 240 then r,g,b = 0,x,c
  elseif h < 300 then r,g,b = x,0,c
  else                r,g,b = c,0,x end
  return math.floor((r+m)*255+0.5), math.floor((g+m)*255+0.5), math.floor((b+m)*255+0.5)
end

-- Random vivid color: full hue range, high saturation, varied brightness
local function random_color()
  local h = math.random(0, 359)
  local s = math.random(55, 100) / 100   -- 0.55–1.0: always reasonably saturated
  local v = math.random(35, 95)  / 100   -- 0.35–0.95: full dark-to-bright range
  local r8, g8, b8 = hsv_to_rgb(h, s, v)
  return pack_color(r8, g8, b8)
end

-- Cycle the V (brightness) of a packed color through 8 equal steps (0/8 .. 7/8 of 1.0)
-- Returns new packed color
local function cycle_brightness(cp)
  local r8, g8, b8 = unpack_color(cp)
  local h, s, v = rgb_to_hsv(r8, g8, b8)
  -- quantise current V to nearest step, then advance one step
  local steps = 8
  local step_size = 1.0 / steps
  local cur_step = math.floor(v / step_size) % steps   -- floor: no wrap at band edge
  local new_v = ((cur_step - 1 + steps) % steps) * step_size + step_size * 0.5
  -- no clamping needed: band centres are safely within 0..1
  local nr, ng, nb = hsv_to_rgb(h, math.max(s, 0.15), new_v)
  return pack_color(nr, ng, nb)
end

-- ImGui wants colours as 0xRRGGBBAA
local function to_imgui_color(c, alpha)
  alpha = alpha or 255
  local rv, gv, bv = unpack_color(c)
  return (rv << 24) | (gv << 16) | (bv << 8) | alpha
end

-- Reaper native colour: 0x00BBGGRR  (yes, BGR)
local function to_reaper_color(c)
  local rv, gv, bv = unpack_color(c)
  return r.ColorToNative(rv, gv, bv) | 0x1000000
end

-- ── State ─────────────────────────────────────────────────────────────────────
local ctx         -- ImGui context (created in init)
local font_large  = nil  -- slightly larger font for modal text
local font_xlarge = nil  -- double-size font for current track name

local tracks      = {}   -- { name, reaper_idx, group, selected }
local groups      = {}   -- { name, color_packed, sends[] }  sends = array of {template}

local rename_track_buf  = {}  -- per-track rename buffer
local rename_group_buf  = {}  -- per-group rename buffer
local pan_track_buf     = {}  -- per-track pan text buffer
local send_track_buf    = {}  -- per-track send levels: send_track_buf[i][s] = dB string
local global_sends      = {}  -- { {name, template, color_packed}, ... } up to 8
local global_send_buf   = {}  -- per-track global send levels: global_send_buf[i][s] = dB string

-- multi-select: last clicked track index for shift-click range
local last_clicked = nil

-- group multi-select
local group_selected       = {}   -- g -> true/false
local last_clicked_group   = nil  -- for shift-click range select
local picker_multi_group_apply = false  -- ctrl+click FX: apply to all selected groups

-- resizable track table height (user can drag the splitter)
local track_table_h = 340

-- tab-to-next-row: track which input field should be focused next frame
local focused_track_send      = nil   -- {g, s} used for drawing (previous frame)
local fx_chain_list           = nil   -- { {label, rel_path}, ... } scanned from FXChains dir
local plugin_list             = nil   -- { {label, name}, ... } scanned from VST/CLAP/JS
local picker_state            = nil   -- { target="track"|"folder"|"send", i=, g=, s=, anchor_x=, anchor_y= }
local picker_search_buf       = ""
local picker_filtered         = {}
local picker_scroll_top       = false
local picker_focus_next        = false  -- bring picker to front next frame
local picker_show_chains      = true
local picker_show_vst3        = true
local picker_show_vst         = true
local picker_show_clap        = true
local picker_show_js          = true
local picker_combined_list    = nil   -- merged FX chains + plugins, rebuilt on first open

-- ── Undo / Redo ─────────────────────────────────────────────────────────────
local UNDO_MAX      = 20
local undo_stack    = {}
local redo_stack    = {}
local undo_debounce = nil   -- { time=, snapshot= } pending debounced push
local DEBOUNCE_SEC  = 1.0   -- seconds after last text/color change before push

-- ── Modal scope prompt ────────────────────────────────────────────────────────
local modal_pending          = nil  -- {title, msg, callback} set when a 0/inf/x button is clicked
local conflict_modal_pending = nil  -- {title, msg, callback} for Overwrite/Unique Name/Cancel
local guess_fx_modal         = nil  -- {tracks_list, current_idx, matches, selected_match}
local guess_fx_grp_modal     = nil  -- same structure but for groups/folder_template

-- Refocus flag: set after any blocking native dialog to reclaim ImGui focus
local refocus_next_frame    = false
local pending_color_action  = nil  -- {g, action} deferred one frame so SHIFT is readable after refocus

-- Modifier keys captured at mouse-down (before any dialog opens, window has OS focus)
local mouse_down_mod_ctrl  = false
local mouse_down_mod_shift = false

-- Pending flags: set on click, operation executes next frame so text is visible first
local preset_store_pending = {}  -- [p] = true when store confirmed, awaiting execution

-- ── FX apply-to-selected toggle ────────────────────────────────────────────
local fx_apply_to_selected = false

-- ── Master track row ────────────────────────────────────────────────────────
local master_name         = ""
local master_fx_chain     = nil



-- ── Options state ────────────────────────────────────────────────────────────
local opt_fx_folder          = nil   -- custom FX chain folder path (nil = default)
local opt_sends_at_bottom    = false -- move sends to bottom (above global sends)
local opt_sends_folder_top   = false -- move sends to top of their folder (just after folder track)
local opt_sends_folder_bot   = true  -- move sends to bottom of their folder (default)
local opt_send_color_packed  = pack_color(136, 136, 136)  -- default send color (0x888888)
local opt_send_use_trk_color = false
local opt_fx_bypass_inserts  = false -- bypass all insert FX after run
local opt_fx_bypass_chains   = false -- bypass all FX-chain tracks after run

-- ── Header text buffers ────────────────────────────────────────────────────────
-- (no extra state needed – labels are literals)

local group_load_version = 0  -- incremented on preset load to bust ImGui InputText cache

local function make_snapshot()
  local snap = { NUM_GROUPS = NUM_GROUPS, groups = {}, tracks = {}, global_sends = {}, global_send_vals = {} }
  for g = 1, NUM_GROUPS do
    local grp = groups[g]
    local snap_sends = {}
    for s = 1, #(grp.sends or {}) do
      local sl = grp.sends[s]
      snap_sends[s] = { name = sl.name, template = sl.template, color_packed = sl.color_packed, pre_fader = sl.pre_fader or false }
    end
    snap.groups[g] = {
      name            = grp.name,
      color_packed    = grp.color_packed,
      folder_template = grp.folder_template,
      sends           = snap_sends,
      routes_to       = grp.routes_to or 0,
    }
  end
  for i, t in ipairs(tracks) do
    local snap_tsends = {}
    if send_track_buf[i] then
      for k, v in pairs(send_track_buf[i]) do snap_tsends[k] = v end
    end
    local snap_gsvals = {}
    for s = 1, #global_sends do
      snap_gsvals[s] = global_send_buf[i] and global_send_buf[i][s] or ""
    end
    snap.tracks[i] = {
      group    = t.group,
      stereo   = t.stereo,
      pan_str  = pan_track_buf[i] or t.pan_str or "C",
      fx_chain = t.fx_chain,
      sends    = snap_tsends,
      gs_vals  = snap_gsvals,
    }
  end
  for s = 1, #global_sends do
    local gs = global_sends[s]
    snap.global_sends[s] = { name = gs.name, template = gs.template, color_packed = gs.color_packed, pre_fader = gs.pre_fader or false }
  end
  snap.opt_fx_folder          = opt_fx_folder
  snap.opt_sends_at_bottom    = opt_sends_at_bottom
  snap.opt_send_color_packed  = opt_send_color_packed
  snap.opt_send_use_trk_color = opt_send_use_trk_color
  snap.opt_fx_bypass_inserts  = opt_fx_bypass_inserts
  snap.opt_fx_bypass_chains   = opt_fx_bypass_chains
  snap.parent_color_packed    = parent_color_packed
  snap.parent_use_track_color = parent_use_track_color
  return snap
end

local function restore_snapshot(snap)
  NUM_GROUPS = snap.NUM_GROUPS
  groups = {}
  rename_group_buf = {}
  for g = 1, NUM_GROUPS do
    local sg = snap.groups[g]
    local r_sends = {}
    for s = 1, #(sg.sends or {}) do
      local sl = sg.sends[s]
      r_sends[s] = { name = sl.name, template = sl.template, color_packed = sl.color_packed, pre_fader = sl.pre_fader or false }
    end
    groups[g] = {
      name            = sg.name,
      color_packed    = sg.color_packed,
      folder_template = sg.folder_template,
      sends           = r_sends,
      routes_to       = sg.routes_to or 0,
      pan_str         = sg.pan_str or "C",
    }
    rename_group_buf[g] = sg.name
  end
  for i, t in ipairs(tracks) do
    local st = snap.tracks and snap.tracks[i]
    if st then
      t.group    = st.group or NO_GROUP
      if t.group > NUM_GROUPS then t.group = NO_GROUP end
      t.stereo   = st.stereo
      t.fx_chain = st.fx_chain
      t.pan_str  = st.pan_str or "C"
      pan_track_buf[i] = t.pan_str
      send_track_buf[i] = {}
      t.sends = {}
      if st.sends then
        for k, v in pairs(st.sends) do
          send_track_buf[i][k] = v
          t.sends[k] = v
        end
      end
      global_send_buf[i] = {}
      for s = 1, #(snap.global_sends or {}) do
        global_send_buf[i][s] = st.gs_vals and st.gs_vals[s] or ""
      end
    end
  end
  global_sends = {}
  for s = 1, #(snap.global_sends or {}) do
    local gs = snap.global_sends[s]
    global_sends[s] = { name = gs.name, template = gs.template, color_packed = gs.color_packed, pre_fader = gs.pre_fader or false }
  end
  group_load_version = group_load_version + 1
  if snap.master_name        ~= nil then master_name        = snap.master_name        end
  if snap.master_fx_chain    ~= nil then master_fx_chain    = snap.master_fx_chain    end
  if snap.opt_fx_folder          ~= nil then opt_fx_folder          = snap.opt_fx_folder          end
  if snap.opt_sends_at_bottom    ~= nil then opt_sends_at_bottom    = snap.opt_sends_at_bottom    end
  if snap.opt_send_color_packed  ~= nil then opt_send_color_packed  = snap.opt_send_color_packed  end
  if snap.opt_send_use_trk_color ~= nil then opt_send_use_trk_color = snap.opt_send_use_trk_color end
  if snap.opt_fx_bypass_inserts  ~= nil then opt_fx_bypass_inserts  = snap.opt_fx_bypass_inserts  end
  if snap.opt_fx_bypass_chains   ~= nil then opt_fx_bypass_chains   = snap.opt_fx_bypass_chains   end
  if snap.parent_color_packed    ~= nil then parent_color_packed    = snap.parent_color_packed    end
  if snap.parent_use_track_color ~= nil then parent_use_track_color = snap.parent_use_track_color end
end

local function push_undo()
  undo_debounce = nil  -- cancel any pending debounce
  local snap = make_snapshot()
  undo_stack[#undo_stack + 1] = snap
  if #undo_stack > UNDO_MAX then table.remove(undo_stack, 1) end
  redo_stack = {}  -- clear redo on new action
end

local function push_undo_debounced()
  -- Start/reset debounce timer; snapshot captured now, pushed after silence
  undo_debounce = { time = r.time_precise(), snapshot = make_snapshot() }
end

local function do_undo()
  if #undo_stack == 0 then return end
  redo_stack[#redo_stack + 1] = make_snapshot()
  restore_snapshot(table.remove(undo_stack))
end

local function do_redo()
  if #redo_stack == 0 then return end
  undo_stack[#undo_stack + 1] = make_snapshot()
  if #undo_stack > UNDO_MAX then table.remove(undo_stack, 1) end
  restore_snapshot(table.remove(redo_stack))
end

local function scan_fx_chains()
  fx_chain_list = { { label = "-- none --", rel_path = nil } }
  local base = r.GetResourcePath()
  local sep  = base:find("\\") and "\\" or "/"
  local root = (opt_fx_folder and opt_fx_folder ~= "") and opt_fx_folder
               or (base .. sep .. "FXChains")
  local function scan_dir(dir, prefix)
    local i = 0
    while true do
      local f = r.EnumerateFiles(dir, i)
      if not f or f == "" then break end
      if f:lower():match("%.rfxchain$") then
        local name = f:gsub("%.rfxchain$", ""):gsub("%.RfxChain$", ""):gsub("%.RFXCHAIN$", "")
        local lbl  = prefix ~= "" and (prefix .. "/" .. name) or name
        local rel  = prefix ~= "" and (prefix .. "/" .. f) or f
        fx_chain_list[#fx_chain_list + 1] = { label = lbl, rel_path = rel }
      end
      i = i + 1
    end
    local j = 0
    while true do
      local sub = r.EnumerateSubdirectories(dir, j)
      if not sub or sub == "" then break end
      scan_dir(dir .. sep .. sub, prefix ~= "" and (prefix .. "/" .. sub) or sub)
      j = j + 1
    end
  end
  scan_dir(root, "")
end
local function scan_plugins()
  plugin_list = {}
  picker_combined_list = nil  -- force rebuild on next open
  local res_path = r.GetResourcePath()
  local seen = {}

  -- VST / VST3: scan ALL reaper-vstplugins*.ini files in resource dir
  -- (Reaper creates separate files per scan path in some versions/configs)
  local function parse_vst_ini(path)
    local f = io.open(path, "r")
    if not f then return end
    for line in f:lines() do
      if not line:match("^%[") and line:match("=") then
        local filename = line:match("^([^=]+)=")
        local after_eq = line:match("=(.+)$")
        if after_eq and filename then
          -- Strip path, keep just the filename for extension detection
          local bs = string.char(92)  -- backslash without escape issues
          local basename = filename:match("([^/" .. bs .. "]+)$") or filename
          local _, _, rest = after_eq:match("^([^,]*),([^,]*),(.+)$")
          if rest then
            local name = rest:match("^([^!]+)"):match("^%s*(.-)%s*$")
            if name and name ~= "" then
              local is_vst3 = basename:lower():match("%.vst3$") ~= nil
              local prefix = is_vst3 and "VST3:" or "VST:"
              local full_name = prefix .. name
              if not seen[full_name] then
                seen[full_name] = true
                plugin_list[#plugin_list+1] = {
                  label = (is_vst3 and "VST3: " or "VST: ") .. name,
                  name  = full_name
                }
              end
            end
          end
        end
      end
    end
    f:close()
  end
  do
    local vi = 0
    while true do
      local fn = r.EnumerateFiles(res_path, vi)
      if not fn then break end
      if fn:lower():match("^reaper%-vstplugins") and fn:lower():match("%.ini$") then
        parse_vst_ini(res_path .. "/" .. fn)
      end
      vi = vi + 1
    end
  end

  -- CLAP: scan resource dir for any reaper-clap*.ini (filename varies by Reaper version)
  -- Line format: path\plugin.clap=HEXID,timestamp,subidx|Display Name (Manufacturer)!features
  -- The name field is after the last comma, then after "N|" sub-plugin index prefix.
  -- We store names as "CLAP:Name" so TrackFX_AddByName can locate them.
  local function parse_clap_ini(path)
    local f = io.open(path, "r")
    if not f then return end
    for line in f:lines() do
      if not line:match("^%[") and line:match("=") then
        local after_eq = line:match("=(.+)$")
        if after_eq then
          -- Extract everything after the last comma as the name field
          local name_field = after_eq:match(",([^,]+)$") or after_eq
          -- Strip trailing !features
          name_field = name_field:match("^([^!]+)") or name_field
          -- Strip leading N| sub-plugin index (e.g. "0|", "1|")
          name_field = name_field:match("^%d+|(.+)$") or name_field
          -- Trim whitespace
          local name = name_field:match("^%s*(.-)%s*$")
          -- Skip if it looks like a raw hex ID (32 hex chars) or empty
          if name and name ~= "" and not name:match("^[0-9A-Fa-f]+$") then
            local clap_name = "CLAP:" .. name  -- prefix for TrackFX_AddByName
            if not seen[clap_name] then
              seen[clap_name] = true
              plugin_list[#plugin_list+1] = { label = "CLAP: " .. name, name = clap_name }
            end
          end
        end
      end
    end
    f:close()
  end
  do
    local ri = 0
    while true do
      local fn = r.EnumerateFiles(res_path, ri)
      if not fn then break end
      if fn:lower():match("^reaper%-clap") and fn:lower():match("%.ini$") then
        parse_clap_ini(res_path .. "/" .. fn)
      end
      ri = ri + 1
    end
  end

  -- JS
  local js_path = res_path .. "/Effects"
  local function scan_js_dir(dir, rel)
    local i = 0
    while true do
      local fn = r.EnumerateFiles(dir, i)
      if not fn then break end
      if not fn:match("^%.") then
        local full_rel = rel ~= "" and (rel .. "/" .. fn) or fn
        local key = "JS: " .. full_rel
        if not seen[key] then
          seen[key] = true
          plugin_list[#plugin_list+1] = { label = key, name = key }
        end
      end
      i = i + 1
    end
    local j = 0
    while true do
      local dn = r.EnumerateSubdirectories(dir, j)
      if not dn then break end
      scan_js_dir(dir .. "/" .. dn, rel ~= "" and (rel .. "/" .. dn) or dn)
      j = j + 1
    end
  end
  scan_js_dir(js_path, "")

  table.sort(plugin_list, function(a, b) return a.label:lower() < b.label:lower() end)
end

local function picker_build_combined()
  if not fx_chain_list then scan_fx_chains() end
  if not plugin_list   then scan_plugins()  end
  picker_combined_list = {}
  -- FX chains first
  for _, e in ipairs(fx_chain_list) do
    if e.rel_path then  -- skip "-- none --"
      picker_combined_list[#picker_combined_list+1] = { label = "Chain: " .. e.label, name = e.rel_path, kind = "chain" }
    end
  end
  -- then plugins
  for _, p in ipairs(plugin_list) do
    local kind =
      p.label:find("^VST3:") and "vst3" or
      p.label:find("^VST:")  and "vst"  or
      p.label:find("^CLAP:") and "clap" or
      p.label:find("^JS:")   and "js"   or "other"
    picker_combined_list[#picker_combined_list+1] = { label = p.label, name = p.name, kind = kind }
  end
end

local function picker_rebuild_filtered()
  picker_filtered = {}
  local q = picker_search_buf:lower()
  local list = picker_combined_list or {}
  for _, p in ipairs(list) do
    local show =
      (p.kind == "chain" and picker_show_chains) or
      (p.kind == "vst3"  and picker_show_vst3)   or
      (p.kind == "vst"   and picker_show_vst)    or
      (p.kind == "clap"  and picker_show_clap)   or
      (p.kind == "js"    and picker_show_js)     or
      (p.kind == "other" and true)
    if show and (q == "" or p.label:lower():find(q, 1, true)) then
      picker_filtered[#picker_filtered+1] = p
    end
  end
end

local function open_picker(target, i, g, s)
  if not picker_combined_list then picker_build_combined() end
  picker_state      = { target = target, i = i, g = g, s = s }
  picker_search_buf = ""
  picker_scroll_top = true
  picker_focus_next  = true
  picker_rebuild_filtered()
end

local function group_path_to_root(g)
  local path = {}
  local cur = g
  while cur and cur ~= 0 do
    path[#path+1] = cur
    cur = (groups[cur] and groups[cur].routes_to) or 0
  end
  return path
end

-- True if g2 is a descendant of g1 (g2 is inside g1's subtree)
local function is_group_descendant(g2, g1)
  if g2 == 0 or g1 == 0 then return false end
  local cur = (groups[g2] and groups[g2].routes_to) or 0
  local limit = 0
  while cur ~= 0 and limit < 64 do
    if cur == g1 then return true end
    cur = (groups[cur] and groups[cur].routes_to) or 0
    limit = limit + 1
  end
  return false
end

-- True if g_check == g_root or is a descendant of g_root
local function in_group_subtree(g_check, g_root)
  if g_check == g_root then return true end
  return is_group_descendant(g_check, g_root)
end

-- Returns true if setting group g's routes_to to 'target' would create a cycle
local function would_create_routing_cycle(g, target)
  if target == 0 then return false end  -- routing to master is always fine
  if target == g then return true end
  return is_group_descendant(target, g)  -- target is inside g's subtree → cycle
end


-- Collect all group indices in g's subtree (g itself + all descendants)
local function groups_in_subtree(g)
  local result = { [g] = true }
  -- Walk all groups and check ancestry
  for gg = 1, NUM_GROUPS do
    if gg ~= g and in_group_subtree(gg, g) then result[gg] = true end
  end
  return result
end

local function apply_picker_result(name)
  if not picker_state then return end
  push_undo()
  local ps = picker_state
  if ps.target == "track" then
    if ps.mod_ctrl then
      -- Ctrl: apply to all selected tracks
      for _, st in ipairs(tracks) do
        if st.selected then st.fx_chain = name end
      end
      tracks[ps.i].fx_chain = name  -- also apply to clicked track
    elseif ps.mod_shift then
      -- Shift: this track + all tracks whose group is a strict descendant of this track's group
      local tg = tracks[ps.i].group
      tracks[ps.i].fx_chain = name
      if tg and tg ~= NO_GROUP then
        for _, st in ipairs(tracks) do
          if st.group and (st.group == tg or is_group_descendant(st.group, tg)) then
            st.fx_chain = name
          end
        end
      end
    else
      tracks[ps.i].fx_chain = name
    end
  elseif ps.target == "folder" then
    groups[ps.g].folder_template = name
    if ps.mod_ctrl then
      -- Ctrl: apply to all selected groups
      for gg = 1, NUM_GROUPS do
        if group_selected[gg] and gg ~= ps.g then groups[gg].folder_template = name end
      end
    elseif ps.mod_shift then
      -- Shift: apply to this group and all groups in its subtree
      local sub = groups_in_subtree(ps.g)
      for gg = 1, NUM_GROUPS do
        if sub[gg] and gg ~= ps.g then groups[gg].folder_template = name end
      end
    end
    picker_multi_group_apply = false
  elseif ps.target == "send" then
    groups[ps.g].sends[ps.s].template = name
  elseif ps.target == "gsend" then
    global_sends[ps.s].template = name
  elseif ps.target == "master" then
    master_fx_chain = name
  end
  picker_state = nil
end

local focused_track_send_next = nil   -- {g, s} set this frame, applied next frame

-- ── Parent track color settings ───────────────────────────────────────────────
local parent_color_packed    = pack_color(180, 40, 40)  -- default red
local parent_use_track_color = false  -- if true, folder gets same color as group

-- ── Group presets (8 slots) ───────────────────────────────────────────────────
local NUM_PRESETS = 8
local presets = {}
local preset_name_buf = {}
local spr_pan_buf     = "50"  -- inline spread value field
for i = 1, NUM_PRESETS do
  presets[i] = nil
  preset_name_buf[i] = "Preset " .. i
end

-- Parse pan string → Reaper pan value (-1.0 to +1.0), or nil if invalid
-- Accepts: "C", "0", "L", "R", "50L", "100L", "50R", "100R", "27L", etc.
local function parse_pan(s)
  if not s or s == "" then return nil end
  s = s:match("^%s*(.-)%s*$"):upper()  -- trim + uppercase
  if s == "C" or s == "0" then return 0.0 end
  if s == "L" then return -1.0 end
  if s == "R" then return  1.0 end
  local num, side = s:match("^(%d+%.?%d*)([LR])$")
  if num and side then
    local pct = tonumber(num)
    if pct < 0 or pct > 100 then return nil end
    local v = pct / 100.0
    return side == "L" and -v or v
  end
  -- plain number -100..100
  local plain = tonumber(s)
  if plain and math.abs(plain) <= 100 then return plain / 100.0 end
  return nil
end

-- Format Reaper pan value → display string
local function format_pan(v)
  if math.abs(v) < 0.005 then return "C" end
  local pct = math.floor(math.abs(v) * 100 + 0.5)
  return pct .. (v < 0 and "L" or "R")
end

-- Parse dB string → linear volume (0.0+), or nil if invalid
-- Accepts: "0", "-6", "-inf", "-INF", "inf" etc.
local function parse_db(s)
  if not s or s == "" then return nil end
  s = s:match("^%s*(.-)%s*$"):lower()
  if s == "-inf" or s == "-infinity" or s == "inf" or s == "infinity" or s == "i" then return 0.0 end
  local n = tonumber(s)
  if n == nil then return nil end
  if n > 12 then return nil end   -- sanity cap
  return 10 ^ (n / 20.0)
end

local function refresh_tracks()
  local count = r.CountTracks(0)
  -- Build a lookup of existing track state keyed by GUID (stable across reorders)
  local existing = {}
  for ti, t in ipairs(tracks) do
    local key = t.guid
    if not key or key == "" then
      -- Fallback: fetch GUID live for tracks that predate GUID storage
      local tr = r.GetTrack(0, t.reaper_idx)
      if tr then
        local _, g = r.GetSetMediaTrackInfo_String(tr, "GUID", "", false)
        key = g
      end
    end
    if key and key ~= "" then
      -- Carry global send buf values alongside the track state
      local gs_vals = {}
      if global_send_buf[ti] then
        for s, v in pairs(global_send_buf[ti]) do gs_vals[s] = v end
      end
      existing[key] = { group = t.group, selected = t.selected, stereo = t.stereo,
                        pan_str = t.pan_str, sends = t.sends, fx_chain = t.fx_chain,
                        gs_vals = gs_vals }
    end
  end
  tracks = {}
  global_send_buf = {}
  rename_track_buf = {}
  for i = 0, count - 1 do
    local track = r.GetTrack(0, i)
    local _, name = r.GetTrackName(track)
    local _, guid = r.GetSetMediaTrackInfo_String(track, "GUID", "", false)
    local prev = existing[guid] or { group = NO_GROUP, selected = false, stereo = false, pan_str = "C", sends = {}, fx_chain = nil, gs_vals = {} }
    -- Read current pan from Reaper if no stored value
    local init_pan_str = prev.pan_str
    if init_pan_str == "" or init_pan_str == nil then
      local pv = r.GetMediaTrackInfo_Value(track, "D_PAN")
      init_pan_str = format_pan(pv)
    end
    -- Migrate sends: old format has integer keys, new format uses "g:s" string keys
    local new_sends = {}
    if prev.sends then
      for k, v in pairs(prev.sends) do
        if type(k) == "number" and type(v) == "string" then
          local pg = prev.group
          if pg and pg ~= NO_GROUP then new_sends[pg..":"..k] = v end
        elseif type(k) == "string" and type(v) == "string" then
          new_sends[k] = v
        end
      end
    end
    local new_idx = #tracks + 1
    tracks[new_idx] = {
      name       = name,
      reaper_idx = i,
      guid       = guid,
      group      = prev.group,
      selected   = prev.selected,
      stereo     = prev.stereo,
      pan_str    = init_pan_str,
      sends      = new_sends,
      fx_chain   = prev.fx_chain,
    }
    rename_track_buf[new_idx] = name
    pan_track_buf[new_idx] = init_pan_str
    local stb = {}
    for k, v in pairs(new_sends) do stb[k] = v end
    send_track_buf[new_idx] = stb
    -- Restore global send buf values from GUID-keyed snapshot
    global_send_buf[new_idx] = {}
    if prev.gs_vals then
      for s, v in pairs(prev.gs_vals) do global_send_buf[new_idx][s] = v end
    end
  end
end

local function init_groups()
  groups = {}
  rename_group_buf = {}
  -- Distinct default hues spread evenly
  local default_colors = {
    pack_color(220,  80,  80),  -- 1  red-ish
    pack_color(220, 140,  60),  -- 2  orange
    pack_color(200, 200,  60),  -- 3  yellow
    pack_color(100, 200,  80),  -- 4  green
    pack_color( 60, 180, 180),  -- 5  teal
    pack_color( 60, 120, 220),  -- 6  blue
    pack_color(120,  60, 220),  -- 7  purple
    pack_color(200,  60, 180),  -- 8  pink
    pack_color(160, 100,  60),  -- 9  brown
    pack_color(100, 160, 100),  -- 10 sage
    pack_color( 60, 160, 200),  -- 11 sky
    pack_color(180,  60, 100),  -- 12 crimson
    pack_color(140, 200, 100),  -- 13 lime
    pack_color( 80, 100, 200),  -- 14 indigo
    pack_color(200, 120, 160),  -- 15 rose
    pack_color(120, 200, 180),  -- 16 mint
  }
  for i = 1, NUM_GROUPS do
    groups[i] = {
      name          = "Group " .. i,
      color_packed  = default_colors[i],
      sends         = {},    -- array of up to MAX_SENDS {template=path}
      routes_to     = 0,     -- 0 = master, or group index
      pan_str       = "C",   -- group folder track pan
    }
    rename_group_buf[i] = "Group " .. i
  end
end

-- ── Run: create folder tracks ─────────────────────────────────────────────────

local function run()
  local function find_track_by_guid(guid)
    for ki = 0, r.CountTracks(0) - 1 do
      local ktr = r.GetTrack(0, ki)
      local _, kg = r.GetSetMediaTrackInfo_String(ktr, "GUID", "", false)
      if kg == guid then return ki, ktr end
    end
    return nil, nil
  end

  -- Helper: try several name forms for TrackFX_AddByName robustness
  local function add_fx(tr, name)
    if not name or not tr then return end
    -- Try as stored (may have VST3:/VST:/CLAP:/JS: prefix)
    local result = r.TrackFX_AddByName(tr, name, false, -1)
    if result >= 0 then return end
    -- Try stripping the prefix and using bare name
    local bare = name:match("^[^:]+:(.+)$")
    if bare then
      result = r.TrackFX_AddByName(tr, bare, false, -1)
      if result >= 0 then return end
    end
    -- Try adding as instrument (for VSTi)
    r.TrackFX_AddByName(tr, name, true, -1)
  end

  -- ── Step 1: collect group members (skip tracks already inside a folder) ───
  local group_members = {}
  for g = 1, NUM_GROUPS do group_members[g] = {} end

  for _, t in ipairs(tracks) do
    if t.group ~= NO_GROUP then
      local rtrack = r.GetTrack(0, t.reaper_idx)
      if not r.GetParentTrack(rtrack) then
        group_members[t.group][#group_members[t.group] + 1] = t
      end
    end
  end

  -- Build list of active groups sorted by the lowest original track index
  local active_groups = {}
  for g = 1, NUM_GROUPS do
    if #group_members[g] > 0 then
      table.sort(group_members[g], function(a, b) return a.reaper_idx < b.reaper_idx end)
      active_groups[#active_groups + 1] = {
        g       = g,
        members = group_members[g],
        min_idx = group_members[g][1].reaper_idx,
      }
    end
  end
  -- (continue even with no active groups — track FX and global sends still apply)

  -- Stamp GUIDs onto ALL tracks (including stereo-flagged ones) before any moves
  for _, t in ipairs(tracks) do
    local tr = r.GetTrack(0, t.reaper_idx)
    if tr then
      local _, gg = r.GetSetMediaTrackInfo_String(tr, "GUID", "", false)
      t.guid = gg
    end
  end

  -- Helper: get current index of a track by its GUID
  local function track_index(guid)
    local n = r.CountTracks(0)
    for i = 0, n - 1 do
      local tr = r.GetTrack(0, i)
      local _, g2 = r.GetSetMediaTrackInfo_String(tr, "GUID", "", false)
      if g2 == guid then return i end
    end
    return nil
  end

  -- Helper: get GUID of a track
  local function track_guid(tr)
    local _, g2 = r.GetSetMediaTrackInfo_String(tr, "GUID", "", false)
    return g2
  end

  -- Stamp GUIDs onto every member
  for _, ag in ipairs(active_groups) do
    for _, m in ipairs(ag.members) do
      local tr = r.GetTrack(0, m.reaper_idx)
      m.guid = track_guid(tr)
    end
  end

  local folder_track_guid = {}   -- [g] = GUID string
  local send_track_guids  = {}   -- [g][s] = GUID string

  -- ── Build group tree (hoisted: needed by send reposition block too) ──────────
  local group_children_map = {}
  for g2b = 1, NUM_GROUPS do group_children_map[g2b] = {} end
  for g2b = 1, NUM_GROUPS do
    local par = (groups[g2b].routes_to or 0)
    if par ~= 0 and par <= NUM_GROUPS then
      group_children_map[par][#group_children_map[par]+1] = g2b
    end
  end

  local has_active_sub = {}
  local function has_any_active(ga)
    if has_active_sub[ga] ~= nil then return has_active_sub[ga] end
    if #group_members[ga] > 0 then has_active_sub[ga] = true; return true end
    for _, cg in ipairs(group_children_map[ga]) do
      if has_any_active(cg) then has_active_sub[ga] = true; return true end
    end
    has_active_sub[ga] = false; return false
  end

  if #active_groups > 0 then

  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)

  -- ── process_group: roots-first DFS ────────────────────────────────────────────
  -- 1. Move all subtree tracks to consecutive positions.
  -- 2. Insert folder track above them.
  -- 3. Recurse into children (they land naturally inside the parent folder).
  -- 4. Insert send tracks using GUID-based max-position search (no depth traversal).
  -- 5. One clean depth pass after everything is placed.
  local function process_group(g)
    -- Order GUID list by original track position:
    -- direct members and child subtrees are interleaved by their min position,
    -- so a stereo pair that sits after the subgroup tracks stays after them.
    local function subtree_min_pos(gg)
      local min = math.huge
      for _, m in ipairs(group_members[gg]) do
        if m.guid then
          local p = track_index(m.guid)
          if p and p < min then min = p end
        end
      end
      for _, cg in ipairs(group_children_map[gg]) do
        if has_any_active(cg) then
          local p = subtree_min_pos(cg)
          if p < min then min = p end
        end
      end
      return min
    end

    local function ordered_guids(gg)
      local out   = {}
      -- items: each entry is either {kind="mem", guid, pos} or {kind="child", cg, pos}
      local items = {}
      for _, m in ipairs(group_members[gg]) do
        if m.guid then
          local p = track_index(m.guid)
          items[#items+1] = { kind = "mem", guid = m.guid, pos = p or math.huge }
        end
      end
      for _, cg in ipairs(group_children_map[gg]) do
        if has_any_active(cg) then
          items[#items+1] = { kind = "child", cg = cg, pos = subtree_min_pos(cg) }
        end
      end
      table.sort(items, function(a, b) return a.pos < b.pos end)
      for _, item in ipairs(items) do
        if item.kind == "mem" then
          out[#out+1] = item.guid
        else
          for _, guid in ipairs(ordered_guids(item.cg)) do out[#out+1] = guid end
        end
      end
      return out
    end

    local ordered = ordered_guids(g)
    if #ordered == 0 then return end

    -- Current first position of any track in this subtree
    local first_pos = math.huge
    for _, guid in ipairs(ordered) do
      local p = track_index(guid)
      if p and p < first_pos then first_pos = p end
    end
    if first_pos == math.huge then return end

    -- Consolidate subtree tracks to consecutive positions starting at first_pos
    for idx, guid in ipairs(ordered) do
      local target = first_pos + idx - 1
      local cur    = track_index(guid)
      if cur and cur ~= target then
        local tr = r.GetTrack(0, cur)
        r.SetOnlyTrackSelected(tr)
        if cur > target then
          r.ReorderSelectedTracks(target, 0)
        else
          r.ReorderSelectedTracks(target + 1, 0)
        end
      end
    end

    -- Insert folder track at first_pos
    r.InsertTrackAtIndex(first_pos, true)
    local folder_tr = r.GetTrack(0, first_pos)
    local grp       = groups[g]
    r.GetSetMediaTrackInfo_String(folder_tr, "P_NAME", grp.name, true)
    local fc = parent_use_track_color and to_reaper_color(grp.color_packed)
                                       or  to_reaper_color(parent_color_packed)
    r.SetTrackColor(folder_tr, fc)
    folder_track_guid[g] = track_guid(folder_tr)
    do local pv = parse_pan(grp.pan_str or "C"); if pv then r.SetMediaTrackInfo_Value(folder_tr, "D_PAN", pv) end end

    -- Recurse into children (they are now inside this folder's block)
    local kids = {}
    for _, cg in ipairs(group_children_map[g]) do
      if has_any_active(cg) then kids[#kids+1] = cg end
    end
    table.sort(kids)
    for _, cg in ipairs(kids) do process_group(cg) end

    -- Insert send tracks using GUID-based max-position — no depth traversal needed
    if grp.sends and #grp.sends > 0 then
      send_track_guids[g] = {}
      for s, send_slot in ipairs(grp.sends) do
        local last_pos = track_index(folder_track_guid[g]) or first_pos
        local function scan_last(gg)
          for _, m in ipairs(group_members[gg]) do
            if m.guid then
              local p = track_index(m.guid)
              if p then last_pos = math.max(last_pos, p) end
            end
          end
          if send_track_guids[gg] then
            for _, sg in ipairs(send_track_guids[gg]) do
              if sg then
                local p = track_index(sg)
                if p then last_pos = math.max(last_pos, p) end
              end
            end
          end
          if folder_track_guid[gg] and gg ~= g then
            local p = track_index(folder_track_guid[gg])
            if p then last_pos = math.max(last_pos, p) end
          end
          for _, cg in ipairs(group_children_map[gg]) do
            if has_any_active(cg) then scan_last(cg) end
          end
        end
        scan_last(g)

        local insert_at = last_pos + 1
        r.InsertTrackAtIndex(insert_at, false)
        local send_tr = r.GetTrack(0, insert_at)
        local stguid  = track_guid(send_tr)
        send_track_guids[g][s] = stguid

        if send_slot.template then add_fx(send_tr, send_slot.template) end
        local sname = (send_slot.name ~= "") and send_slot.name or nil
        if sname then r.GetSetMediaTrackInfo_String(send_tr, "P_NAME", sname, true) end
        if send_slot.color_packed and send_slot.color_packed ~= 0x888888 then
          local sr2, sg2b, sb2 = unpack_color(send_slot.color_packed)
          r.SetMediaTrackInfo_Value(send_tr, "I_CUSTOMCOLOR",
            r.ColorToNative(sr2, sg2b, sb2) | 0x1000000)
        end

        -- Wire sends
        local skey = g..":"..s
        for ti2, t2 in ipairs(tracks) do
          local db_str = send_track_buf[ti2] and send_track_buf[ti2][skey] or ""
          if db_str ~= "" then
            local vol = parse_db(db_str)
            if vol and t2.guid then
              local _, src_trk = find_track_by_guid(t2.guid)
              if src_trk then
                local sidx = r.CreateTrackSend(src_trk, send_tr)
                r.SetTrackSendInfo_Value(src_trk, 0, sidx, "D_VOL",      vol)
                r.SetTrackSendInfo_Value(src_trk, 0, sidx, "I_SENDMODE", send_slot.pre_fader and 3 or 0)
              end
            end
          end
        end
      end  -- for s
    end
  end  -- process_group

  -- Process each root group in index order
  for g2c = 1, NUM_GROUPS do
    if (groups[g2c].routes_to or 0) == 0 and has_any_active(g2c) then
      process_group(g2c)
    end
  end

  -- ── Single depth pass after all insertions ────────────────────────────────────
  local guid_level = {}
  local function assign_levels(g, depth)
    if folder_track_guid[g] then guid_level[folder_track_guid[g]] = depth end
    for _, m in ipairs(group_members[g]) do
      if m.guid then guid_level[m.guid] = depth + 1 end
    end
    if send_track_guids[g] then
      for _, sg in ipairs(send_track_guids[g]) do
        if sg then guid_level[sg] = depth + 1 end
      end
    end
    for _, cg in ipairs(group_children_map[g]) do
      if has_any_active(cg) then assign_levels(cg, depth + 1) end
    end
  end
  for g2d = 1, NUM_GROUPS do
    if (groups[g2d].routes_to or 0) == 0 and has_any_active(g2d) then
      assign_levels(g2d, 0)
    end
  end

  local total_tracks = r.CountTracks(0)
  local track_levels = {}
  for ti = 0, total_tracks - 1 do
    local tr = r.GetTrack(0, ti)
    local _, tguid = r.GetSetMediaTrackInfo_String(tr, "GUID", "", false)
    track_levels[ti] = guid_level[tguid] or 0
  end
  for ti = 0, total_tracks - 1 do
    local tr         = r.GetTrack(0, ti)
    local cur_level  = track_levels[ti]
    local next_level = (ti + 1 < total_tracks) and track_levels[ti + 1] or 0
    r.SetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH", next_level - cur_level)
  end

  -- ── Color pass ───────────────────────────────────────────────────────────────
  for g2e = 1, NUM_GROUPS do
    local child_color = to_reaper_color(groups[g2e].color_packed)
    for _, m in ipairs(group_members[g2e]) do
      if m.guid then
        local _, mtr = find_track_by_guid(m.guid)
        if mtr then r.SetTrackColor(mtr, child_color) end
      end
    end
  end

  -- ── Pan values ───────────────────────────────────────────────────────────────
  for _, t in ipairs(tracks) do
    if t.pan_str and t.pan_str ~= "" then
      local pv = parse_pan(t.pan_str)
      if pv and t.guid then
        local _, ktr = find_track_by_guid(t.guid)
        if ktr then r.SetMediaTrackInfo_Value(ktr, "D_PAN", pv) end
      end
    end
  end

  r.PreventUIRefresh(-1)
  r.TrackList_AdjustWindows(false)
  r.UpdateArrange()
  r.Undo_EndBlock("ReaOrganize: build session", -1)

  end  -- end if #active_groups > 0

  -- ── Apply master track settings ─────────────────────────────────────────────
  do
    local mtr = r.GetMasterTrack(0)
    if mtr then
      if master_name and master_name ~= "" then
        r.GetSetMediaTrackInfo_String(mtr, "P_NAME", master_name, true)
      end
      if master_fx_chain then add_fx(mtr, master_fx_chain) end
      r.UpdateArrange()
      r.MarkProjectDirty(0)
    end
  end

  -- ── Step 4: implode stereo pairs then delete the second track ───────────────
  -- Done AFTER the undo block and PreventUIRefresh so Reaper's state is fully live.
  local implode_cmd = r.NamedCommandLookup("_XENAKIOS_IMPLODEITEMSPANSYMMETRICALLY")
  if implode_cmd and implode_cmd ~= 0 then

    -- Stamp GUIDs of all trk_b tracks BEFORE imploding/deleting anything,
    -- so deletions don't invalidate indices mid-loop.
    local b_guids = {}
    for _, t in ipairs(tracks) do
      if t.stereo and t.guid then
        local cur_idx, trk_a = find_track_by_guid(t.guid)
        if cur_idx then
          local trk_b = r.GetTrack(0, cur_idx + 1)
          if trk_a and trk_b then
            -- Implode immediately (order matters for overlapping pairs)
            r.Main_OnCommand(40297, 0)
            r.SetTrackSelected(trk_a, true)
            r.SetTrackSelected(trk_b, true)
            r.SelectAllMediaItems(0, false)
            for ii = 0, r.CountTrackMediaItems(trk_a) - 1 do
              r.SetMediaItemSelected(r.GetTrackMediaItem(trk_a, ii), true)
            end
            for ii = 0, r.CountTrackMediaItems(trk_b) - 1 do
              r.SetMediaItemSelected(r.GetTrackMediaItem(trk_b, ii), true)
            end
            r.Main_OnCommand(implode_cmd, 0)
            r.UpdateArrange()
            -- Store trk_b GUID for deletion pass
            local _, bg = r.GetSetMediaTrackInfo_String(trk_b, "GUID", "", false)
            b_guids[#b_guids + 1] = bg
          end
        end
      end
    end

    -- Delete all trk_b tracks one at a time using the native "delete selected
    -- tracks" action (40005) — this keeps folder depth bookkeeping correct,
    -- matching what happens when the user deletes manually.
    -- Process bottom-up so each deletion doesn't shift indices of tracks above.
    local b_idxs = {}
    for _, bg in ipairs(b_guids) do
      local bi, _ = find_track_by_guid(bg)
      if bi then b_idxs[#b_idxs + 1] = bi end
    end
    table.sort(b_idxs, function(a, b) return a > b end)
    r.Undo_BeginBlock()
    for _, bi in ipairs(b_idxs) do
      local trk_del = r.GetTrack(0, bi)
      if trk_del then
        -- Deselect all, select only this track, then delete via native action
        r.Main_OnCommand(40297, 0)       -- unselect all tracks
        r.SetTrackSelected(trk_del, true)
        r.Main_OnCommand(40005, 0)       -- delete selected tracks (same as manual)
      end
    end
    r.Undo_EndBlock("Track Group Manager: delete imploded stereo tracks", -1)

    -- Clean up selection
    r.Main_OnCommand(40297, 0)
    r.SelectAllMediaItems(0, false)
    r.TrackList_AdjustWindows(false)
    r.UpdateArrange()
  end
  -- ── Step 6: apply FX chains from track templates ───────────────────────────
  local has_fx_templates = false
  for _, t in ipairs(tracks) do
    if t.fx_chain and t.guid then has_fx_templates = true; break end
  end
  for g = 1, NUM_GROUPS do
    if groups[g].folder_template then has_fx_templates = true; break end
  end

  if has_fx_templates then
    r.Undo_BeginBlock()
    for _, t in ipairs(tracks) do
      if t.fx_chain and t.guid then
        local _, tr = find_track_by_guid(t.guid)
        if tr then
          for fi = r.TrackFX_GetCount(tr) - 1, 0, -1 do
            r.TrackFX_Delete(tr, fi)
          end
          add_fx(tr, t.fx_chain)
        end
      end
    end
    -- Apply folder FX templates to group folder tracks
    for g = 1, NUM_GROUPS do
      if groups[g].folder_template then
        -- find the folder track for this group by name
        for ki = 0, r.CountTracks(0) - 1 do
          local ktr = r.GetTrack(0, ki)
          local _, kname = r.GetSetMediaTrackInfo_String(ktr, "P_NAME", "", false)
          if kname == groups[g].name then
            for fi = r.TrackFX_GetCount(ktr) - 1, 0, -1 do
              r.TrackFX_Delete(ktr, fi)
            end
            add_fx(ktr, groups[g].folder_template)
            break
          end
        end
      end
    end
    r.TrackList_AdjustWindows(false)
    r.UpdateArrange()
    r.Undo_EndBlock("ReaOrganize: apply FX templates", -1)
  end

  -- ── Step 7: insert global send tracks at very bottom ──────────────────────
  if #global_sends > 0 then
    r.Undo_BeginBlock()
    for s, gs in ipairs(global_sends) do
      local insert_at = r.CountTracks(0)
      r.InsertTrackAtIndex(insert_at, false)
      local gs_track = r.GetTrack(0, insert_at)
      -- Name
      local gsname = gs.name ~= "" and gs.name or ("Global Send "..s)
      r.GetSetMediaTrackInfo_String(gs_track, "P_NAME", gsname, true)
      -- Color
      if gs.color_packed and gs.color_packed ~= 0x888888 then
        local gr2, gg2, gb2 = unpack_color(gs.color_packed)
        r.SetMediaTrackInfo_Value(gs_track, "I_CUSTOMCOLOR", r.ColorToNative(gr2,gg2,gb2) | 0x1000000)
      end
      -- FX chain
      if gs.template then
        add_fx(gs_track, gs.template)
      end
      -- Wire sends from all tracks that have a dB value for this slot
      for ti, t in ipairs(tracks) do
        local db_str = global_send_buf[ti] and global_send_buf[ti][s] or ""
        if db_str and db_str ~= "" then
          local vol = parse_db(db_str)
          if vol and t.guid then
            local _, src_trk = find_track_by_guid(t.guid)
            if src_trk then
              local send_idx = r.CreateTrackSend(src_trk, gs_track)
              r.SetTrackSendInfo_Value(src_trk, 0, send_idx, "D_VOL",      vol)
              r.SetTrackSendInfo_Value(src_trk, 0, send_idx, "I_SENDMODE", gs.pre_fader and 3 or 0)
            end
          end
        end
      end
    end
    r.TrackList_AdjustWindows(false)
    r.UpdateArrange()
    r.Undo_EndBlock("ReaOrganize: insert global send tracks", -1)
  end

  -- ── Send position adjustments ────────────────────────────────────────────────
  if (opt_sends_at_bottom or opt_sends_folder_top) and next(send_track_guids) ~= nil then
    r.Undo_BeginBlock()
    if opt_sends_at_bottom then
      -- Collect all send tracks, sort descending, move each to very end of project.
      local all_st = {}
      for _, sguids in pairs(send_track_guids) do
        for _, sg in ipairs(sguids) do
          if sg then
            local si = track_index(sg)
            if si then all_st[#all_st+1] = { guid = sg, idx = si } end
          end
        end
      end
      table.sort(all_st, function(a, b) return a.idx > b.idx end)
      for _, st in ipairs(all_st) do
        local cur2 = track_index(st.guid)
        if cur2 then
          local dest = r.CountTracks(0)  -- always the very last position
          if cur2 ~= dest - 1 then
            local str = r.GetTrack(0, cur2)
            r.SetOnlyTrackSelected(str)
            r.ReorderSelectedTracks(dest, 0)
          end
        end
      end
    else  -- opt_sends_folder_top: per group, move sends to just after folder track
      for gx, sguids in pairs(send_track_guids) do
        local fguid = folder_track_guid[gx]
        if fguid then
          -- Collect valid send GUIDs for this group
          local grp_sends = {}
          for _, sg in ipairs(sguids) do
            if sg and track_index(sg) then
              grp_sends[#grp_sends+1] = sg
            end
          end
          -- Move ascending: each send goes to fi+1, pushing previous ones down by 1
          for k, sg in ipairs(grp_sends) do
            local fi = track_index(fguid)  -- re-lookup each time
            if fi then
              local dest = fi + 1
              local cur2 = track_index(sg)
              if cur2 and cur2 ~= dest then
                local str = r.GetTrack(0, cur2)
                r.SetOnlyTrackSelected(str)
                if cur2 > dest then r.ReorderSelectedTracks(dest, 0)
                else r.ReorderSelectedTracks(dest + 1, 0) end
              end
            end
          end
        end
      end
    end
    -- After moving, redo the depth pass so depth values are correct.
    -- Only needed for At Bottom (sends move outside all folders).
    -- Folder Top leaves sends inside folders so no depth repair is needed.
    if opt_sends_at_bottom then
      local tot = r.CountTracks(0)
      local g2l = {}
      do
        local function ral2(gg, dep)
          if folder_track_guid[gg] then g2l[folder_track_guid[gg]] = dep end
          for _, mem in ipairs(group_members[gg]) do
            if mem.guid then g2l[mem.guid] = dep + 1 end
          end
          for _, cg in ipairs(group_children_map[gg]) do
            if has_any_active(cg) then ral2(cg, dep + 1) end
          end
        end
        for grr = 1, NUM_GROUPS do
          if (groups[grr].routes_to or 0) == 0 and has_any_active(grr) then ral2(grr, 0) end
        end
      end  -- ral2
      local tl2 = {}
      for ti = 0, tot - 1 do
        local tr = r.GetTrack(0, ti)
        local _, tg = r.GetSetMediaTrackInfo_String(tr, "GUID", "", false)
        tl2[ti] = g2l[tg] or 0
      end
      for ti = 0, tot - 1 do
        local tr = r.GetTrack(0, ti)
        local nl = (ti + 1 < tot) and tl2[ti + 1] or 0
        r.SetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH", nl - tl2[ti])
      end
    end
    r.TrackList_AdjustWindows(false); r.UpdateArrange()
    r.Undo_EndBlock("ReaOrganize: reposition sends", -1)
  end

  -- ── Apply send color (per-send color from group panel) ───────────────────
  for gx2, sguids2 in pairs(send_track_guids) do
    for sx2, sg2 in ipairs(sguids2) do
      if sg2 then
        local _, str2 = find_track_by_guid(sg2)
        if str2 then
          local send_slot2 = groups[gx2] and groups[gx2].sends and groups[gx2].sends[sx2]
          local cp2 = (send_slot2 and send_slot2.color_packed) or opt_send_color_packed
          if cp2 ~= 0x888888 then
            local sr2, sg2b, sb2 = unpack_color(cp2)
            r.SetMediaTrackInfo_Value(str2, "I_CUSTOMCOLOR", r.ColorToNative(sr2, sg2b, sb2) | 0x1000000)
          end
        end
      end
    end
  end

  -- ── FX Bypass ──────────────────────────────────────────────────────────────
  if opt_fx_bypass_inserts or opt_fx_bypass_chains then
    r.Undo_BeginBlock()
    r.PreventUIRefresh(1)
    for bti = 0, r.CountTracks(0) - 1 do
      local btr = r.GetTrack(0, bti)
      local fxc = r.TrackFX_GetCount(btr)
      for bfi = 0, fxc - 1 do
        local is_instrument = r.TrackFX_GetInstrument(btr) == bfi
        if opt_fx_bypass_inserts and not is_instrument then
          r.TrackFX_SetEnabled(btr, bfi, false)
        end
        if opt_fx_bypass_chains then
          for _, bt2 in ipairs(tracks) do
            if bt2.fx_chain and bt2.guid then
              local _, btr2 = find_track_by_guid(bt2.guid)
              if btr2 == btr then
                r.TrackFX_SetEnabled(btr, bfi, false)
              end
            end
          end
        end
      end
    end
    r.PreventUIRefresh(-1)
    r.Undo_EndBlock("ReaOrganize: bypass FX", -1)
  end

  -- GUI state intentionally NOT reset here — tracks/groups keep their assignments
end

-- ── Native dialog wrappers: restore ImGui focus after every blocking call ───────
local function dlg_ShowMessageBox(msg, title, flags)
  local result = r.ShowMessageBox(msg, title, flags)
  refocus_next_frame = true
  return result
end

local function dlg_GR_SelectColor(hwnd, col)
  local ok, val = r.GR_SelectColor(hwnd, col)
  refocus_next_frame = true
  return ok, val
end

local function dlg_GetUserInputs(title, num, captions, defaults)
  local ok, val = r.GetUserInputs(title, num, captions, defaults)
  refocus_next_frame = true
  return ok, val
end

local function dlg_JS_BrowseForSaveFile(title, folder, default, mask)
  local ok, val = r.JS_Dialog_BrowseForSaveFile(title, folder, default, mask)
  refocus_next_frame = true
  return ok, val
end

local function dlg_JS_BrowseForOpenFiles(title, folder, default, mask, multi)
  local ok, val = r.JS_Dialog_BrowseForOpenFiles(title, folder, default, mask, multi)
  refocus_next_frame = true
  return ok, val
end

local function dlg_JS_BrowseForFolder(title, folder)
  local ok, val = r.JS_Dialog_BrowseForFolder(title, folder)
  refocus_next_frame = true
  return ok, val
end

local function run_and_preserve()
  run()
  -- Close all floating FX and FX chain windows
  r.Main_OnCommand(40770, 0)  -- Close all floating FX windows
  r.Main_OnCommand(40912, 0)  -- Close all FX chain windows (native)
  dlg_ShowMessageBox("Session ReaOrganized!", "ReaOrganize", 0)
end

-- ── Preset persistence via Reaper ExtState ───────────────────────────────────
local EXT_SECTION = "ReaOrganize"

-- ── Preset Export / Import ────────────────────────────────────────────────────

local function preset_to_lines(p, slot)
  local lines = {}
  local function w(k, v) lines[#lines+1] = k .. "=" .. tostring(v) end
  w("preset", p)
  w("name", preset_name_buf[p])
  w("num_groups", #slot.groups)
  w("parent_color", slot.parent_color_packed or pack_color(180,40,40))
  w("parent_utc", slot.parent_use_track_color and "1" or "0")
  w("master_name", slot.master_name or "")
  w("master_fx", slot.master_fx_chain or "")
  w("opt_fx_folder", slot.opt_fx_folder or "")
  w("opt_snd_bot", slot.opt_sends_at_bottom and "1" or "0")
  w("opt_snd_clr", slot.opt_send_color_packed or 0x888888)
  w("opt_snd_utc", slot.opt_send_use_trk_color and "1" or "0")
  w("opt_fx_bins", slot.opt_fx_bypass_inserts and "1" or "0")
  w("opt_fx_bchn", slot.opt_fx_bypass_chains and "1" or "0")
  w("ps_chains",   slot.picker_show_chains ~= false and "1" or "0")
  w("ps_vst3",     slot.picker_show_vst3   ~= false and "1" or "0")
  w("ps_vst",      slot.picker_show_vst    ~= false and "1" or "0")
  w("ps_clap",     slot.picker_show_clap   ~= false and "1" or "0")
  w("ps_js",       slot.picker_show_js     ~= false and "1" or "0")
  for g = 1, #slot.groups do
    local grp = slot.groups[g]
    w("g"..g.."_name",   grp.name)
    w("g"..g.."_color",  grp.color_packed)
    w("g"..g.."_ftmpl",  grp.folder_template or "")
    w("g"..g.."_routes", grp.routes_to or 0)
    w("g"..g.."_pan",    grp.pan_str or "C")
    w("g"..g.."_nsends", #(grp.sends or {}))
    for s = 1, #(grp.sends or {}) do
      local sl = grp.sends[s]
      w("g"..g.."_s"..s.."_tmpl", sl.template or "")
      w("g"..g.."_s"..s.."_name", sl.name or "")
      w("g"..g.."_s"..s.."_clr",  sl.color_packed or 0x888888)
      w("g"..g.."_s"..s.."_pre",  sl.pre_fader and "1" or "0")
    end
  end
  w("num_gs", #(slot.global_sends or {}))
  for s = 1, #(slot.global_sends or {}) do
    local gs = slot.global_sends[s]
    w("gs"..s.."_name", gs.name or "")
    w("gs"..s.."_tmpl", gs.template or "")
    w("gs"..s.."_clr",  gs.color_packed or 0x888888)
    w("gs"..s.."_pre",  gs.pre_fader and "1" or "0")
  end
  return lines
end

local function lines_to_preset(lines)
  local kv = {}
  for _, line in ipairs(lines) do
    local k, v = line:match("^([^=]+)=(.*)$")
    if k then kv[k] = v end
  end
  if not kv["name"] then return nil end
  local slot = { groups = {}, global_sends = {} }
  slot.parent_color_packed    = tonumber(kv["parent_color"])   or pack_color(180,40,40)
  slot.parent_use_track_color = kv["parent_utc"] == "1"
  slot.master_name            = kv["master_name"] or ""
  local mfx = kv["master_fx"] or ""
  slot.master_fx_chain        = mfx ~= "" and mfx or nil
  local ff = kv["opt_fx_folder"] or ""
  slot.opt_fx_folder          = ff ~= "" and ff or nil
  slot.opt_sends_at_bottom    = kv["opt_snd_bot"] == "1"
  slot.opt_send_color_packed  = tonumber(kv["opt_snd_clr"])    or 0x888888
  slot.opt_send_use_trk_color = kv["opt_snd_utc"] == "1"
  slot.opt_fx_bypass_inserts  = kv["opt_fx_bins"] == "1"
  slot.opt_fx_bypass_chains   = kv["opt_fx_bchn"] == "1"
  slot.picker_show_chains = kv["ps_chains"] ~= "0"
  slot.picker_show_vst3   = kv["ps_vst3"]   ~= "0"
  slot.picker_show_vst    = kv["ps_vst"]    ~= "0"
  slot.picker_show_clap   = kv["ps_clap"]   ~= "0"
  slot.picker_show_js     = kv["ps_js"]     ~= "0"
  local ng = tonumber(kv["num_groups"]) or 0
  for g = 1, ng do
    local grp = {}
    grp.name            = kv["g"..g.."_name"] or ("Group "..g)
    grp.color_packed    = tonumber(kv["g"..g.."_color"])  or pack_color(128,128,128)
    local ft = kv["g"..g.."_ftmpl"] or ""
    grp.folder_template = ft ~= "" and ft or nil
    grp.routes_to       = tonumber(kv["g"..g.."_routes"]) or 0
    local ns = tonumber(kv["g"..g.."_nsends"]) or 0
    grp.sends = {}
    for s = 1, ns do
      local tmpl = kv["g"..g.."_s"..s.."_tmpl"] or ""
      grp.sends[s] = {
        template     = tmpl ~= "" and tmpl or nil,
        name         = kv["g"..g.."_s"..s.."_name"] or "",
        color_packed = tonumber(kv["g"..g.."_s"..s.."_clr"]) or 0x888888,
        pre_fader    = kv["g"..g.."_s"..s.."_pre"] == "1",
      }
    end
    if kv["g"..g.."_pan"] then grp.pan_str = kv["g"..g.."_pan"] end
    slot.groups[g] = grp
  end
  local ngs = tonumber(kv["num_gs"]) or 0
  for s = 1, ngs do
    local tmpl2 = kv["gs"..s.."_tmpl"] or ""
    slot.global_sends[s] = {
      name         = kv["gs"..s.."_name"] or "",
      template     = tmpl2 ~= "" and tmpl2 or nil,
      color_packed = tonumber(kv["gs"..s.."_clr"]) or 0x888888,
      pre_fader    = kv["gs"..s.."_pre"] == "1",
    }
  end
  return slot, kv["name"], tonumber(kv["preset"]) or 1
end

local function save_presets()
  -- Serialise all presets into one blob using the same INI format as export.
  -- A single SetExtState call is vastly faster than hundreds of individual ones.
  local all_lines = {"[ReaOrganize_Presets]"}
  for p = 1, NUM_PRESETS do
    -- Always write the name so it persists even for empty slots
    all_lines[#all_lines+1] = "preset_name_" .. p .. "=" .. (preset_name_buf[p] or "")
    if presets[p] then
      all_lines[#all_lines+1] = ""
      all_lines[#all_lines+1] = "[preset_" .. p .. "]"
      for _, line in ipairs(preset_to_lines(p, presets[p])) do
        all_lines[#all_lines+1] = line
      end
    end
  end
  r.SetExtState(EXT_SECTION, "presets_blob", table.concat(all_lines, "||"), true)
end

local function load_presets()
  local blob = r.GetExtState(EXT_SECTION, "presets_blob")
  if blob ~= "" then
    -- ── New path: parse the blob ─────────────────────────────────────────────
    -- First pass: collect preset_name_N lines and sections
    local names = {}
    local sections = {}
    local cur = nil
    for line in (blob .. "||"):gmatch("([^|]*)||") do
      line = line:match("^%s*(.-)%s*$")
      local pname_idx, pname_val = line:match("^preset_name_(%d+)=(.*)$")
      if pname_idx then
        names[tonumber(pname_idx)] = pname_val
      elseif line:match("^%[preset_%d+%]$") then
        local pi = tonumber(line:match("^%[preset_(%d+)%]$"))
        cur = {}; sections[pi] = cur
      elseif cur and line ~= "" and line ~= "[ReaOrganize_Presets]" then
        cur[#cur+1] = line
      end
    end
    -- Only use blob if it actually contains preset sections
    -- Otherwise fall through to legacy path
    if next(sections) ~= nil then
      -- Apply names
      for p = 1, NUM_PRESETS do
        if names[p] and names[p] ~= "" then preset_name_buf[p] = names[p] end
      end
      -- Parse each preset section using lines_to_preset
      for p, lines_arr in pairs(sections) do
        if p >= 1 and p <= NUM_PRESETS then
          local slot = lines_to_preset(lines_arr)
          if slot then
            if names[p] and names[p] ~= "" then slot.name = names[p] end
            presets[p] = slot
          end
        end
      end
      return  -- blob loaded successfully, skip legacy
    end
  end
  do
    -- ── Legacy path: read old per-key ExtState (backwards compat) ────────────
    for p = 1, NUM_PRESETS do
      local stored_name = r.GetExtState(EXT_SECTION, "preset_name_" .. p)
      if stored_name ~= "" then preset_name_buf[p] = stored_name end
      local exists = r.GetExtState(EXT_SECTION, "preset_exists_" .. p)
      if exists == "1" then
        local slot = { groups = {} }
        slot.name                  = preset_name_buf[p]
        slot.parent_color          = tonumber(r.GetExtState(EXT_SECTION, "preset_pcolor_"  .. p)) or pack_color(180,40,40)
        slot.parent_use_track_color = r.GetExtState(EXT_SECTION, "preset_putc_" .. p) == "1"
        local gcount = tonumber(r.GetExtState(EXT_SECTION, "preset_gcount_" .. p)) or 16
        for g = 1, gcount do
          local gname   = r.GetExtState(EXT_SECTION, "preset_" ..p.. "_gname_"  ..g)
          local gcolor  = tonumber(r.GetExtState(EXT_SECTION, "preset_" ..p.. "_gcolor_" ..g))
          local gftmpl  = r.GetExtState(EXT_SECTION, "preset_" ..p.. "_gftmpl_" ..g)
          local groutes = tonumber(r.GetExtState(EXT_SECTION, "preset_" ..p.. "_groutes_"..g)) or 0
          local nsends  = tonumber(r.GetExtState(EXT_SECTION, "preset_" ..p.. "_gsndcnt_"..g)) or 0
          local gsends  = {}
          for s = 1, nsends do
            local tmpl  = r.GetExtState(EXT_SECTION, "preset_"..p.."_gsnd_"    ..g.."_"..s)
            local sname = r.GetExtState(EXT_SECTION, "preset_"..p.."_gsndname_"..g.."_"..s)
            local sclr  = tonumber(r.GetExtState(EXT_SECTION, "preset_"..p.."_gsndclr_"..g.."_"..s)) or 0x888888
            local spre  = r.GetExtState(EXT_SECTION, "preset_"..p.."_gsndpre_" ..g.."_"..s) == "1"
            gsends[s] = { template = tmpl ~= "" and tmpl or nil, name = sname, color_packed = sclr, pre_fader = spre }
          end
          slot.groups[g] = {
            name            = gname  ~= "" and gname  or ("Group " .. g),
            color_packed    = gcolor or pack_color(128,128,128),
            folder_template = gftmpl ~= "" and gftmpl or nil,
            sends           = gsends,
            routes_to       = groutes,
          }
        end
        local ngs = tonumber(r.GetExtState(EXT_SECTION, "preset_"..p.."_gscnt")) or 0
        slot.global_sends = {}
        for s = 1, ngs do
          local gsname = r.GetExtState(EXT_SECTION, "preset_"..p.."_gsname_"..s)
          local gstmpl = r.GetExtState(EXT_SECTION, "preset_"..p.."_gstmpl_"..s)
          local gsclr  = tonumber(r.GetExtState(EXT_SECTION, "preset_"..p.."_gsclr_" ..s)) or 0x888888
          local gspre  = r.GetExtState(EXT_SECTION, "preset_"..p.."_gspre_" ..s) == "1"
          slot.global_sends[s] = { name = gsname, template = gstmpl ~= "" and gstmpl or nil, color_packed = gsclr, pre_fader = gspre }
        end
        slot.opt_fx_folder          = r.GetExtState(EXT_SECTION, "preset_"..p.."_opt_fxfolder")
        if slot.opt_fx_folder == "" then slot.opt_fx_folder = nil end
        slot.opt_sends_folder_top   = r.GetExtState(EXT_SECTION, "preset_"..p.."_opt_sndftp") == "1"
        slot.opt_sends_folder_bot   = r.GetExtState(EXT_SECTION, "preset_"..p.."_opt_sndfbt") == "1"
              slot.opt_sends_at_bottom    = r.GetExtState(EXT_SECTION, "preset_"..p.."_opt_sndbot") == "1"
        slot.opt_send_color_packed  = tonumber(r.GetExtState(EXT_SECTION, "preset_"..p.."_opt_sndclr")) or 0x888888
        slot.opt_send_use_trk_color = r.GetExtState(EXT_SECTION, "preset_"..p.."_opt_sndutc") == "1"
        slot.opt_fx_bypass_inserts  = r.GetExtState(EXT_SECTION, "preset_"..p.."_opt_fxbins") == "1"
        slot.opt_fx_bypass_chains   = r.GetExtState(EXT_SECTION, "preset_"..p.."_opt_fxbchn") == "1"
        slot.parent_color_packed    = tonumber(r.GetExtState(EXT_SECTION, "preset_"..p.."_opt_pcolor")) or pack_color(180,40,40)
        slot.parent_use_track_color = r.GetExtState(EXT_SECTION, "preset_"..p.."_opt_putc") == "1"
        local mstnm = r.GetExtState(EXT_SECTION, "preset_"..p.."_mstnm")
        slot.master_name        = mstnm ~= "" and mstnm or ""
        local mstfx = r.GetExtState(EXT_SECTION, "preset_"..p.."_mstfx")
        slot.picker_show_chains = r.GetExtState(EXT_SECTION, "preset_"..p.."_psChains") ~= "0"
        slot.picker_show_vst3   = r.GetExtState(EXT_SECTION, "preset_"..p.."_psVst3")   ~= "0"
        slot.picker_show_vst    = r.GetExtState(EXT_SECTION, "preset_"..p.."_psVst")    ~= "0"
        slot.picker_show_clap   = r.GetExtState(EXT_SECTION, "preset_"..p.."_psClap")   ~= "0"
        slot.picker_show_js     = r.GetExtState(EXT_SECTION, "preset_"..p.."_psJs")     ~= "0"
        slot.master_fx_chain    = mstfx ~= "" and mstfx or nil
        presets[p] = slot
      end
    end
    -- Migrate: write the blob now so future saves are fast
    save_presets()
  end  -- legacy
end

-- ── GUI ───────────────────────────────────────────────────────────────────────

local function imgui_color_to_packed(col32)
  -- ImGui color is 0xRRGGBBAA, we want 0xRRGGBB
  return (col32 >> 8) & 0xFFFFFF
end

local function fx_preview_label(s)
  if not s then return "-- none --" end
  return s:gsub("%.rfxchain$",""):gsub("%.RfxChain$",""):gsub("%.RFXCHAIN$","")
end

-- Returns the preview label for any FX value (chain path or plugin name)
local function fx_preview(val)
  if not val then return nil end
  -- Strip plugin type prefixes (used internally for TrackFX_AddByName)
  val = val:gsub("^VST3:", ""):gsub("^VST:", ""):gsub("^CLAP:", ""):gsub("^JS:", "JS: ")
  -- Strip .rfxchain extension
  return val:gsub("%.rfxchain$",""):gsub("%.RfxChain$",""):gsub("%.RFXCHAIN$","")
end

-- ── Group tree helpers ───────────────────────────────────────────────────────

-- Returns path from g to root as array: [g, parent(g), ..., root_g]
-- Build active_send_cols: list of all {g, s} pairs across all groups with sends
-- Used to determine dynamic track panel send columns
local function build_active_send_cols()
  local cols = {}
  for g = 1, NUM_GROUPS do
    local grp = groups[g]
    for s = 1, #(grp.sends or {}) do
      cols[#cols+1] = { g = g, s = s }
    end
  end
  return cols
end

-- Returns the effective display color for a group:
-- if it routes into another group (chain of any depth), inherit the root group's color.
local function get_group_display_color(g)
  local cur = g
  local limit = 64
  while limit > 0 do
    local rt = (groups[cur] and groups[cur].routes_to) or 0
    if rt == 0 or rt > NUM_GROUPS then break end
    cur = rt
    limit = limit - 1
  end
  return groups[cur] and groups[cur].color_packed or (groups[g] and groups[g].color_packed) or 0x888888
end

-- Apply a send value to a send slot for all eligible tracks or selected only.
-- val: string to set ("0", "i", "")  g: group index  s: slot index
-- scope: true = all eligible, false = selected eligible only
local function apply_send_slot_value(val, scope_all, g, s)
  local skey = g..":"..s
  for ti, t in ipairs(tracks) do
    local eligible = (t.group ~= NO_GROUP) and
      (t.group == g or is_group_descendant(t.group, g))
    if eligible and (scope_all or t.selected) then
      if not send_track_buf[ti] then send_track_buf[ti] = {} end
      send_track_buf[ti][skey] = val
      if not t.sends then t.sends = {} end
      t.sends[skey] = val
    end
  end
end

-- Apply a send value to ALL send slots across all groups.
local function apply_all_sends_value(val, scope_all)
  for g2 = 1, NUM_GROUPS do
    for s2 = 1, #(groups[g2].sends or {}) do
      if (groups[g2].sends[s2]) then
        apply_send_slot_value(val, scope_all, g2, s2)
      end
    end
  end
end

-- Apply a global send value.
local function apply_global_send_value(val, scope_all, s)
  for ti = 1, #tracks do
    if scope_all or tracks[ti].selected then
      if not global_send_buf[ti] then global_send_buf[ti] = {} end
      global_send_buf[ti][s] = val
    end
  end
end

-- Open an All/Selected/Cancel modal. callback(true)=All, callback(false)=Selected
local function open_scope_modal(title, msg, callback)
  modal_pending = { title = title, msg = msg, callback = callback }
end

local function open_conflict_modal(title, msg, callback)
  conflict_modal_pending = { title = title, msg = msg, callback = callback }
end

local function start_guess_fx_groups()
  if not fx_chain_list then scan_fx_chains() end
  -- Build unified list: groups, global sends, master
  local glist = {}
  for g = 1, NUM_GROUPS do
    glist[#glist+1] = {
      name    = groups[g].name or ("Group "..g),
      get_fx  = function() return groups[g].folder_template end,
      set_fx  = function(v) groups[g].folder_template = v end,
    }
  end
  for s, gs in ipairs(global_sends) do
    glist[#glist+1] = {
      name    = (gs.name ~= "" and gs.name or ("Global Send "..s)),
      get_fx  = function() return gs.template end,
      set_fx  = function(v) gs.template = v end,
    }
  end
  glist[#glist+1] = {
    name    = "Master",
    get_fx  = function() return master_fx_chain end,
    set_fx  = function(v) master_fx_chain = v end,
  }
  if #glist == 0 then return end
  local function find_matches_g(item)
    local results = {}
    local name_lower = (item.name or ""):lower()
    if name_lower == "" then return results end
    for _, entry in ipairs(fx_chain_list) do
      if entry.rel_path and entry.label:lower():find(name_lower, 1, true) then
        results[#results+1] = entry
      end
    end
    return results
  end
  local function advance_g(start_idx)
    for i = start_idx, #glist do
      local item = glist[i]
      local matches = find_matches_g(item)
      local sel = 1
      local cur_fx = item.get_fx()
      if cur_fx then
        for mi, m in ipairs(matches) do
          if m.rel_path == cur_fx then sel = mi; break end
        end
      end
      guess_fx_grp_modal = {
        glist        = glist,
        cur          = i,
        matches      = matches,
        selected     = sel,
        find_matches = find_matches_g,
        advance      = advance_g,
      }
      return
    end
    guess_fx_grp_modal = nil
    dlg_ShowMessageBox("Set Group FX complete.", "Done", 0)
  end
  advance_g(1)
end

local function start_guess_fx()
  if not fx_chain_list then scan_fx_chains() end
  -- Build list of all tracks (all, not just unassigned)
  local tlist = {}
  for i, t in ipairs(tracks) do
    tlist[#tlist+1] = { idx = i, t = t }
  end
  if #tlist == 0 then return end
  -- Find first track with matches and open modal
  local function find_matches(t)
    local results = {}
    local tname_lower = (t.name or ""):lower()
    if tname_lower == "" then return results end
    for _, entry in ipairs(fx_chain_list) do
      if entry.rel_path and entry.label:lower():find(tname_lower, 1, true) then
        results[#results+1] = entry
      end
    end
    return results
  end
  local function advance(start_idx)
    for i = start_idx, #tlist do
      local item = tlist[i]
      local matches = find_matches(item.t)
      -- pre-select current assignment if in list
      local sel = 1
      if item.t.fx_chain then
        for mi, m in ipairs(matches) do
          if m.rel_path == item.t.fx_chain then sel = mi; break end
        end
      end
      guess_fx_modal = {
        tlist       = tlist,
        cur         = i,
        matches     = matches,
        selected    = sel,
        find_matches = find_matches,
        advance     = advance,
      }
      return
    end
    -- Done
    guess_fx_modal = nil
    dlg_ShowMessageBox("Guess Track FX complete.", "Done", 0)
  end
  advance(1)
end



-- Inner capture execution (called directly or from conflict modal callback)
local capture_execute  -- forward declaration
capture_execute = function(folder_tracks, cap, guid_to_slot, fx_root, sep, prefix, suffix, overwrite_mode)
  -- Helper: unique filename if base already exists
  local function unique_fname(base_fname)
    local stem = base_fname:match("^(.-)%.RfxChain$") or base_fname
    local ft = io.open(fx_root .. sep .. base_fname, "r")
    if not ft then return base_fname end
    ft:close()
    local n2 = 1
    while true do
      local candidate = stem .. string.format("_%02d", n2) .. ".RfxChain"
      local ft2 = io.open(fx_root .. sep .. candidate, "r")
      if not ft2 then return candidate end
      ft2:close()
      n2 = n2 + 1
    end
  end

  push_undo()
  for slot = 1, cap do
    local tr  = folder_tracks[slot].tr
    local grp = groups[slot]

    -- Name
    local _, tname = r.GetTrackName(tr)
    grp.name = tname
    rename_group_buf[slot] = tname

    -- Color
    local col_native = r.GetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR")
    if col_native ~= 0 then
      local cr, cg, cb = r.ColorFromNative(col_native)
      grp.color_packed = pack_color(cr, cg, cb)
    end

    -- Pan
    grp.pan_str = format_pan(r.GetMediaTrackInfo_Value(tr, "D_PAN"))

    -- Routing
    grp.routes_to = 0
    local parent = r.GetParentTrack(tr)
    if parent then
      local _, pguid = r.GetSetMediaTrackInfo_String(parent, "GUID", "", false)
      if guid_to_slot[pguid] then grp.routes_to = guid_to_slot[pguid] end
    end

    -- FX chain
    grp.folder_template = nil
    local ok_chunk, chunk = r.GetTrackStateChunk(tr, "", false)
    if ok_chunk and chunk and chunk:find("<FXCHAIN", 1, true) then
      local fxchain_block = nil
      local fs = chunk:find("<FXCHAIN", 1, true)
      if fs then
        local depth2, i2 = 0, fs
        while i2 <= #chunk do
          local c = chunk:sub(i2, i2)
          if c == "<" then depth2 = depth2 + 1
          elseif c == ">" then
            depth2 = depth2 - 1
            if depth2 == 0 then fxchain_block = chunk:sub(fs, i2); break end
          end
          i2 = i2 + 1
        end
      end
      if fxchain_block then
        local safe_name = tname:gsub("[^%w%- _]", "_")
        local fname = prefix .. safe_name .. suffix .. ".RfxChain"
        if overwrite_mode == "unique" then fname = unique_fname(fname) end
        local fpath = fx_root .. sep .. fname
        local f2 = io.open(fpath, "w")
        if f2 then
          f2:write(fxchain_block)
          f2:close()
          grp.folder_template = fname
          fx_chain_list = nil
          picker_combined_list = nil
        end
      end
    end

    -- Clear sends (will be re-populated below)
    for s = 1, #grp.sends do
      grp.sends[s] = { name = "", template = nil,
                       color_packed = opt_send_color_packed, pre = false, pan_str = "" }
    end
  end

  -- ── Helper: extract FX chain from a track and write .RfxChain file ──────
  local function extract_and_save_fx(tr2, name2)
    local ok3, chunk3 = r.GetTrackStateChunk(tr2, "", false)
    if not (ok3 and chunk3 and chunk3:find("<FXCHAIN", 1, true)) then return nil end
    local fs3 = chunk3:find("<FXCHAIN", 1, true)
    local block3, d3, i3 = nil, 0, fs3
    while i3 <= #chunk3 do
      local c3 = chunk3:sub(i3, i3)
      if c3 == "<" then d3 = d3 + 1
      elseif c3 == ">" then d3 = d3 - 1
        if d3 == 0 then block3 = chunk3:sub(fs3, i3); break end
      end
      i3 = i3 + 1
    end
    if not block3 then return nil end
    local safe2 = name2:gsub("[^%w%- _]", "_")
    local fname2 = prefix .. safe2 .. suffix .. ".RfxChain"
    if overwrite_mode == "unique" then fname2 = unique_fname(fname2) end
    local f3 = io.open(fx_root .. sep .. fname2, "w")
    if f3 then f3:write(block3); f3:close()
      fx_chain_list = nil; picker_combined_list = nil
      return fname2
    end
    return nil
  end

  -- ── Capture sends by parent folder ───────────────────────────────────────
  -- Build folder pointer → slot lookup
  local folder_ptr_to_slot = {}
  for slot = 1, cap do
    folder_ptr_to_slot[tostring(folder_tracks[slot].tr)] = slot
  end
  -- Track send slot counters per group
  local grp_send_idx = {}
  for slot = 1, cap do grp_send_idx[slot] = 0 end
  global_sends = {}
  local gs_ptr_seen = {}  -- avoid duplicate global sends
  -- Scan every track in the session
  local total_tr = r.CountTracks(0)
  for ti = 0, total_tr - 1 do
    local tr2 = r.GetTrack(0, ti)
    local depth2 = r.GetMediaTrackInfo_Value(tr2, "I_FOLDERDEPTH")
    local num_receives = r.GetTrackNumSends(tr2, -1)
    -- Only capture tracks that: are not folder tracks AND receive at least one send
    if depth2 ~= 1 and num_receives > 0 then
      local parent2 = r.GetParentTrack(tr2)
      local _, tname2 = r.GetTrackName(tr2)
      local tcol = r.GetMediaTrackInfo_Value(tr2, "I_CUSTOMCOLOR")
      local tc_packed = opt_send_color_packed
      if tcol ~= 0 then
        local tr2, tg2, tb2 = r.ColorFromNative(tcol)
        tc_packed = pack_color(tr2, tg2, tb2)
      end
      local tfx = extract_and_save_fx(tr2, tname2)
      if parent2 then
        -- Has a parent folder — belongs to that group as a send slot
        local slot = folder_ptr_to_slot[tostring(parent2)]
        if slot and grp_send_idx[slot] < MAX_SENDS then
          grp_send_idx[slot] = grp_send_idx[slot] + 1
          local si2 = grp_send_idx[slot]
          groups[slot].sends[si2] = {
            name         = tname2 or "",
            template     = tfx,
            color_packed = tc_packed,
            pre_fader    = false,
            pan_str      = "",
          }
        end
      else
        -- No parent folder → top-level track → global send
        local ptr2 = tostring(tr2)
        if not gs_ptr_seen[ptr2] and #global_sends < MAX_GLOBAL_SENDS then
          gs_ptr_seen[ptr2] = true
          global_sends[#global_sends+1] = {
            name         = tname2 or "",
            template     = tfx,
            color_packed = tc_packed,
            pre_fader    = false,
          }
        end
      end
    end
  end
  -- Clear remaining send slots for each group
  for slot = 1, cap do
    for s = grp_send_idx[slot] + 1, #groups[slot].sends do
      groups[slot].sends[s] = { name = "", template = nil,
                                color_packed = opt_send_color_packed, pre = false, pan_str = "" }
    end
  end

  -- ── Capture master FX chain ───────────────────────────────────────────────
  local mtr = r.GetMasterTrack(0)
  if mtr then
    master_fx_chain = extract_and_save_fx(mtr, "Master")
  end

  dlg_ShowMessageBox(
    "Captured " .. cap .. " folder track(s), " .. #global_sends .. " global send(s) and master FX into group panel.",
    "Capture OK", 0)
end

local function capture_from_session()
  -- Step 1: Confirm overwrite of group panel
  if dlg_ShowMessageBox(
    "Capture all folder tracks from the current session?\n" ..
    "This will overwrite the current group panel.",
    "Capture from Session", 4) ~= 6 then return end

  -- Step 2: Ask for prefix and suffix
  local default_suffix = os.date("%d%m%Y")
  local ok_suf, suf_val = dlg_GetUserInputs("FX Chain Name",
    2, "Prefix:,Suffix:", "," .. default_suffix)
  if not ok_suf then return end
  local cap_prefix, cap_suffix = suf_val:match("^([^,]*),(.*)$")
  cap_prefix = cap_prefix or ""
  cap_suffix = cap_suffix or ""
  local prefix = cap_prefix ~= "" and (cap_prefix .. "_") or ""
  local suffix = cap_suffix ~= "" and ("_" .. cap_suffix) or ""

  -- Step 3: Collect folder tracks
  local folder_tracks = {}
  local n = r.CountTracks(0)
  for i = 0, n - 1 do
    local tr = r.GetTrack(0, i)
    if r.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH") == 1 then
      folder_tracks[#folder_tracks+1] = { tr = tr, idx = i }
    end
  end

  if #folder_tracks == 0 then
    dlg_ShowMessageBox("No folder tracks found in session.", "Capture", 0)
    return
  end

  local cap = math.min(#folder_tracks, MAX_GROUPS)

  -- Auto-add groups if needed
  if cap > NUM_GROUPS then
    for g2 = NUM_GROUPS + 1, cap do
      groups[g2] = {
        name         = "Group " .. g2,
        color_packed = random_color(),
        sends        = {},
        routes_to    = 0,
        pan_str      = "C",
      }
      rename_group_buf[g2] = "Group " .. g2
    end
    NUM_GROUPS = cap
  end
  if #folder_tracks > MAX_GROUPS then
    dlg_ShowMessageBox(
      "Found " .. #folder_tracks .. " folder tracks but MAX_GROUPS (" ..
      MAX_GROUPS .. ") reached.\nCapturing first " .. cap .. ".",
      "Capture Warning", 0)
  end

  -- Step 4: FX folder setup
  local base    = r.GetResourcePath()
  local sep     = base:find("\\") and "\\" or "/"
  local fx_root = (opt_fx_folder and opt_fx_folder ~= "")
                  and opt_fx_folder or (base .. sep .. "FXChains")

  -- Step 5: Build GUID→slot lookup
  local guid_to_slot = {}
  for slot = 1, cap do
    local _, gg = r.GetSetMediaTrackInfo_String(folder_tracks[slot].tr, "GUID", "", false)
    guid_to_slot[gg] = slot
  end

  -- Step 6: Pre-scan for filename conflicts
  local conflicts = {}
  for slot = 1, cap do
    local _, tname = r.GetTrackName(folder_tracks[slot].tr)
    local safe_name = tname:gsub("[^%w%- _]", "_")
    local fname = prefix .. safe_name .. suffix .. ".RfxChain"
    local ft = io.open(fx_root .. sep .. fname, "r")
    if ft then ft:close(); conflicts[#conflicts+1] = fname end
  end

  -- Step 7: Show conflict modal or execute directly
  if #conflicts > 0 then
    local conflict_list = table.concat(conflicts, "\n  ")
    open_conflict_modal(
      "File Conflict",
      #conflicts .. " FX chain file(s) already exist:\n  " .. conflict_list,
      function(mode)
        if mode then
          capture_execute(folder_tracks, cap, guid_to_slot, fx_root, sep, prefix, suffix, mode)
        end
      end)
    return
  end

  -- No conflicts: run directly
  capture_execute(folder_tracks, cap, guid_to_slot, fx_root, sep, prefix, suffix, "overwrite")
end
local function export_presets()
  -- Build all lines for all stored presets
  local all_lines = {"[ReaOrganize_Presets]"}
  for p = 1, NUM_PRESETS do
    if presets[p] then
      all_lines[#all_lines+1] = ""
      all_lines[#all_lines+1] = "[preset_"..p.."]"
      for _, line in ipairs(preset_to_lines(p, presets[p])) do
        all_lines[#all_lines+1] = line
      end
    end
  end
  -- Try js_ReaScriptAPI save dialog; fall back to resource path
  local out_path
  if r.JS_Dialog_BrowseForSaveFile then
    local ok, path = dlg_JS_BrowseForSaveFile("Export ReaOrganize Presets",
      r.GetProjectPath("") ~= "" and r.GetProjectPath("") or r.GetResourcePath(), 
      "reaorganize_presets.roPre", "ReaOrganize Presets (*.roPre) *.roPre All files *.* ")
    if ok == 1 and path and path ~= "" then
      out_path = path
      if not out_path:match("%.roPre$") then out_path = out_path .. ".roPre" end
    end
  else
    out_path = r.GetResourcePath() .. "/session_presets.roPre"
  end
  if not out_path then return end
  local f = io.open(out_path, "w")
  if not f then
    dlg_ShowMessageBox("Could not write file:\n" .. out_path, "Export Error", 0)
    return
  end
  f:write(table.concat(all_lines, "\n") .. "\n")
  f:close()
  dlg_ShowMessageBox("Presets exported to:\n" .. out_path, "Export OK", 0)
end

local function import_presets()
  local in_path
  if r.JS_Dialog_BrowseForOpenFiles then
    local ok, path = dlg_JS_BrowseForOpenFiles("Import ReaOrganize Presets",
      r.GetProjectPath("") ~= "" and r.GetProjectPath("") or r.GetResourcePath(),
      "", "ReaOrganize Presets (*.roPre) *.roPre All files *.* ", false)
    if ok == 1 and path and path ~= "" then in_path = path end
  else
    -- Manual fallback: ask user to type path
    local ok2, path2 = dlg_GetUserInputs("Import Presets", 1, "File path:", "")
    if ok2 and path2 ~= "" then in_path = path2 end
  end
  if not in_path then return end
  local f = io.open(in_path, "r")
  if not f then
    dlg_ShowMessageBox("Could not read file:\n" .. in_path, "Import Error", 0)
    return
  end
  local lines_by_section = {}
  local cur_section = nil
  for line in f:lines() do
    line = line:match("^%s*(.-)%s*$")
    if line:match("^%[preset_%d+%]$") then
      cur_section = {}
      lines_by_section[#lines_by_section+1] = cur_section
    elseif cur_section and line ~= "" and not line:match("^%[") then
      cur_section[#cur_section+1] = line
    end
  end
  f:close()
  if #lines_by_section == 0 then
    dlg_ShowMessageBox("No valid presets found in file.", "Import Error", 0)
    return
  end
  push_undo()
  local imported = 0
  for _, sec_lines in ipairs(lines_by_section) do
    local slot, sname, p_idx = lines_to_preset(sec_lines)
    if slot and p_idx and p_idx >= 1 and p_idx <= NUM_PRESETS then
      slot.name              = sname or ("Preset "..p_idx)
      presets[p_idx]         = slot
      preset_name_buf[p_idx] = slot.name
      imported = imported + 1
    end
  end
  save_presets()
  dlg_ShowMessageBox("Imported " .. imported .. " preset(s).", "Import OK", 0)
end

local function draw_gui()
  -- Swap: previous frame's detection becomes this frame's highlight
  focused_track_send      = focused_track_send_next
  focused_track_send_next = nil

  -- ── Refocus after native dialogs ───────────────────────────────────────────
  if refocus_next_frame then
    r.ImGui_SetNextWindowFocus(ctx)
    refocus_next_frame = false
  end

  -- ── Execute deferred R/A color actions (modifier read after window refocus) ──
  if pending_color_action then
    local pca = pending_color_action
    pending_color_action = nil
    local pmod_ctrl  = r.ImGui_IsKeyDown(ctx, r.ImGui_Key_LeftCtrl   and r.ImGui_Key_LeftCtrl()   or 641) or
                       r.ImGui_IsKeyDown(ctx, r.ImGui_Key_RightCtrl  and r.ImGui_Key_RightCtrl()  or 645)
    local pmod_shift = r.ImGui_IsKeyDown(ctx, r.ImGui_Key_LeftShift  and r.ImGui_Key_LeftShift()  or 640) or
                       r.ImGui_IsKeyDown(ctx, r.ImGui_Key_RightShift and r.ImGui_Key_RightShift() or 644)
    local g2 = pca.g
    if pca.action == "R" then
      push_undo()
      local new_cp = random_color()
      groups[g2].color_packed = new_cp
      if pmod_ctrl then
        for gg = 1, NUM_GROUPS do
          if group_selected[gg] and gg ~= g2 then groups[gg].color_packed = new_cp end
        end
      elseif pmod_shift then
        local sub = groups_in_subtree(g2)
        for gg = 1, NUM_GROUPS do
          if sub[gg] and gg ~= g2 then groups[gg].color_packed = new_cp end
        end
      end
    elseif pca.action == "A" then
      push_undo()
      groups[g2].color_packed = cycle_brightness(groups[g2].color_packed)
      if pmod_ctrl then
        for gg = 1, NUM_GROUPS do
          if group_selected[gg] and gg ~= g2 then
            groups[gg].color_packed = cycle_brightness(groups[gg].color_packed)
          end
        end
      elseif pmod_shift then
        local sub = groups_in_subtree(g2)
        for gg = 1, NUM_GROUPS do
          if sub[gg] and gg ~= g2 then
            groups[gg].color_packed = cycle_brightness(groups[gg].color_packed)
          end
        end
      end
    end
  end

  -- ── Capture modifiers at mouse-down (before any blocking dialog steals focus) ──
  do
    local k_lshift = r.ImGui_Key_LeftShift  and r.ImGui_Key_LeftShift()  or 640
    local k_rshift = r.ImGui_Key_RightShift and r.ImGui_Key_RightShift() or 644
    local k_lctrl  = r.ImGui_Key_LeftCtrl   and r.ImGui_Key_LeftCtrl()   or 641
    local k_rctrl  = r.ImGui_Key_RightCtrl  and r.ImGui_Key_RightCtrl()  or 645
    if r.ImGui_IsMouseClicked(ctx, 0) then
      mouse_down_mod_shift = r.ImGui_IsKeyDown(ctx, k_lshift) or r.ImGui_IsKeyDown(ctx, k_rshift)
      mouse_down_mod_ctrl  = r.ImGui_IsKeyDown(ctx, k_lctrl)  or r.ImGui_IsKeyDown(ctx, k_rctrl)
    end
  end

  -- ── Debounce flush ───────────────────────────────────────────────────────
  if undo_debounce and (r.time_precise() - undo_debounce.time) >= DEBOUNCE_SEC then
    undo_stack[#undo_stack + 1] = undo_debounce.snapshot
    if #undo_stack > UNDO_MAX then table.remove(undo_stack, 1) end
    redo_stack = {}
    undo_debounce = nil
  end

  -- ── Keyboard shortcuts: Ctrl+Z / Ctrl+Y ─────────────────────────────────
  do
    local k_lctrl  = r.ImGui_Key_LeftCtrl  and r.ImGui_Key_LeftCtrl()  or 641
    local k_rctrl  = r.ImGui_Key_RightCtrl and r.ImGui_Key_RightCtrl() or 645
    local k_z      = r.ImGui_Key_Z         and r.ImGui_Key_Z()         or 1050
    local k_y      = r.ImGui_Key_Y         and r.ImGui_Key_Y()         or 1049
    local ctrl = r.ImGui_IsKeyDown(ctx, k_lctrl) or r.ImGui_IsKeyDown(ctx, k_rctrl)
    if ctrl then
      if r.ImGui_IsKeyPressed(ctx, k_z) then do_undo() end
      if r.ImGui_IsKeyPressed(ctx, k_y) then do_redo() end
    end
  end

  -- ── Track table ────────────────────────────────────────────────────────────
  -- ── Top-level two-column layout: Groups+Presets LEFT, Tracks RIGHT ──────────
  local avail_w, avail_h = r.ImGui_GetContentRegionAvail(ctx)
  local groups_w   = 599   -- fixed width for left panel (widened for Set button in vals col)
  local gap        = 8
  local tracks_w   = avail_w - groups_w - gap

  -- ════════════════════════════════════════════════════════════════════════════
  -- LEFT PANEL: Groups + Presets
  -- ════════════════════════════════════════════════════════════════════════════
  if r.ImGui_BeginChild(ctx, "left_scroll", groups_w, avail_h) then
  groups_w = select(1, r.ImGui_GetContentRegionAvail(ctx))  -- adjust for scrollbar

  -- ── Panel header: "Groups" label row ──────────────────────────────────────
  if r.ImGui_BeginTable(ctx, "lhdr", 1, r.ImGui_TableFlags_BordersOuter(), groups_w, 0) then
    r.ImGui_TableSetupColumn(ctx, "Groups", r.ImGui_TableColumnFlags_WidthStretch())
    r.ImGui_TableHeadersRow(ctx)
    r.ImGui_EndTable(ctx)
  end

  -- ── Groups: single scrollable table of all 16 ─────────────────────────────
  local grp_flags = r.ImGui_TableFlags_BordersOuter()
    | r.ImGui_TableFlags_BordersInnerV()

  local pending_delete      = nil  -- group index to delete after the loop
  local pending_delete_list = nil  -- list of group indices (ctrl+click multi-delete)
  local pending_move        = nil  -- {src=, dst=} group reorder after the loop
  if r.ImGui_BeginTable(ctx, "grp_main", 6, grp_flags, groups_w, 0) then
    r.ImGui_TableSetupColumn(ctx, "#",          r.ImGui_TableColumnFlags_WidthFixed(),  42)
    r.ImGui_TableSetupColumn(ctx, "Group Name", r.ImGui_TableColumnFlags_WidthStretch())
    r.ImGui_TableSetupColumn(ctx, "##del",      r.ImGui_TableColumnFlags_WidthFixed(),  22)
    r.ImGui_TableSetupColumn(ctx, "Color",      r.ImGui_TableColumnFlags_WidthFixed(),  76)
    r.ImGui_TableSetupColumn(ctx, "##vals",     r.ImGui_TableColumnFlags_WidthFixed(), 100)
    r.ImGui_TableSetupColumn(ctx, "##prepost",  r.ImGui_TableColumnFlags_WidthFixed(),  28)
    r.ImGui_TableNextRow(ctx, r.ImGui_TableRowFlags_Headers())
    local grp_hdr = { [0]="##grphdr0", [1]="Group Name", [2]="##del", [3]="Color", [4]="##vals", [5]="##prepost_hdr" }
    local grp_table_left_x = 0
    local grp_cell_pad_x   = 0
    for ci = 0, 5 do
      r.ImGui_TableSetColumnIndex(ctx, ci)
      if ci == 0 then
        grp_table_left_x, _ = r.ImGui_GetCursorScreenPos(ctx)
        grp_cell_pad_x, _   = r.ImGui_GetStyleVar(ctx, r.ImGui_StyleVar_CellPadding())
      end
      if ci == 3 then
        -- Center "Color" label manually
        local col_w = r.ImGui_GetContentRegionAvail(ctx)
        local txt_w = r.ImGui_CalcTextSize(ctx, "Color")
        local offset = math.max(0, math.floor((col_w - txt_w) / 2))
        r.ImGui_SetCursorPosX(ctx, r.ImGui_GetCursorPosX(ctx) + offset)
        r.ImGui_TableHeader(ctx, "Color")
      else
        r.ImGui_TableHeader(ctx, grp_hdr[ci])
      end
    end
    -- outer left border is at cursor_x - cell_padding_x (- 1 for border pixel)
    local grp_line_x0 = grp_table_left_x - grp_cell_pad_x - 1
    local grp_line_x1 = grp_line_x0 + groups_w + 1
    local grp_dl = r.ImGui_GetWindowDrawList(ctx)
    -- Modifier keys and selection snapshot captured ONCE before the loop,
    -- so checkbox Ctrl+click cannot mutate group_selected mid-render.
    local grp_mod_alt   = r.ImGui_IsKeyDown(ctx, r.ImGui_Key_LeftAlt    and r.ImGui_Key_LeftAlt()    or 642) or
                          r.ImGui_IsKeyDown(ctx, r.ImGui_Key_RightAlt   and r.ImGui_Key_RightAlt()   or 646)
    local grp_mod_shift = r.ImGui_IsKeyDown(ctx, r.ImGui_Key_LeftShift  and r.ImGui_Key_LeftShift()  or 640) or
                          r.ImGui_IsKeyDown(ctx, r.ImGui_Key_RightShift and r.ImGui_Key_RightShift() or 644)
    local grp_mod_ctrl  = r.ImGui_IsKeyDown(ctx, r.ImGui_Key_LeftCtrl   and r.ImGui_Key_LeftCtrl()   or 641) or
                          r.ImGui_IsKeyDown(ctx, r.ImGui_Key_RightCtrl  and r.ImGui_Key_RightCtrl()  or 645)
    local grp_sel_snap  = {}  -- snapshot of selection for multi-apply (not affected by mid-loop changes)
    for _sg = 1, NUM_GROUPS do grp_sel_snap[_sg] = group_selected[_sg] or false end
    for g = 1, NUM_GROUPS do
      -- ── Row A: group number / name / color ──────────────────────────────────
      r.ImGui_TableNextRow(ctx)
      r.ImGui_TableSetColumnIndex(ctx, 0)
      -- Thin divider 3px above top of this row (except first group), giving a small gap
      if g > 1 then
        local _, ly = r.ImGui_GetCursorScreenPos(ctx)
        r.ImGui_DrawList_AddLine(grp_dl, grp_line_x0, ly - 3, grp_line_x1, ly - 3, 0x555555FF, 1)
      end
      -- Alias to loop-local names (kept for readability in column code below)
      local mod_alt   = grp_mod_alt
      local mod_shift = grp_mod_shift
      local mod_ctrl  = grp_mod_ctrl
      -- Selection checkbox (also drag handle for reordering)
      local is_gsel = group_selected[g] or false
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_CheckMark(), is_gsel and 0x55BBFFFF or 0x666666FF)
      local cb_chg, cb_new = r.ImGui_Checkbox(ctx, tostring(g).."##gsel"..g, is_gsel)
      r.ImGui_PopStyleColor(ctx)
      if cb_chg then
        if mod_alt then
          -- Alt+Click: exclusive select
          for gg = 1, NUM_GROUPS do group_selected[gg] = false end
          group_selected[g] = true
        elseif mod_shift and last_clicked_group then
          -- Shift+Click: range select
          local lo = math.min(last_clicked_group, g)
          local hi = math.max(last_clicked_group, g)
          for gg = lo, hi do group_selected[gg] = true end
        elseif mod_ctrl then
          -- Ctrl+Click: exclusive select all with same destination
          local dest = groups[g].routes_to or 0
          for gg = 1, NUM_GROUPS do
            group_selected[gg] = ((groups[gg].routes_to or 0) == dest)
          end
        else
          -- Plain click: additive toggle
          group_selected[g] = cb_new
        end
        last_clicked_group = g
      end
      -- Drag source (reorder groups by dragging the checkbox)
      if r.ImGui_BeginDragDropSource(ctx, r.ImGui_DragDropFlags_None and r.ImGui_DragDropFlags_None() or 0) then
        r.ImGui_SetDragDropPayload(ctx, "GROUP_MOVE", tostring(g))
        if grp_mod_ctrl and grp_sel_snap[g] then
          -- Show count of selected groups being moved
          local n = 0; for gg=1,NUM_GROUPS do if grp_sel_snap[gg] then n=n+1 end end
          r.ImGui_Text(ctx, "Move " .. n .. " groups")
        else
          r.ImGui_Text(ctx, "Move: " .. groups[g].name)
        end
        r.ImGui_EndDragDropSource(ctx)
      end
      -- Drop target: whole row
      if r.ImGui_BeginDragDropTarget(ctx) then
        local ok_payload, payload_data = r.ImGui_AcceptDragDropPayload(ctx, "GROUP_MOVE")
        if ok_payload then
          local src_g = tonumber(payload_data)
          if src_g and src_g ~= g then
            -- Read ctrl fresh at drop time
            local drop_ctrl = r.ImGui_IsKeyDown(ctx, r.ImGui_Key_LeftCtrl and r.ImGui_Key_LeftCtrl() or 641) or
                              r.ImGui_IsKeyDown(ctx, r.ImGui_Key_RightCtrl and r.ImGui_Key_RightCtrl() or 645)
            pending_move = { src = src_g, dst = g, multi = drop_ctrl and grp_sel_snap[src_g] }
          end
        end
        r.ImGui_EndDragDropTarget(ctx)
      end
      r.ImGui_TableSetColumnIndex(ctx, 1)
      do
        local col1_w = r.ImGui_GetContentRegionAvail(ctx)
        local half_w = math.floor(col1_w / 3) - 2
        r.ImGui_SetNextItemWidth(ctx, half_w)
        local gitflags = r.ImGui_InputTextFlags_AutoSelectAll()
        local gc, gv = r.ImGui_InputText(ctx, "##gname"..g.."_v"..group_load_version, rename_group_buf[g], gitflags)
        if gc then
          push_undo_debounced()
          rename_group_buf[g] = gv
          groups[g].name = gv
        end
        r.ImGui_SameLine(ctx, 0, 4)
        -- Folder FX button + clear
        local ftmpl = groups[g].folder_template
        local ftpreview = fx_preview(ftmpl) or "-- FX --"
        local ftx_w = ftmpl and 26 or 0
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        ftmpl and 0x1a3a1aFF or 0x2a2a2aFF)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), ftmpl and 0x2a5a2aFF or 0x3a3a3aFF)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(),          ftmpl and 0xAAFFAAFF or 0x888888FF)
        if r.ImGui_Button(ctx, ftpreview .. "##ftbtn"..g, -1 - ftx_w, 0) then
          open_picker("folder", nil, g, nil)
          -- Read modifiers FRESH at click time (before any blocking dialog)
          local fmod_ctrl  = r.ImGui_IsKeyDown(ctx, r.ImGui_Key_LeftCtrl  and r.ImGui_Key_LeftCtrl()  or 641) or r.ImGui_IsKeyDown(ctx, r.ImGui_Key_RightCtrl and r.ImGui_Key_RightCtrl() or 645)
          local fmod_shift = r.ImGui_IsKeyDown(ctx, r.ImGui_Key_LeftShift and r.ImGui_Key_LeftShift() or 640) or r.ImGui_IsKeyDown(ctx, r.ImGui_Key_RightShift and r.ImGui_Key_RightShift() or 644)
          if picker_state then picker_state.mod_ctrl = fmod_ctrl; picker_state.mod_shift = fmod_shift end
          picker_multi_group_apply = fmod_ctrl
        end
        r.ImGui_PopStyleColor(ctx, 3)
        if ftmpl then
          r.ImGui_SameLine(ctx, 0, 4)
          r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x5a1a1aFF)
          r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x8a2a2aFF)
          if r.ImGui_Button(ctx, "x##ftclr"..g, 22, 0) then
            if mouse_down_mod_ctrl then
              -- Ctrl+Click: clear FX on all selected groups
              local sel_names = {}
              for gg = 1, NUM_GROUPS do
                if group_selected[gg] and groups[gg].folder_template then
                  sel_names[#sel_names+1] = groups[gg].name
                end
              end
              if groups[g].folder_template and not group_selected[g] then
                sel_names[#sel_names+1] = groups[g].name
              end
              local msg = #sel_names > 0
                and ("Clear folder FX on: " .. table.concat(sel_names, ", ") .. "?")
                or  "Clear folder FX?"
              if dlg_ShowMessageBox(msg, "Clear FX", 4) == 6 then
                push_undo()
                groups[g].folder_template = nil
                for gg = 1, NUM_GROUPS do
                  if group_selected[gg] then groups[gg].folder_template = nil end
                end
              end
            else
              if dlg_ShowMessageBox("Clear folder FX?", "Clear FX", 4) == 6 then
                push_undo(); groups[g].folder_template = nil
              end
            end
          end
          r.ImGui_PopStyleColor(ctx, 2)
        end
      end
      -- Col 2: delete group button (Ctrl+Click: delete all selected)
      r.ImGui_TableSetColumnIndex(ctx, 2)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x5a1a1aFF)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x8a2a2aFF)
      if r.ImGui_Button(ctx, "x##delg"..g, 22, 0) then
        if mod_ctrl then
          local sel_list, sel_names = {}, {}
          for gg = 1, NUM_GROUPS do
            if grp_sel_snap[gg] then
              sel_list[#sel_list+1] = gg
              sel_names[#sel_names+1] = groups[gg].name
            end
          end
          if #sel_list > 0 then
            local msg = "Delete " .. #sel_list .. " selected group(s)?\n" .. table.concat(sel_names, ", ")
            if dlg_ShowMessageBox(msg, "Delete Groups", 4) == 6 then
              push_undo(); pending_delete_list = sel_list
            end
          else
            if dlg_ShowMessageBox('Delete group "' .. groups[g].name .. '"?', "Delete Group", 4) == 6 then
              push_undo(); pending_delete = g
            end
          end
        else
          if dlg_ShowMessageBox('Delete group "' .. groups[g].name .. '"?', "Delete Group", 4) == 6 then
            push_undo()
            pending_delete = g
          end
        end
      end
      r.ImGui_PopStyleColor(ctx, 2)
      -- Col 3: group color swatch + RDM
      -- Ctrl+Click: apply to all selected groups
      -- Shift+Click: apply to this group and all groups in its subtree
      r.ImGui_TableSetColumnIndex(ctx, 3)
      do
        local own_cp = groups[g].color_packed  -- always show/edit own color
        local ic = to_imgui_color(own_cp, 255)
        local cb_flags = r.ImGui_ColorEditFlags_NoTooltip() | r.ImGui_ColorEditFlags_NoBorder()
        if r.ImGui_ColorButton(ctx, "##gcolor"..g, ic, cb_flags, 22, 20) then
          -- Use pre-captured modifiers (grp_mod_*) — fresh IsKeyDown can fail before
          -- the window has keyboard focus (e.g. first click after preset load).
          -- GR_SelectColor is blocking so we capture mod state NOW, before it opens.
          local cmod_ctrl  = mouse_down_mod_ctrl
          local cmod_shift = mouse_down_mod_shift
          local rv8, gv8, bv8 = unpack_color(own_cp)
          local ok, nn = dlg_GR_SelectColor(r.GetMainHwnd(), r.ColorToNative(rv8, gv8, bv8))
          if ok ~= 0 then
            push_undo()
            local nr, ng2, nb = r.ColorFromNative(nn)
            local new_cp = pack_color(nr, ng2, nb)
            groups[g].color_packed = new_cp
            if cmod_ctrl then
              for gg = 1, NUM_GROUPS do
                if group_selected[gg] and gg ~= g then groups[gg].color_packed = new_cp end
              end
            elseif cmod_shift then
              local sub = groups_in_subtree(g)
              for gg = 1, NUM_GROUPS do
                if sub[gg] and gg ~= g then groups[gg].color_packed = new_cp end
              end
            end
          end
        end
        r.ImGui_SameLine(ctx, 0, 4)
        if r.ImGui_Button(ctx, "R##grdm"..g, 22, 20) then
          pending_color_action = { g = g, action = "R" }
        end
        r.ImGui_SameLine(ctx, 0, 4)
        if r.ImGui_Button(ctx, "A##gbrt"..g, 22, 20) then
          pending_color_action = { g = g, action = "A" }
        end
      end
      -- Col 4: routing dropdown (Row A — vals col is empty on this row)
      r.ImGui_TableSetColumnIndex(ctx, 4)
      do
        local rt = groups[g].routes_to or 0
        local rt_full = (rt == 0) and "-> Master" or ("-> " .. groups[rt].name)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        rt ~= 0 and 0x1a2a3aFF or 0x222222FF)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), rt ~= 0 and 0x2a4a6aFF or 0x333333FF)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(),          rt ~= 0 and 0xAADDFFFF or 0x666666FF)
        local _avail_rt = r.ImGui_GetContentRegionAvail(ctx); r.ImGui_SetNextItemWidth(ctx, _avail_rt)
        if r.ImGui_BeginCombo(ctx, "##rta"..g, rt_full) then
          r.ImGui_PopStyleColor(ctx, 3)
          local is_master = (rt == 0)
          if r.ImGui_Selectable(ctx, "-> Master##rtam"..g, is_master) and not is_master then
            push_undo()
            if mod_ctrl then
              for gg = 1, NUM_GROUPS do if grp_sel_snap[gg] then groups[gg].routes_to = 0 end end
            end
            groups[g].routes_to = 0
          end
          for g2 = 1, NUM_GROUPS do
            if g2 ~= g and not would_create_routing_cycle(g, g2) then
              local is_rt_match = (rt == g2)
              if r.ImGui_Selectable(ctx, "-> "..groups[g2].name.."##rtag"..g.."_"..g2, is_rt_match) and not is_rt_match then
                push_undo()
                if mod_ctrl then
                  for gg = 1, NUM_GROUPS do
                    if grp_sel_snap[gg] and not would_create_routing_cycle(gg, g2) then
                      groups[gg].routes_to = g2
                    end
                  end
                end
                groups[g].routes_to = g2
              end
              if is_rt_match then r.ImGui_SetItemDefaultFocus(ctx) end
            end
          end
          r.ImGui_EndCombo(ctx)
        else
          r.ImGui_PopStyleColor(ctx, 3)
        end
      end

      -- Col 5: group pan field
      r.ImGui_TableSetColumnIndex(ctx, 5)
      do
        local gpan_cur = groups[g].pan_str or "C"
        if gpan_cur == "" then gpan_cur = "C" end
        local gpan_valid = (gpan_cur == "") or (parse_pan(gpan_cur) ~= nil)
        local char_w = 7
        local field_w = 18
        local text_w = #gpan_cur * char_w
        local pad_x = math.max(1, math.floor((field_w - text_w) / 2) + 6)
        r.ImGui_SetNextItemWidth(ctx, -1)
        r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FramePadding(), pad_x, 3)
        if not gpan_valid then
          r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBg(), 0x6e1a1aFF)
        end
        local gpan_ch, gpan_val = r.ImGui_InputText(ctx, "##gpan"..g, gpan_cur,
          r.ImGui_InputTextFlags_AutoSelectAll())
        if not gpan_valid then r.ImGui_PopStyleColor(ctx) end
        r.ImGui_PopStyleVar(ctx)
        if gpan_ch then push_undo_debounced(); groups[g].pan_str = gpan_val end
      end

        -- ── Rows B1..B5: one row per send slot + optional + button ────────────────
      local num_sends = #groups[g].sends
      for s = 1, MAX_SENDS do
        num_sends = #groups[g].sends  -- recompute: a deletion in this frame shrinks the array
        local slot_exists = (s <= num_sends)
        local send_removed = false  -- must be in outer scope so col5 guard works
        r.ImGui_TableNextRow(ctx)
        -- Highlight this row if the corresponding send field is focused in the tracks panel
        local is_highlighted = focused_track_send and focused_track_send.g == g and focused_track_send.s == s
        if is_highlighted then
          r.ImGui_TableSetBgColor(ctx, r.ImGui_TableBgTarget_RowBg1(), 0x2a4a6aFF)
        end

        -- Col 0: "S1"-"S5" label if slot exists, "+" button on first empty slot
        r.ImGui_TableSetColumnIndex(ctx, 0)
        if slot_exists then
          local col_w = r.ImGui_GetContentRegionAvail(ctx)
          local lbl = "S"..s
          local tw = r.ImGui_CalcTextSize(ctx, lbl)
          local _, fp_ys = r.ImGui_GetStyleVar(ctx, r.ImGui_StyleVar_FramePadding())
          r.ImGui_SetCursorPosX(ctx, r.ImGui_GetCursorPosX(ctx) + math.max(0, (col_w - tw) / 2))
          r.ImGui_SetCursorPosY(ctx, r.ImGui_GetCursorPosY(ctx) + fp_ys)
          r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xAAAAAAAA)
          r.ImGui_Text(ctx, lbl)
          r.ImGui_PopStyleColor(ctx, 1)
        elseif s == num_sends + 1 and num_sends < MAX_SENDS then
          r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x1a3a1aFF)
          r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x2a6a2aFF)
          if r.ImGui_Button(ctx, "+##sadd"..g.."_"..s, 22, 0) then
            push_undo()
            groups[g].sends[s] = { name = "", template = nil, color_packed = opt_send_color_packed, pre_fader = false }
          end
          r.ImGui_PopStyleColor(ctx, 2)
        end
        -- Col 1: name field (left half) + template label (right half)
        r.ImGui_TableSetColumnIndex(ctx, 1)
        if slot_exists then
          local col_w = r.ImGui_GetContentRegionAvail(ctx)
          local half_w = math.floor(col_w / 3) - 2
          -- Name field
          if is_highlighted then
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Border(), 0xFFFFFFCCFF)
            r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FrameBorderSize(), 1.5)
          end
          r.ImGui_SetNextItemWidth(ctx, half_w)
          local sn = groups[g].sends[s].name or ""
          local sn_changed, sn_val = r.ImGui_InputText(ctx, "##sname"..g.."_"..s, sn,
            r.ImGui_InputTextFlags_AutoSelectAll())
          if is_highlighted then
            r.ImGui_PopStyleColor(ctx, 1)
            r.ImGui_PopStyleVar(ctx)
          end
          if sn_changed then push_undo_debounced(); groups[g].sends[s].name = sn_val end
          r.ImGui_SameLine(ctx, 0, 4)
          -- Send FX button + clear
          local tmpl = groups[g].sends[s].template
          local stpreview = fx_preview(tmpl) or "-- FX --"
          local stx_w = tmpl and 26 or 0
          if is_highlighted then
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Border(), 0xFFFFFFCCFF)
            r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FrameBorderSize(), 1.5)
          end
          r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        tmpl and 0x1a3a1aFF or 0x2a2a2aFF)
          r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), tmpl and 0x2a5a2aFF or 0x3a3a3aFF)
          r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(),          tmpl and 0xAAFFAAFF or 0x888888FF)
          if r.ImGui_Button(ctx, stpreview .. "##stbtn"..g.."_"..s, -1 - stx_w, 0) then
            open_picker("send", nil, g, s)
          end
          r.ImGui_PopStyleColor(ctx, 3)
          if is_highlighted then r.ImGui_PopStyleColor(ctx, 1); r.ImGui_PopStyleVar(ctx) end
          if tmpl then
            r.ImGui_SameLine(ctx, 0, 4)
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x5a1a1aFF)
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x8a2a2aFF)
            if r.ImGui_Button(ctx, "x##stmplclr"..g.."_"..s, 22, 0) then
              if dlg_ShowMessageBox("Clear send FX?", "Clear FX", 4) == 6 then
                push_undo(); groups[g].sends[s].template = nil
              end
            end
            r.ImGui_PopStyleColor(ctx, 2)
          end
          -- Col 2: x to remove slot
          r.ImGui_TableSetColumnIndex(ctx, 2)
          r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x5a1a1aFF)
          r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x8a2a2aFF)
          if r.ImGui_Button(ctx, "x##stc"..g.."_"..s, 22, 0) then
            if dlg_ShowMessageBox("Remove this send slot?", "Remove Send", 4) == 6 then
              push_undo()
              table.remove(groups[g].sends, s)
              send_removed = true
            end
          end
          r.ImGui_PopStyleColor(ctx, 2)
          -- Col 3: send color swatch + RDM (skip if just removed)
          r.ImGui_TableSetColumnIndex(ctx, 3)
          if not send_removed then
            local sc = groups[g].sends[s].color_packed or 0x888888
            local sic = to_imgui_color(sc, 255)
            local scb_flags = r.ImGui_ColorEditFlags_NoTooltip() | r.ImGui_ColorEditFlags_NoBorder()
            if r.ImGui_ColorButton(ctx, "##scolor"..g.."_"..s, sic, scb_flags, 22, 20) then
              local srv, sgv, sbv = unpack_color(sc)
              local ok2, nn2 = dlg_GR_SelectColor(r.GetMainHwnd(), r.ColorToNative(srv, sgv, sbv))
              if ok2 ~= 0 then
                push_undo()
                local nr2, ng3, nb2 = r.ColorFromNative(nn2)
                groups[g].sends[s].color_packed = pack_color(nr2, ng3, nb2)
              end
            end
            r.ImGui_SameLine(ctx, 0, 4)
            if r.ImGui_Button(ctx, "R##srdm"..g.."_"..s, 22, 20) then
              push_undo()
              groups[g].sends[s].color_packed = random_color()
            end
            r.ImGui_SameLine(ctx, 0, 4)
            if r.ImGui_Button(ctx, "A##sbrt"..g.."_"..s, 22, 20) then
              push_undo()
              groups[g].sends[s].color_packed = cycle_brightness(groups[g].sends[s].color_packed or 0x888888)
            end
          end
        end
          -- Col 4: bulk set 0dB / -inf / clear (only on rows that have a send slot)
          if slot_exists then
          r.ImGui_TableSetColumnIndex(ctx, 4)
          if not send_removed then
            local btn_w = 22
            do  -- center the 4 buttons in the column
              local avail_bw = r.ImGui_GetContentRegionAvail(ctx)
              local total_bw = btn_w * 4 + 4 * 3
              local off_bw   = math.max(0, math.floor((avail_bw - total_bw) / 2))
              r.ImGui_SetCursorPosX(ctx, r.ImGui_GetCursorPosX(ctx) + off_bw)
            end
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x2a3a2aFF)
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x3a5a3aFF)
            if r.ImGui_Button(ctx, "S##svs"..g.."_"..s, btn_w, 0) then
              do local cg, cs = g, s
                modal_pending = {
                  title       = "Set Sends",
                  msg         = "Set S"..cs.." send values to:",
                  input_label = "Value:",
                  input_buf   = "0",
                  callback    = function(sc, val)
                    if val and val ~= "" then push_undo(); apply_send_slot_value(val, sc, cg, cs) end
                  end,
                }
              end
            end
            r.ImGui_PopStyleColor(ctx, 2)
            r.ImGui_SameLine(ctx, 0, 4)
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x1a3a1aFF)
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x2a5a2aFF)
            if r.ImGui_Button(ctx, "0##sv0"..g.."_"..s, btn_w, 0) then
              do local cg, cs = g, s
                open_scope_modal("Set Sends", "Set S"..cs.." sends to 0 dB?",
                  function(sc) push_undo(); apply_send_slot_value("0", sc, cg, cs) end)
              end
            end
            r.ImGui_PopStyleColor(ctx, 2)
            r.ImGui_SameLine(ctx, 0, 4)
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x1a1a3aFF)
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x2a2a5aFF)
            if r.ImGui_Button(ctx, "inf##svi"..g.."_"..s, btn_w, 0) then
              do local cg, cs = g, s
                open_scope_modal("Set Sends", "Set S"..cs.." sends to -inf?",
                  function(sc) push_undo(); apply_send_slot_value("i", sc, cg, cs) end)
              end
            end
            r.ImGui_PopStyleColor(ctx, 2)
            r.ImGui_SameLine(ctx, 0, 4)
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x5a1a1aFF)
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x8a2a2aFF)
            if r.ImGui_Button(ctx, "clr##svx"..g.."_"..s, btn_w, 0) then
              do local cg, cs = g, s
                open_scope_modal("Clear Sends", "Clear S"..cs.." send values?",
                  function(sc) push_undo(); apply_send_slot_value("", sc, cg, cs) end)
              end
            end
            r.ImGui_PopStyleColor(ctx, 2)
          end  -- if not send_removed
          end -- slot_exists guard for col 4

          -- Col 5: Pre/Post fader toggle (send rows only)
          if slot_exists and not send_removed then
            r.ImGui_TableSetColumnIndex(ctx, 5)
            local pre_v = groups[g].sends[s].pre_fader or false
            -- Center-align the checkbox
            local cw5 = r.ImGui_GetContentRegionAvail(ctx)
            local cb_sz = 19
            r.ImGui_SetCursorPosX(ctx, r.ImGui_GetCursorPosX(ctx) + math.max(0, math.floor((cw5 - cb_sz) / 2)))
            r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), pre_v and 0xFFDDAAFF or 0x666666FF)
            local pre_ch, pre_nv = r.ImGui_Checkbox(ctx, "##spre"..g.."_"..s, pre_v)
            r.ImGui_PopStyleColor(ctx)
            if pre_ch then push_undo(); groups[g].sends[s].pre_fader = pre_nv end
          end

      end -- per-slot loop
    end
    r.ImGui_EndTable(ctx)
  end

  -- Apply any pending group reorder
  if pending_move then
    push_undo()
    local src_g, dst_g = pending_move.src, pending_move.dst
    local do_multi = pending_move.multi and group_selected[src_g]

    if do_multi then
      -- ── Multi-move: move all selected groups as a block to dst_g ─────────────
      local sel = {}
      for gg = 1, NUM_GROUPS do
        if group_selected[gg] then sel[#sel+1] = gg end
      end
      local sel_set = {}
      for _, gg in ipairs(sel) do sel_set[gg] = true end

      -- Extract selected groups in order
      local moved_grps, moved_bufs = {}, {}
      for _, gg in ipairs(sel) do
        moved_grps[#moved_grps+1] = groups[gg]
        moved_bufs[#moved_bufs+1] = rename_group_buf[gg]
      end

      -- Build stripped list (without selected groups) and map old→stripped pos
      local new_groups, new_bufs = {}, {}
      local old_to_stripped = {}
      local pos = 0
      for gg = 1, NUM_GROUPS do
        if not sel_set[gg] then
          pos = pos + 1
          new_groups[pos] = groups[gg]
          new_bufs[pos]   = rename_group_buf[gg]
          old_to_stripped[gg] = pos
        end
      end

      -- Insertion point in stripped list
      local insert_at = math.max(1, math.min(old_to_stripped[dst_g] or pos, pos + 1))

      -- Insert block
      for k = #moved_grps, 1, -1 do
        table.insert(new_groups, insert_at, moved_grps[k])
        table.insert(new_bufs,   insert_at, moved_bufs[k])
      end

      -- Build final old→new index map
      local final_map = {}
      local si = 0
      for gg = 1, NUM_GROUPS do
        if not sel_set[gg] then
          si = si + 1
          final_map[gg] = si < insert_at and si or si + #sel
        end
      end
      for k, gg in ipairs(sel) do
        final_map[gg] = insert_at + k - 1
      end

      groups           = new_groups
      rename_group_buf = new_bufs

      for _, t in ipairs(tracks) do
        if t.group ~= NO_GROUP then t.group = final_map[t.group] or t.group end
      end
      for gg2 = 1, NUM_GROUPS do
        local rt = groups[gg2].routes_to or 0
        if rt ~= 0 then groups[gg2].routes_to = final_map[rt] or rt end
      end
      local new_gsel = {}
      for gg, v in pairs(group_selected) do
        if final_map[gg] then new_gsel[final_map[gg]] = v end
      end
      group_selected = new_gsel

    else
      -- ── Single move ───────────────────────────────────────────────────────────
      local moved_grp = table.remove(groups, src_g)
      local moved_buf = table.remove(rename_group_buf, src_g)
      table.insert(groups, dst_g, moved_grp)
      table.insert(rename_group_buf, dst_g, moved_buf)
      local function remap_g(v)
        if v == src_g then return dst_g
        elseif src_g < dst_g then return (v > src_g and v <= dst_g) and v - 1 or v
        else return (v >= dst_g and v < src_g) and v + 1 or v end
      end
      for _, t in ipairs(tracks) do
        if t.group ~= NO_GROUP then t.group = remap_g(t.group) end
      end
      for g2 = 1, NUM_GROUPS do
        local rt = groups[g2].routes_to or 0
        if rt ~= 0 then groups[g2].routes_to = remap_g(rt) end
      end
      local new_gsel = {}
      for gg, v in pairs(group_selected) do new_gsel[remap_g(gg)] = v end
      group_selected = new_gsel
    end

    pending_move = nil
  end

  -- Apply any pending group deletion(s)
  local del_list = pending_delete_list or (pending_delete and {pending_delete} or nil)
  if del_list then
    table.sort(del_list, function(a, b) return a > b end)  -- descending: safe index removal
    for _, dg in ipairs(del_list) do
      for _, t in ipairs(tracks) do
        if t.group == dg then t.group = NO_GROUP
        elseif t.group > dg then t.group = t.group - 1 end
      end
      for g2 = 1, NUM_GROUPS do
        if g2 ~= dg then
          local rt = groups[g2].routes_to or 0
          if rt == dg then groups[g2].routes_to = 0
          elseif rt > dg then groups[g2].routes_to = rt - 1 end
        end
      end
      local new_gsel = {}
      for gg, v in pairs(group_selected) do
        if gg < dg then new_gsel[gg] = v
        elseif gg > dg then new_gsel[gg - 1] = v end
      end
      group_selected = new_gsel
      table.remove(groups, dg)
      table.remove(rename_group_buf, dg)
      NUM_GROUPS = NUM_GROUPS - 1
    end
    pending_delete = nil
    pending_delete_list = nil
  end

  -- ── Add group / Reset buttons (40% narrower) + Parent Tracks inline ────────
  r.ImGui_BeginGroup(ctx)
  r.ImGui_Dummy(ctx, 0, 3)
  do
    local btn_each = math.floor((groups_w - 24) / 4)
    r.ImGui_Dummy(ctx, 6, 0) r.ImGui_SameLine(ctx, 0, 0)
    if NUM_GROUPS < MAX_GROUPS then
      if r.ImGui_Button(ctx, "Add Group##ag", btn_each, 0) then
        push_undo()
        NUM_GROUPS = NUM_GROUPS + 1
        groups[NUM_GROUPS] = {
          name          = "Group " .. NUM_GROUPS,
          color_packed  = random_color(),
          sends         = {},
          routes_to     = 0,
        }
        rename_group_buf[NUM_GROUPS] = "Group " .. NUM_GROUPS
      end
    else
      r.ImGui_Dummy(ctx, btn_each, 0)
    end
    r.ImGui_SameLine(ctx, 0, 4)
    if NUM_GROUPS < MAX_GROUPS then
      if r.ImGui_Button(ctx, "Add Groups##ags", btn_each, 0) then
        local ok2, val2 = dlg_GetUserInputs("Add Multiple Groups", 1, "How many groups to add:", "4")
        if ok2 then
          local n2 = math.floor(tonumber(val2) or 0)
          if n2 >= 1 then
            push_undo()
            for _i2 = 1, math.min(n2, MAX_GROUPS - NUM_GROUPS) do
              NUM_GROUPS = NUM_GROUPS + 1
              groups[NUM_GROUPS] = {
                name         = "Group " .. NUM_GROUPS,
                color_packed = random_color(),
                sends        = {},
                routes_to    = 0,
              }
              rename_group_buf[NUM_GROUPS] = "Group " .. NUM_GROUPS
            end
          end
        end
      end
    else
      r.ImGui_Dummy(ctx, btn_each, 0)
    end
    r.ImGui_SameLine(ctx, 0, 4)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x5a1a1aFF)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x8a2a2aFF)
    if r.ImGui_Button(ctx, "Reset Groups##rsg", btn_each, 0) then
      if dlg_ShowMessageBox("Reset all groups to default?", "Reset Groups", 4) == 6 then
        push_undo()
        init_groups()
        group_load_version = group_load_version + 1
        for _, t in ipairs(tracks) do t.group = NO_GROUP end
      end
    end
    r.ImGui_SameLine(ctx, 0, 4)
    if r.ImGui_Button(ctx, "Reset Sends##rss", btn_each, 0) then
      if dlg_ShowMessageBox("Clear all send slots from all groups?", "Reset Sends", 4) == 6 then
        push_undo()
        for g = 1, NUM_GROUPS do groups[g].sends = {} end
      end
    end
    r.ImGui_PopStyleColor(ctx, 2)
  end  -- buttons row
  r.ImGui_Dummy(ctx, 0, 3)
  r.ImGui_EndGroup(ctx)
  do
    local bx1, by1 = r.ImGui_GetItemRectMin(ctx)
    local bx2, by2 = r.ImGui_GetItemRectMax(ctx)
    local bdl = r.ImGui_GetWindowDrawList(ctx)
    r.ImGui_DrawList_AddRect(bdl, bx1, by1, bx1 + groups_w, by2, 0x454545FF, 0, 0, 1)
  end

  r.ImGui_Spacing(ctx)
  local gs_flags = r.ImGui_TableFlags_BordersOuter()
    | r.ImGui_TableFlags_BordersInnerV()
    | r.ImGui_TableFlags_RowBg()
  -- Header row
  -- ── Global Sends Panel ──────────────────────────────────────────────────────
  r.ImGui_BeginGroup(ctx)
  r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ItemSpacing(), 0, 1)
  if r.ImGui_BeginTable(ctx, "gs_hdr", 1, r.ImGui_TableFlags_BordersOuter(), groups_w, 0) then
    r.ImGui_TableSetupColumn(ctx, "Global Sends", r.ImGui_TableColumnFlags_WidthStretch())
    r.ImGui_TableHeadersRow(ctx)
    r.ImGui_EndTable(ctx)
  end
  r.ImGui_PopStyleVar(ctx)  -- ItemSpacing
  -- Send rows: same layout as group send rows
  -- Cols: # (22) | Name+FX (stretch) | Del (22) | Color (50)
  if r.ImGui_BeginTable(ctx, "gs_table", 6, gs_flags, groups_w, 0) then
    r.ImGui_TableSetupColumn(ctx, "##gsnum",   r.ImGui_TableColumnFlags_WidthFixed(),  22)
    r.ImGui_TableSetupColumn(ctx, "##gsname",  r.ImGui_TableColumnFlags_WidthStretch())
    r.ImGui_TableSetupColumn(ctx, "##gsdel",   r.ImGui_TableColumnFlags_WidthFixed(),  22)
    r.ImGui_TableSetupColumn(ctx, "##gsclr",   r.ImGui_TableColumnFlags_WidthFixed(),  76)
    r.ImGui_TableSetupColumn(ctx, "##gsvals",  r.ImGui_TableColumnFlags_WidthFixed(), 100)
    r.ImGui_TableSetupColumn(ctx, "##gspre",   r.ImGui_TableColumnFlags_WidthFixed(),  22)
    local gs_removed = nil
    for s = 1, #global_sends do
      local gs = global_sends[s]
      r.ImGui_TableNextRow(ctx)
      -- Col 0: slot label S1..S8
      r.ImGui_TableSetColumnIndex(ctx, 0)
      do
        local cw = r.ImGui_GetContentRegionAvail(ctx)
        local lbl = "S"..s
        local tw = r.ImGui_CalcTextSize(ctx, lbl)
        local _, fpy = r.ImGui_GetStyleVar(ctx, r.ImGui_StyleVar_FramePadding())
        r.ImGui_SetCursorPosX(ctx, r.ImGui_GetCursorPosX(ctx) + math.max(0,(cw-tw)/2))
        r.ImGui_SetCursorPosY(ctx, r.ImGui_GetCursorPosY(ctx) + fpy)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xAAAAAAAA)
        r.ImGui_Text(ctx, lbl)
        r.ImGui_PopStyleColor(ctx)
      end
      -- Col 1: name (1/3) + FX dropdown (stretch) + x clear
      r.ImGui_TableSetColumnIndex(ctx, 1)
      do
        local col_w = r.ImGui_GetContentRegionAvail(ctx)
        local name_w = math.floor(col_w / 3) - 2
        r.ImGui_SetNextItemWidth(ctx, name_w)
        local gnc, gnv = r.ImGui_InputText(ctx, "##gsn"..s, gs.name, r.ImGui_InputTextFlags_AutoSelectAll())
        if gnc then push_undo_debounced(); gs.name = gnv end
        r.ImGui_SameLine(ctx, 0, 4)
        -- Global send FX button + clear
        local gtmpl = gs.template
        local gtpreview = fx_preview(gtmpl) or "-- FX --"
        local gtx_w = gtmpl and 26 or 0
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        gtmpl and 0x1a3a1aFF or 0x2a2a2aFF)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), gtmpl and 0x2a5a2aFF or 0x3a3a3aFF)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(),          gtmpl and 0xAAFFAAFF or 0x888888FF)
        if r.ImGui_Button(ctx, gtpreview .. "##gstbtn"..s, -1 - gtx_w, 0) then
          open_picker("gsend", nil, nil, s)
        end
        r.ImGui_PopStyleColor(ctx, 3)
        if gtmpl then
          r.ImGui_SameLine(ctx, 0, 4)
          r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x5a1a1aFF)
          r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x8a2a2aFF)
          if r.ImGui_Button(ctx, "x##gsfxclr"..s, 22, 0) then
            if dlg_ShowMessageBox("Clear global send FX?", "Clear FX", 4) == 6 then
              push_undo(); gs.template = nil
            end
          end
          r.ImGui_PopStyleColor(ctx, 2)
        end
      end
      -- Col 2: delete slot
      r.ImGui_TableSetColumnIndex(ctx, 2)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x5a1a1aFF)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x8a2a2aFF)
      local gs_slot_removed = false
      if r.ImGui_Button(ctx, "x##gsdel"..s, 22, 0) then
        if dlg_ShowMessageBox("Remove global send S"..s.."?", "Remove Send", 4) == 6 then
          push_undo()
          gs_removed = s
          gs_slot_removed = true
        end
      end
      r.ImGui_PopStyleColor(ctx, 2)
      -- Col 3: color swatch + RDM
      r.ImGui_TableSetColumnIndex(ctx, 3)
      if not gs_slot_removed then
        local sc = gs.color_packed or 0x888888
        local sic = to_imgui_color(sc, 255)
        local scf = r.ImGui_ColorEditFlags_NoTooltip() | r.ImGui_ColorEditFlags_NoBorder()
        if r.ImGui_ColorButton(ctx, "##gsclr"..s, sic, scf, 22, 20) then
          local srv, sgv, sbv = unpack_color(sc)
          local ok2, nn2 = dlg_GR_SelectColor(r.GetMainHwnd(), r.ColorToNative(srv, sgv, sbv))
          if ok2 ~= 0 then
            push_undo()
            local nr2, ng3, nb2 = r.ColorFromNative(nn2)
            gs.color_packed = pack_color(nr2, ng3, nb2)
          end
        end
        r.ImGui_SameLine(ctx, 0, 4)
        if r.ImGui_Button(ctx, "R##gsrdm"..s, 22, 20) then
          push_undo()
          gs.color_packed = random_color()
        end
        r.ImGui_SameLine(ctx, 0, 4)
        if r.ImGui_Button(ctx, "A##gsbrt"..s, 22, 20) then
          push_undo()
          gs.color_packed = cycle_brightness(gs.color_packed or 0x888888)
        end
      end
      -- Col 4: bulk 0/inf/x for this global send slot
      r.ImGui_TableSetColumnIndex(ctx, 4)
      if not gs_slot_removed then
        local btn_w = 22
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x2a3a2aFF)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x3a5a3aFF)
        if r.ImGui_Button(ctx, "S##gsvs"..s, btn_w, 0) then
          do local cs = s
            modal_pending = {
              title       = "Set GS"..cs,
              msg         = "Set GS"..cs.." values to:",
              input_label = "Value:",
              input_buf   = "0",
              callback    = function(sc, val)
                if val and val ~= "" then push_undo(); apply_global_send_value(val, sc, cs) end
              end,
            }
          end
        end
        r.ImGui_PopStyleColor(ctx, 2)
        r.ImGui_SameLine(ctx, 0, 2)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x1a3a1aFF)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x2a5a2aFF)
        if r.ImGui_Button(ctx, "0##gsv0"..s, btn_w, 0) then
          do local cs = s
            open_scope_modal("Set GS"..cs, "Set GS"..cs.." values to 0 dB?",
              function(sc) push_undo(); apply_global_send_value("0", sc, cs) end)
          end
        end
        r.ImGui_PopStyleColor(ctx, 2)
        r.ImGui_SameLine(ctx, 0, 2)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x1a1a3aFF)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x2a2a5aFF)
        if r.ImGui_Button(ctx, "inf##gsvi"..s, btn_w, 0) then
          do local cs = s
            open_scope_modal("Set GS"..cs, "Set GS"..cs.." values to -inf?",
              function(sc) push_undo(); apply_global_send_value("i", sc, cs) end)
          end
        end
        r.ImGui_PopStyleColor(ctx, 2)
        r.ImGui_SameLine(ctx, 0, 2)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x5a1a1aFF)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x8a2a2aFF)
        if r.ImGui_Button(ctx, "clr##gsvx"..s, btn_w, 0) then
          do local cs = s
            open_scope_modal("Clear GS"..cs, "Clear GS"..cs.." values?",
              function(sc) push_undo(); apply_global_send_value("", sc, cs) end)
          end
        end
        r.ImGui_PopStyleColor(ctx, 2)
      end
      -- Col 5: Pre/Post fader for global send
      if not gs_slot_removed then
        r.ImGui_TableSetColumnIndex(ctx, 5)
        local gs_pre = gs.pre_fader or false
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), gs_pre and 0xFFDDAAFF or 0x666666FF)
        local gspch, gspv = r.ImGui_Checkbox(ctx, "##gspre"..s, gs_pre)
        r.ImGui_PopStyleColor(ctx)
        if gspch then push_undo(); gs.pre_fader = gspv end
      end
    end
    -- Deferred removal
    if gs_removed then
      table.remove(global_sends, gs_removed)
      for i = 1, #tracks do
        if global_send_buf[i] and gs_removed <= #global_send_buf[i] then
          table.remove(global_send_buf[i], gs_removed)
        end
      end
    end
    r.ImGui_EndTable(ctx)
  end
  -- Add global send button
  if #global_sends < MAX_GLOBAL_SENDS then
    if r.ImGui_Button(ctx, "+ Add Global Send", groups_w, 0) then
      push_undo()
      global_sends[#global_sends+1] = { name = "", template = nil, color_packed = opt_send_color_packed, pre_fader = false }
    end
  end
  r.ImGui_EndGroup(ctx)
  do
    local bx1, by1 = r.ImGui_GetItemRectMin(ctx)
    local bx2, by2 = r.ImGui_GetItemRectMax(ctx)
    local bdl = r.ImGui_GetWindowDrawList(ctx)
    r.ImGui_DrawList_AddRect(bdl, bx1, by1, bx1 + groups_w, by2, 0x454545FF, 0, 0, 1)
  end

  r.ImGui_Spacing(ctx)

  -- ── Master Track section ─────────────────────────────────────────────────────
  r.ImGui_BeginGroup(ctx)
  r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ItemSpacing(), 0, 1)
  if r.ImGui_BeginTable(ctx, "mst_hdr", 1, r.ImGui_TableFlags_BordersOuter(), groups_w, 0) then
    r.ImGui_TableSetupColumn(ctx, "Master Track", r.ImGui_TableColumnFlags_WidthStretch())
    r.ImGui_TableHeadersRow(ctx)
    r.ImGui_EndTable(ctx)
  end
  r.ImGui_PopStyleVar(ctx)  -- ItemSpacing
  local mst_flags = r.ImGui_TableFlags_BordersOuter() | r.ImGui_TableFlags_BordersInnerV()
  if r.ImGui_BeginTable(ctx, "master_row", 3, mst_flags, groups_w, 0) then
    r.ImGui_TableSetupColumn(ctx, "##mst0",  r.ImGui_TableColumnFlags_WidthFixed(),  22)
    r.ImGui_TableSetupColumn(ctx, "##mst1",  r.ImGui_TableColumnFlags_WidthStretch())
    r.ImGui_TableSetupColumn(ctx, "##mst2",  r.ImGui_TableColumnFlags_WidthFixed(),  22)
    r.ImGui_TableNextRow(ctx)
    -- Col 0: "M" label
    r.ImGui_TableSetColumnIndex(ctx, 0)
    do
      local cw2 = r.ImGui_GetContentRegionAvail(ctx)
      local _, fp2 = r.ImGui_GetStyleVar(ctx, r.ImGui_StyleVar_FramePadding())
      r.ImGui_SetCursorPosY(ctx, r.ImGui_GetCursorPosY(ctx) + fp2)
      r.ImGui_SetCursorPosX(ctx, r.ImGui_GetCursorPosX(ctx) + math.max(0,(cw2 - r.ImGui_CalcTextSize(ctx,"M"))/2))
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xCCCCCCFF)
      r.ImGui_Text(ctx, "M")
      r.ImGui_PopStyleColor(ctx)
    end
    -- Col 1: FX button only
    r.ImGui_TableSetColumnIndex(ctx, 1)
    do
      local mfx_tmpl    = master_fx_chain
      local mfx_preview = fx_preview(mfx_tmpl) or "-- FX --"
      local mfx_x_w     = mfx_tmpl and 26 or 0
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        mfx_tmpl and 0x1a3a1aFF or 0x2a2a2aFF)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), mfx_tmpl and 0x2a5a2aFF or 0x3a3a3aFF)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(),          mfx_tmpl and 0xAAFFAAFF or 0x888888FF)
      if r.ImGui_Button(ctx, mfx_preview.."##mfxbtn", -1 - mfx_x_w, 0) then
        open_picker("master", nil, nil, nil)
      end
      r.ImGui_PopStyleColor(ctx, 3)
      if mfx_tmpl then
        r.ImGui_SameLine(ctx, 0, 4)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x5a1a1aFF)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x8a2a2aFF)
        if r.ImGui_Button(ctx, "x##mfxclr", 22, 0) then
          if dlg_ShowMessageBox("Clear master FX?", "Clear FX", 4) == 6 then
            push_undo(); master_fx_chain = nil
          end
        end
        r.ImGui_PopStyleColor(ctx, 2)
      end
    end
    -- Col 2: empty spacer
    r.ImGui_TableSetColumnIndex(ctx, 2)
    r.ImGui_EndTable(ctx)
  end
  r.ImGui_EndGroup(ctx)
  do
    local bx1, by1 = r.ImGui_GetItemRectMin(ctx)
    local bx2, by2 = r.ImGui_GetItemRectMax(ctx)
    local bdl = r.ImGui_GetWindowDrawList(ctx)
    r.ImGui_DrawList_AddRect(bdl, bx1, by1, bx1 + groups_w, by2, 0x454545FF, 0, 0, 1)
  end

  r.ImGui_Spacing(ctx)

  -- ── Options section ───────────────────────────────────────────────────────────
  r.ImGui_BeginGroup(ctx)
  if r.ImGui_BeginTable(ctx, "opt_hdr", 1, r.ImGui_TableFlags_BordersOuter(), groups_w, 0) then
    r.ImGui_TableSetupColumn(ctx, "Options", r.ImGui_TableColumnFlags_WidthStretch())
    r.ImGui_TableHeadersRow(ctx)
    r.ImGui_EndTable(ctx)
  end
  local opt_tbl_flags = r.ImGui_TableFlags_BordersOuter() | r.ImGui_TableFlags_BordersInnerV()
  if r.ImGui_BeginTable(ctx, "opt_rows", 2, opt_tbl_flags, groups_w, 0) then
    r.ImGui_TableSetupColumn(ctx, "##optlbl",  r.ImGui_TableColumnFlags_WidthFixed(), 90)
    r.ImGui_TableSetupColumn(ctx, "##optval",  r.ImGui_TableColumnFlags_WidthStretch())

    -- ── FX Folder ───────────────────────────────────────────────────────────
    r.ImGui_TableNextRow(ctx)
    r.ImGui_TableSetColumnIndex(ctx, 0)
    do local _, fpy3 = r.ImGui_GetStyleVar(ctx, r.ImGui_StyleVar_FramePadding())
      r.ImGui_SetCursorPosY(ctx, r.ImGui_GetCursorPosY(ctx) + fpy3)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xAAAAAAAA)
      r.ImGui_Text(ctx, "FX Folder")
      r.ImGui_PopStyleColor(ctx)
    end
    r.ImGui_TableSetColumnIndex(ctx, 1)
    do
      local fxf_label = opt_fx_folder and opt_fx_folder:match("[^/\\]+$") or "(default)"
      local fxf_x_w   = opt_fx_folder and 26 or 0
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), opt_fx_folder and 0x1a3a1aFF or 0x2a2a2aFF)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), opt_fx_folder and 0x2a5a2aFF or 0x3a3a3aFF)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), opt_fx_folder and 0xAAFFAAFF or 0x666666FF)
      if r.ImGui_Button(ctx, fxf_label.."##fxfbtn", -1 - fxf_x_w, 0) then
        local chosen = nil
        if r.JS_Dialog_BrowseForFolder then
          local ok3, p3 = dlg_JS_BrowseForFolder("Select FX Chain Preset Folder", opt_fx_folder or r.GetResourcePath())
          if ok3 == 1 then chosen = p3 end
        else
          local ok3, p3 = dlg_GetUserInputs("FX Folder Path", 1, "Folder path:", opt_fx_folder or "")
          if ok3 and p3 ~= "" then chosen = p3 end
        end
        if chosen then push_undo(); opt_fx_folder = chosen; fx_chain_list = nil; picker_combined_list = nil end
      end
      r.ImGui_PopStyleColor(ctx, 3)
      if opt_fx_folder then
        r.ImGui_SameLine(ctx, 0, 4)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x5a1a1aFF)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x8a2a2aFF)
        if r.ImGui_Button(ctx, "x##fxfclr", 22, 0) then
          push_undo(); opt_fx_folder = nil; fx_chain_list = nil; picker_combined_list = nil
        end
        r.ImGui_PopStyleColor(ctx, 2)
      end
    end

    -- ── Global Filter ────────────────────────────────────────────────────────
    r.ImGui_TableNextRow(ctx)
    r.ImGui_TableSetColumnIndex(ctx, 0)
    do local _, fpyf = r.ImGui_GetStyleVar(ctx, r.ImGui_StyleVar_FramePadding())
      r.ImGui_SetCursorPosY(ctx, r.ImGui_GetCursorPosY(ctx) + fpyf)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xAAAAAAAA)
      r.ImGui_Text(ctx, "Global Filter")
      r.ImGui_PopStyleColor(ctx)
    end
    r.ImGui_TableSetColumnIndex(ctx, 1)
    do
      local gf_changed = false
      local function gfc(label, val)
        local c, v = r.ImGui_Checkbox(ctx, label.."##gf", val)
        if c then gf_changed = true end
        return c and v or (not c and val)
      end
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xCCCCCCFF)
      picker_show_chains = gfc("Chains", picker_show_chains)
      r.ImGui_PopStyleColor(ctx)
      r.ImGui_SameLine(ctx, 0, 8)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xAADDFFFF)
      picker_show_vst3   = gfc("VST3",   picker_show_vst3)
      r.ImGui_PopStyleColor(ctx)
      r.ImGui_SameLine(ctx, 0, 8)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xFFDDAAFF)
      picker_show_vst    = gfc("VST",    picker_show_vst)
      r.ImGui_PopStyleColor(ctx)
      r.ImGui_SameLine(ctx, 0, 8)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xFFFFAAFF)
      picker_show_clap   = gfc("CLAP",   picker_show_clap)
      r.ImGui_PopStyleColor(ctx)
      r.ImGui_SameLine(ctx, 0, 8)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xAAFFAAFF)
      picker_show_js     = gfc("JS",     picker_show_js)
      r.ImGui_PopStyleColor(ctx)
      if gf_changed then picker_rebuild_filtered() end
    end

    -- ── Sends Position ──────────────────────────────────────────────────────
    r.ImGui_TableNextRow(ctx)
    r.ImGui_TableSetColumnIndex(ctx, 0)
    do local _, fpy4 = r.ImGui_GetStyleVar(ctx, r.ImGui_StyleVar_FramePadding())
      r.ImGui_SetCursorPosY(ctx, r.ImGui_GetCursorPosY(ctx) + fpy4)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xAAAAAAAA)
      r.ImGui_Text(ctx, "Sends Pos")
      r.ImGui_PopStyleColor(ctx)
    end
    r.ImGui_TableSetColumnIndex(ctx, 1)
    do
      local sp_ch3, sp_v3 = r.ImGui_Checkbox(ctx, "Folder Top##spft", opt_sends_folder_top)
      if sp_ch3 then push_undo(); opt_sends_folder_top = sp_v3
        if sp_v3 then opt_sends_folder_bot = false; opt_sends_at_bottom = false end
      end
      r.ImGui_SameLine(ctx, 0, 8)
      local sp_ch4, sp_v4 = r.ImGui_Checkbox(ctx, "Folder Bottom##spfb", opt_sends_folder_bot)
      if sp_ch4 then push_undo(); opt_sends_folder_bot = sp_v4
        if sp_v4 then opt_sends_folder_top = false; opt_sends_at_bottom = false end
      end
      r.ImGui_SameLine(ctx, 0, 8)
      local sp_ch2, sp_v2 = r.ImGui_Checkbox(ctx, "At Bottom##spb", opt_sends_at_bottom)
      if sp_ch2 then push_undo(); opt_sends_at_bottom = sp_v2
        if sp_v2 then opt_sends_folder_top = false; opt_sends_folder_bot = false end
      end
    end

    -- ── Parent Color ────────────────────────────────────────────────────────
    r.ImGui_TableNextRow(ctx)
    r.ImGui_TableSetColumnIndex(ctx, 0)
    do local _, fpy5 = r.ImGui_GetStyleVar(ctx, r.ImGui_StyleVar_FramePadding())
      r.ImGui_SetCursorPosY(ctx, r.ImGui_GetCursorPosY(ctx) + fpy5)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xAAAAAAAA)
      r.ImGui_Text(ctx, "Parent Color")
      r.ImGui_PopStyleColor(ctx)
    end
    r.ImGui_TableSetColumnIndex(ctx, 1)
    do
      local pc_ic = parent_use_track_color and 0x555555FF or to_imgui_color(parent_color_packed, 255)
      local pc_flags = r.ImGui_ColorEditFlags_NoTooltip() | r.ImGui_ColorEditFlags_NoBorder()
      if parent_use_track_color then
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x555555FF)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x555555FF)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), 0x555555FF)
      end
      if r.ImGui_ColorButton(ctx, "##pccolor", pc_ic, pc_flags, 22, 20) and not parent_use_track_color then
        local prv, pgv, pbv = unpack_color(parent_color_packed)
        local pok, pnn = dlg_GR_SelectColor(r.GetMainHwnd(), r.ColorToNative(prv, pgv, pbv))
        if pok ~= 0 then push_undo()
          local pnr, png, pnb = r.ColorFromNative(pnn); parent_color_packed = pack_color(pnr, png, pnb)
        end
      end
      if parent_use_track_color then r.ImGui_PopStyleColor(ctx, 3) end
      r.ImGui_SameLine(ctx, 0, 4)
      if r.ImGui_Button(ctx, "R##pcrdm", 22, 20) then push_undo()
        parent_color_packed = random_color()
      end
      r.ImGui_SameLine(ctx, 0, 8)
      local putc_c, putc_v = r.ImGui_Checkbox(ctx, "Use Track Color##putc", parent_use_track_color)
      if putc_c then push_undo(); parent_use_track_color = putc_v end
    end

    -- ── Send Color ──────────────────────────────────────────────────────────
    r.ImGui_TableNextRow(ctx)
    r.ImGui_TableSetColumnIndex(ctx, 0)
    do local _, fpy6 = r.ImGui_GetStyleVar(ctx, r.ImGui_StyleVar_FramePadding())
      r.ImGui_SetCursorPosY(ctx, r.ImGui_GetCursorPosY(ctx) + fpy6)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xAAAAAAAA)
      r.ImGui_Text(ctx, "Send Color")
      r.ImGui_PopStyleColor(ctx)
    end
    r.ImGui_TableSetColumnIndex(ctx, 1)
    do
      local sc_grey = (opt_send_color_packed == 0x888888)
      local sc_ic = sc_grey and 0x555555FF or to_imgui_color(opt_send_color_packed, 255)
      local sc_flags = r.ImGui_ColorEditFlags_NoTooltip() | r.ImGui_ColorEditFlags_NoBorder()
      if sc_grey then
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x555555FF)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x666666FF)
      end
      if r.ImGui_ColorButton(ctx, "##sccolor", sc_ic, sc_flags, 22, 20) then
        local scr, scg2, scb = unpack_color(sc_grey and 0x888888 or opt_send_color_packed)
        local scok, scnn = dlg_GR_SelectColor(r.GetMainHwnd(), r.ColorToNative(scr, scg2, scb))
        if scok ~= 0 then push_undo()
          local snr, sng, snb = r.ColorFromNative(scnn); opt_send_color_packed = pack_color(snr, sng, snb)
        end
      end
      if sc_grey then r.ImGui_PopStyleColor(ctx, 2) end
      r.ImGui_SameLine(ctx, 0, 4)
      if r.ImGui_Button(ctx, "R##scrdm", 22, 20) then push_undo()
        opt_send_color_packed = random_color()
      end
      r.ImGui_SameLine(ctx, 0, 8)
      -- "Sync" button: copy send color to all existing send slots
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x1a3a3aFF)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x2a5a5aFF)
      if r.ImGui_Button(ctx, "Sync All##scsync", 0, 0) then
        push_undo()
        for gsc = 1, NUM_GROUPS do
          for _, sl in ipairs(groups[gsc].sends or {}) do
            sl.color_packed = opt_send_color_packed
          end
        end
        for _, gs2 in ipairs(global_sends) do gs2.color_packed = opt_send_color_packed end
      end
      r.ImGui_PopStyleColor(ctx, 2)
    end

    -- ── FX Bypass ───────────────────────────────────────────────────────────
    r.ImGui_TableNextRow(ctx)
    r.ImGui_TableSetColumnIndex(ctx, 0)
    do local _, fpy7 = r.ImGui_GetStyleVar(ctx, r.ImGui_StyleVar_FramePadding())
      r.ImGui_SetCursorPosY(ctx, r.ImGui_GetCursorPosY(ctx) + fpy7)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xAAAAAAAA)
      r.ImGui_Text(ctx, "FX Bypass")
      r.ImGui_PopStyleColor(ctx)
    end
    r.ImGui_TableSetColumnIndex(ctx, 1)
    do
      local bi_c, bi_v = r.ImGui_Checkbox(ctx, "All Inserts##fxbi", opt_fx_bypass_inserts)
      if bi_c then push_undo(); opt_fx_bypass_inserts = bi_v end
      r.ImGui_SameLine(ctx, 0, 8)
      local bc_c, bc_v = r.ImGui_Checkbox(ctx, "All FX Chains##fxbc", opt_fx_bypass_chains)
      if bc_c then push_undo(); opt_fx_bypass_chains = bc_v end
    end

    r.ImGui_EndTable(ctx)  -- opt_rows
  end
  r.ImGui_EndGroup(ctx)
  do
    local bx1, by1 = r.ImGui_GetItemRectMin(ctx)
    local bx2, by2 = r.ImGui_GetItemRectMax(ctx)
    local bdl = r.ImGui_GetWindowDrawList(ctx)
    r.ImGui_DrawList_AddRect(bdl, bx1, by1, bx1 + groups_w, by2, 0x454545FF, 0, 0, 1)
  end

  r.ImGui_Spacing(ctx)

  -- ── Presets ──────────────────────────────────────────────────────────────────
  local presets_w = groups_w
  local prs_flags = r.ImGui_TableFlags_BordersOuter()
    | r.ImGui_TableFlags_BordersInnerV()
    | r.ImGui_TableFlags_RowBg()

  r.ImGui_BeginGroup(ctx)
  if r.ImGui_BeginTable(ctx, "presets_hdr", 1, r.ImGui_TableFlags_BordersOuter(), presets_w, 0) then
    r.ImGui_TableSetupColumn(ctx, "Group Presets", r.ImGui_TableColumnFlags_WidthStretch())
    r.ImGui_TableHeadersRow(ctx)
    r.ImGui_EndTable(ctx)
  end

  if r.ImGui_BeginTable(ctx, "presets_table", 4, prs_flags, presets_w, 0) then
    r.ImGui_TableSetupColumn(ctx, "Name",    r.ImGui_TableColumnFlags_WidthStretch())
    r.ImGui_TableSetupColumn(ctx, "##pst",   r.ImGui_TableColumnFlags_WidthFixed(), 52)
    r.ImGui_TableSetupColumn(ctx, "##pld",   r.ImGui_TableColumnFlags_WidthFixed(), 48)
    r.ImGui_TableSetupColumn(ctx, "##pclr",  r.ImGui_TableColumnFlags_WidthFixed(), 26)
    r.ImGui_TableHeadersRow(ctx)

    for p = 1, NUM_PRESETS do
      r.ImGui_TableNextRow(ctx)
      r.ImGui_TableSetColumnIndex(ctx, 0)
      r.ImGui_SetNextItemWidth(ctx, -1)
      local pnf_changed, pnf_val = r.ImGui_InputText(ctx, "##pname"..p, preset_name_buf[p],
        r.ImGui_InputTextFlags_AutoSelectAll())
      if pnf_changed then preset_name_buf[p] = pnf_val end

      r.ImGui_TableSetColumnIndex(ctx, 1)
      do
        local is_pending = preset_store_pending[p] or false
        -- Green tint matching the track panel Save button
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        is_pending and 0x2a6a2aFF or 0x2a3a2aFF)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), is_pending and 0x3a8a3aFF or 0x3a5a3aFF)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(),          is_pending and 0xAAFFAAFF or 0xAAFFAAFF)
        if is_pending then
          -- Phase 2: "Storing..." visible this frame → show prompt → execute or cancel
          r.ImGui_Button(ctx, "Storing...##ps"..p, 50, 0)
          r.ImGui_PopStyleColor(ctx, 3)
          local msg = 'Store current groups into "' .. preset_name_buf[p] .. '"?'
          if dlg_ShowMessageBox(msg, "Store Preset", 4) == 6 then
            local slot = { name = preset_name_buf[p], parent_color = parent_color_packed,
                           parent_use_track_color = parent_use_track_color, groups = {} }
            for g = 1, NUM_GROUPS do
              local sg = {}
              for s2 = 1, #(groups[g].sends or {}) do
                sg[s2] = { template = groups[g].sends[s2].template, name = groups[g].sends[s2].name or "", color_packed = groups[g].sends[s2].color_packed or 0x888888, pre_fader = groups[g].sends[s2].pre_fader or false }
              end
              slot.groups[g] = { name = groups[g].name, color_packed = groups[g].color_packed, folder_template = groups[g].folder_template, sends = sg, routes_to = groups[g].routes_to or 0, pan_str = groups[g].pan_str or "C" }
            end
            slot.global_sends = {}
            for s = 1, #global_sends do
              local gs = global_sends[s]
              slot.global_sends[s] = { name = gs.name, template = gs.template, color_packed = gs.color_packed, pre_fader = gs.pre_fader or false }
            end
            slot.opt_fx_folder          = opt_fx_folder
                      slot.opt_sends_at_bottom    = opt_sends_at_bottom
            slot.opt_sends_folder_top   = opt_sends_folder_top
            slot.opt_sends_folder_bot   = opt_sends_folder_bot
            slot.opt_send_color_packed  = opt_send_color_packed
            slot.opt_send_use_trk_color = opt_send_use_trk_color
            slot.opt_fx_bypass_inserts  = opt_fx_bypass_inserts
            slot.opt_fx_bypass_chains   = opt_fx_bypass_chains
            slot.parent_color_packed    = parent_color_packed
            slot.parent_use_track_color = parent_use_track_color
            slot.master_name            = master_name
            slot.master_fx_chain        = master_fx_chain
            slot.picker_show_chains     = picker_show_chains
            slot.picker_show_vst3       = picker_show_vst3
            slot.picker_show_vst        = picker_show_vst
            slot.picker_show_clap       = picker_show_clap
            slot.picker_show_js         = picker_show_js
            presets[p] = slot
            save_presets()
          end
          preset_store_pending[p] = false
        else
          -- Phase 1: normal button, click sets pending for next frame
          if r.ImGui_Button(ctx, "Store##ps"..p, 50, 0) then
            preset_store_pending[p] = true
          end
          r.ImGui_PopStyleColor(ctx, 3)
        end
      end

      r.ImGui_TableSetColumnIndex(ctx, 2)
      local has_preset = presets[p] ~= nil
      if not has_preset then
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x333333AA)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x333333AA)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(),          0x666666FF)
      end
      if r.ImGui_Button(ctx, "Load##pl"..p, 46, 0) and has_preset then
        local msg = 'Load preset "' .. preset_name_buf[p] .. '"?\nThis will overwrite the current groups.'
        if dlg_ShowMessageBox(msg, "Load Preset", 4) == 6 then
        push_undo()
        local slot = presets[p]
        preset_name_buf[p]     = slot.name or preset_name_buf[p]
        parent_color_packed    = slot.parent_color
        parent_use_track_color = slot.parent_use_track_color
        -- Deep-copy groups so live edits never mutate the stored snapshot
        NUM_GROUPS = #slot.groups
        groups = {}
        rename_group_buf = {}
        for g = 1, NUM_GROUPS do
          local src_sends = slot.groups[g].sends or {}
          local sends_copy = {}
          for s = 1, #src_sends do
            sends_copy[s] = { template = src_sends[s].template, name = src_sends[s].name or "", color_packed = src_sends[s].color_packed or 0x888888, pre_fader = src_sends[s].pre_fader or false }
          end
          groups[g] = {
            name            = slot.groups[g].name,
            color_packed    = slot.groups[g].color_packed,
            folder_template = slot.groups[g].folder_template,
            sends           = sends_copy,
            routes_to       = slot.groups[g].routes_to or 0,
          }
          rename_group_buf[g] = slot.groups[g].name
        end
        -- Fix any track assignments that are now out of range
        for _, t in ipairs(tracks) do
          if t.group > NUM_GROUPS then t.group = NO_GROUP end
        end
        global_sends = {}
        for s = 1, #(slot.global_sends or {}) do
          local gs = slot.global_sends[s]
          global_sends[s] = { name = gs.name, template = gs.template, color_packed = gs.color_packed or 0x888888, pre_fader = gs.pre_fader or false }
        end
        global_send_buf = {}
        group_load_version = group_load_version + 1
        -- Restore options from preset
        if slot.opt_fx_folder          ~= nil then opt_fx_folder          = slot.opt_fx_folder          end
              if slot.opt_sends_at_bottom    ~= nil then opt_sends_at_bottom    = slot.opt_sends_at_bottom    end
        if slot.opt_send_color_packed  ~= nil then opt_send_color_packed  = slot.opt_send_color_packed  end
        if slot.opt_send_use_trk_color ~= nil then opt_send_use_trk_color = slot.opt_send_use_trk_color end
        if slot.opt_fx_bypass_inserts  ~= nil then opt_fx_bypass_inserts  = slot.opt_fx_bypass_inserts  end
        if slot.opt_fx_bypass_chains   ~= nil then opt_fx_bypass_chains   = slot.opt_fx_bypass_chains   end
        if slot.parent_color_packed    ~= nil then parent_color_packed    = slot.parent_color_packed    end
        if slot.parent_use_track_color ~= nil then parent_use_track_color = slot.parent_use_track_color end
        if slot.master_name            ~= nil then master_name            = slot.master_name            end
        if slot.master_fx_chain        ~= nil then master_fx_chain        = slot.master_fx_chain        end
        if slot.picker_show_chains     ~= nil then picker_show_chains     = slot.picker_show_chains end
        if slot.picker_show_vst3       ~= nil then picker_show_vst3       = slot.picker_show_vst3   end
        if slot.picker_show_vst        ~= nil then picker_show_vst        = slot.picker_show_vst    end
        if slot.picker_show_clap       ~= nil then picker_show_clap       = slot.picker_show_clap   end
        if slot.picker_show_js         ~= nil then picker_show_js         = slot.picker_show_js     end
        picker_rebuild_filtered()
            end
      end
      if not has_preset then r.ImGui_PopStyleColor(ctx, 3) end

      r.ImGui_TableSetColumnIndex(ctx, 3)
      if has_preset then
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x5a1a1aFF)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x8a2a2aFF)
        if r.ImGui_Button(ctx, "x##pclr"..p, 22, 0) then
          local msg = 'Delete preset "' .. preset_name_buf[p] .. '"?'
          if dlg_ShowMessageBox(msg, "Delete Preset", 4) == 6 then
            presets[p] = nil
            save_presets()
          end
        end
        r.ImGui_PopStyleColor(ctx, 2)
      end
    end
    r.ImGui_EndTable(ctx)
  end

  -- Export / Import / Capture / Set FX / Guess FX buttons (5 equal width)
  do
    local ei_w = math.floor((groups_w - 6 - 4 * 4) / 5)
    r.ImGui_Dummy(ctx, 6, 0) r.ImGui_SameLine(ctx, 0, 0)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x1a2a3aFF)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x2a4a6aFF)
    if r.ImGui_Button(ctx, "Export##expbtn", ei_w, 0) then export_presets() end
    r.ImGui_PopStyleColor(ctx, 2)
    r.ImGui_SameLine(ctx, 0, 4)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x1a3a2aFF)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x2a5a3aFF)
    if r.ImGui_Button(ctx, "Import##impbtn", ei_w, 0) then import_presets() end
    r.ImGui_PopStyleColor(ctx, 2)
    r.ImGui_SameLine(ctx, 0, 4)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x3a2a1aFF)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x5a4a2aFF)
    if r.ImGui_Button(ctx, "Capture##capbtn", ei_w, 0) then capture_from_session() end
    r.ImGui_PopStyleColor(ctx, 2)
    r.ImGui_SameLine(ctx, 0, 4)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x2a2a3aFF)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x3a3a5aFF)
    if r.ImGui_Button(ctx, "Set FX##grpsetfx", ei_w, 0) then start_guess_fx_groups() end
    r.ImGui_PopStyleColor(ctx, 2)
    r.ImGui_SameLine(ctx, 0, 4)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x1a2a3aFF)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x2a4a5aFF)
    if r.ImGui_Button(ctx, "Guess FX##grpguess", ei_w, 0) then
      if not fx_chain_list then scan_fx_chains() end
      open_scope_modal("Guess Group FX",
        "Auto-apply first matching FX chain to groups, global sends and master?",
        function(sc)
          push_undo()
          local function auto_apply(name, get_fx, set_fx)
            local nl = (name or ""):lower()
            if nl == "" then return end
            for _, entry in ipairs(fx_chain_list) do
              if entry.rel_path and entry.label:lower():find(nl, 1, true) then
                set_fx(entry.rel_path); return
              end
            end
          end
          for g2 = 1, NUM_GROUPS do
            if sc or group_selected[g2] then
              auto_apply(groups[g2].name,
                function() return groups[g2].folder_template end,
                function(v) groups[g2].folder_template = v end)
            end
          end
          for s2, gs2 in ipairs(global_sends) do
            if sc then
              auto_apply(gs2.name ~= "" and gs2.name or ("Global Send "..s2),
                function() return gs2.template end,
                function(v) gs2.template = v end)
            end
          end
          if sc then
            auto_apply("Master",
              function() return master_fx_chain end,
              function(v) master_fx_chain = v end)
          end
        end)
    end
    r.ImGui_PopStyleColor(ctx, 2)
  end
  r.ImGui_EndGroup(ctx)
  do
    local bx1, by1 = r.ImGui_GetItemRectMin(ctx)
    local bx2, by2 = r.ImGui_GetItemRectMax(ctx)
    local bdl = r.ImGui_GetWindowDrawList(ctx)
    r.ImGui_DrawList_AddRect(bdl, bx1, by1, bx1 + groups_w, by2 + 4, 0x454545FF, 0, 0, 1)
  end

  r.ImGui_EndChild(ctx)
  end  -- left_scroll child

  -- ════════════════════════════════════════════════════════════════════════════
  -- RIGHT PANEL: Tracks
  -- ════════════════════════════════════════════════════════════════════════════
  r.ImGui_SameLine(ctx, 0, gap)
  r.ImGui_BeginGroup(ctx)
  local btn_row_h = 28  -- reserved for fixed button row below track table
  if r.ImGui_BeginChild(ctx, "right_scroll", 0, avail_h - btn_row_h) then

  -- ── Panel header: "Tracks" label row ──────────────────────────────────────
  local tracks_hdr_w = r.ImGui_GetContentRegionAvail(ctx)
  if r.ImGui_BeginTable(ctx, "rhdr", 1, r.ImGui_TableFlags_BordersOuter(), tracks_hdr_w, 0) then
    r.ImGui_TableSetupColumn(ctx, "Tracks", r.ImGui_TableColumnFlags_WidthStretch())
    r.ImGui_TableHeadersRow(ctx)
    r.ImGui_EndTable(ctx)
  end

  local track_table_flags = r.ImGui_TableFlags_BordersOuter()
    | r.ImGui_TableFlags_BordersInnerV()
    | r.ImGui_TableFlags_RowBg()
    | r.ImGui_TableFlags_ScrollX()
    | r.ImGui_TableFlags_ScrollY()

  local num_gs         = #global_sends
  local active_sc      = build_active_send_cols()  -- {g, s} per dynamic send col
  local num_send_cols  = #active_sc
  local fx_col_idx     = 6 + num_send_cols + num_gs  -- absolute table col index for FX
  local total_cols     = fx_col_idx + 1
  -- Reverse touchpad horizontal scroll for the track table
  local _tracks_hwheel = 0
  if r.ImGui_IsWindowHovered and r.ImGui_IsWindowHovered(ctx) then
    if r.ImGui_GetMouseWheelH then
      _tracks_hwheel = -(r.ImGui_GetMouseWheelH(ctx))
    end
  end
  if r.ImGui_BeginTable(ctx, "tracks_table", total_cols, track_table_flags, 0, 0) then
    if _tracks_hwheel ~= 0 then
      local cur_sx = r.ImGui_GetScrollX(ctx)
      r.ImGui_SetScrollX(ctx, cur_sx + _tracks_hwheel * 20)
    end
    r.ImGui_TableSetupScrollFreeze(ctx, 6, 1)  -- freeze 6 left cols
    r.ImGui_TableSetupColumn(ctx, "#",          r.ImGui_TableColumnFlags_WidthFixed(),   30)
    r.ImGui_TableSetupColumn(ctx, "##selcol",   r.ImGui_TableColumnFlags_WidthFixed(),   22)
    r.ImGui_TableSetupColumn(ctx, "Track Name", r.ImGui_TableColumnFlags_WidthFixed(), 160)
    r.ImGui_TableSetupColumn(ctx, "Group",      r.ImGui_TableColumnFlags_WidthFixed(), 160)
    r.ImGui_TableSetupColumn(ctx, "\xE2\x97\x8E\xE2\x97\x8E", r.ImGui_TableColumnFlags_WidthFixed(),  22)
    r.ImGui_TableSetupColumn(ctx, "Pan",        r.ImGui_TableColumnFlags_WidthFixed(),  36)
    for ci, sc in ipairs(active_sc) do
      local snd = groups[sc.g].sends[sc.s]
      local lbl = (snd.name ~= "" and snd.name) or ("S"..sc.s)
      r.ImGui_TableSetupColumn(ctx, lbl, r.ImGui_TableColumnFlags_WidthFixed(), 45)
    end
    for gs_ci = 1, num_gs do
      local gs_lbl = global_sends[gs_ci].name ~= "" and global_sends[gs_ci].name or ("GS"..gs_ci)
      r.ImGui_TableSetupColumn(ctx, gs_lbl, r.ImGui_TableColumnFlags_WidthFixed(), 45)
    end
    r.ImGui_TableSetupColumn(ctx, "FX", r.ImGui_TableColumnFlags_WidthFixed(), 213)
    -- Manual header row with centered labels for Pan, S1-S5, GS1-GS8, #
    r.ImGui_TableNextRow(ctx, r.ImGui_TableRowFlags_Headers())
    local hdr_cols = {
      [0] = { label = "#",    center = true  },
      [1] = { label = "##selchk", center = false, is_checkbox = true },
      [2] = { label = "Track Name", center = false },
      [3] = { label = "Group", center = false },
      [4] = { label = "\xE2\x97\x8E\xE2\x97\x8E", center = false },
      [5] = { label = "Pan",  center = true  },
    }
    hdr_cols[fx_col_idx] = { label = "FX", center = false }
    for ci2, sc in ipairs(active_sc) do
      local snd = groups[sc.g].sends[sc.s]
      local lbl = (snd.name ~= "" and snd.name) or ("S"..sc.s)
      hdr_cols[5 + ci2] = { label = lbl, center = true }
    end
    for gs_ci = 1, num_gs do
      local gs_lbl = global_sends[gs_ci].name ~= "" and global_sends[gs_ci].name or ("GS"..gs_ci)
      hdr_cols[5 + num_send_cols + gs_ci] = { label = gs_lbl, center = true }
    end
    for ci = 0, fx_col_idx do
      r.ImGui_TableSetColumnIndex(ctx, ci)
      local hc = hdr_cols[ci]
      if hc and hc.center then
        local cw = r.ImGui_GetContentRegionAvail(ctx)
        local tw = r.ImGui_CalcTextSize(ctx, hc.label)
        r.ImGui_SetCursorPosX(ctx, r.ImGui_GetCursorPosX(ctx) + math.max(0, (cw - tw) / 2))
      end
      if hc and hc.is_checkbox then
        -- Select-all checkbox in header
        local all_sel = #tracks > 0
        for _, t2 in ipairs(tracks) do if not t2.selected then all_sel = false; break end end
        local cb_chg2, cb_new2 = r.ImGui_Checkbox(ctx, "##selhdr", all_sel)
        if cb_chg2 then
          for _, t2 in ipairs(tracks) do t2.selected = cb_new2 end
        end
      elseif hc then
        r.ImGui_TableHeader(ctx, hc.label .. "##trkhdr" .. ci)
      else
        r.ImGui_TableHeader(ctx, "##trkhdr" .. ci)
      end
    end

    for i, t in ipairs(tracks) do
      r.ImGui_TableNextRow(ctx)

      -- Col 0: track number — colored with group color
      r.ImGui_TableSetColumnIndex(ctx, 0)
      do
        local disp_cpacked = (t.group ~= NO_GROUP) and groups[t.group].color_packed or 0x444444
        local num_col = to_imgui_color(disp_cpacked, 255)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        num_col)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), num_col)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(),  num_col)
        -- choose black or white text depending on brightness
        local rr, gg, bb = unpack_color(disp_cpacked)
        local bright = (rr * 299 + gg * 587 + bb * 114) / 1000
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), bright > 140 and 0x000000FF or 0xFFFFFFFF)
        r.ImGui_Button(ctx, tostring(t.reaper_idx + 1) .. "##num" .. i, -1, 0)
        r.ImGui_PopStyleColor(ctx, 4)
      end

      local is_stereo_top    = t.stereo
      local is_stereo_bottom = (i > 1) and (tracks[i-1].stereo or false)
      -- Col 1: checkbox / selection (stereo pair border here)
      r.ImGui_TableSetColumnIndex(ctx, 1)
      if is_stereo_top or is_stereo_bottom then
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Border(), 0xFFFFFFAAFF)
        r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FrameBorderSize(), 1.5)
      end
      local sel_changed, new_sel = r.ImGui_Checkbox(ctx, "##sel"..i, t.selected)
      if is_stereo_top or is_stereo_bottom then
        r.ImGui_PopStyleColor(ctx, 1)
        r.ImGui_PopStyleVar(ctx)
      end
      if sel_changed then
        local alt_down   = r.ImGui_IsKeyDown(ctx, r.ImGui_Key_LeftAlt())
                        or r.ImGui_IsKeyDown(ctx, r.ImGui_Key_RightAlt())
        local shift_down = r.ImGui_IsKeyDown(ctx, r.ImGui_Key_LeftShift())
                        or r.ImGui_IsKeyDown(ctx, r.ImGui_Key_RightShift())
        local ctrl_down  = r.ImGui_IsKeyDown(ctx, r.ImGui_Key_LeftCtrl())
                        or r.ImGui_IsKeyDown(ctx, r.ImGui_Key_RightCtrl())
        if ctrl_down then
          -- Ctrl+click: deselect all, then select only tracks in same group
          local grp = t.group
          for _, st in ipairs(tracks) do st.selected = false end
          if grp ~= NO_GROUP then
            for _, st in ipairs(tracks) do
              if st.group == grp then st.selected = true end
            end
          else
            t.selected = true
          end
        elseif alt_down then
          -- Alt+click: deselect all, select only this track
          for _, st in ipairs(tracks) do st.selected = false end
          t.selected = true
        elseif shift_down then
          -- Shift+click: select range from last clicked
          if last_clicked and last_clicked ~= i then
            local lo = math.min(last_clicked, i)
            local hi = math.max(last_clicked, i)
            for j = lo, hi do tracks[j].selected = new_sel end
          else
            t.selected = new_sel
          end
        else
          t.selected = new_sel
        end
        last_clicked = i
      end

      -- Col 2: track name (editable)
      r.ImGui_TableSetColumnIndex(ctx, 2)
      r.ImGui_SetNextItemWidth(ctx, -1)
      local is_send_focused  = focused_track_send and focused_track_send.i == i
      if is_send_focused then
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Border(), 0xFFFFFFFFFF)
        r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FrameBorderSize(), 1.5)
      end
      local itflags = r.ImGui_InputTextFlags_AutoSelectAll()
      local name_changed, new_name = r.ImGui_InputText(ctx, "##name"..i, rename_track_buf[i], itflags)
      if is_send_focused then
        r.ImGui_PopStyleColor(ctx, 1)
        r.ImGui_PopStyleVar(ctx)
      end
      if name_changed then
        rename_track_buf[i] = new_name
        t.name = new_name
        local rtrack = r.GetTrack(0, t.reaper_idx)
        if rtrack then
          r.GetSetMediaTrackInfo_String(rtrack, "P_NAME", new_name, true)
        end
      end

      -- Col 3: group dropdown
      r.ImGui_TableSetColumnIndex(ctx, 3)
      r.ImGui_SetNextItemWidth(ctx, -1)
      local preview = t.group == NO_GROUP and "-- none --" or groups[t.group].name
      r.ImGui_SetNextWindowSizeConstraints(ctx, 0, 0, math.huge, 16 * 22)
      if r.ImGui_BeginCombo(ctx, "##grp"..i, preview) then
        if r.ImGui_Selectable(ctx, "-- none --", t.group == NO_GROUP) then
          push_undo()
          if t.selected then
            for _, st in ipairs(tracks) do
              if st.selected then st.group = NO_GROUP end
            end
          else
            t.group = NO_GROUP
          end
        end
        for g = 1, NUM_GROUPS do
          local is_sel = (t.group == g)
          local ic = to_imgui_color(groups[g].color_packed, 255)
          r.ImGui_ColorButton(ctx, "##swatchc"..g, ic,
            r.ImGui_ColorEditFlags_NoTooltip() | r.ImGui_ColorEditFlags_NoBorder(), 12, 12)
          r.ImGui_SameLine(ctx)
          if r.ImGui_Selectable(ctx, groups[g].name .. "##opt"..g, is_sel) then
            push_undo()
            if t.selected then
              for _, st in ipairs(tracks) do
                if st.selected then st.group = g end
              end
            else
              t.group = g
            end
          end
        end
        r.ImGui_EndCombo(ctx)
      end

      -- Col 4: stereo checkbox (greyed out if track above is stereo top)
      r.ImGui_TableSetColumnIndex(ctx, 4)
      if is_stereo_bottom then
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_CheckMark(),    0x333333FF)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBg(),      0x1e1e1eFF)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBgHovered(), 0x1e1e1eFF)
        r.ImGui_BeginDisabled(ctx, true)
        r.ImGui_Checkbox(ctx, "##stereo"..i, false)
        r.ImGui_EndDisabled(ctx)
        r.ImGui_PopStyleColor(ctx, 3)
      else
        local stereo_changed, stereo_val = r.ImGui_Checkbox(ctx, "##stereo"..i, t.stereo or false)
        if stereo_changed then push_undo(); t.stereo = stereo_val end
      end

      -- Col 5: pan text field
      -- Disabled if this track is stereo-checked, or if the track above it is
      local pan_locked = t.stereo or (i > 1 and (tracks[i-1].stereo or false))
      r.ImGui_TableSetColumnIndex(ctx, 5)
      r.ImGui_SetNextItemWidth(ctx, -1)
      if pan_locked then
        -- Grey out: same FramePadding as active field so row height stays consistent
        r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FramePadding(), 14, 3)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBg(),     0x2a2a2aFF)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(),        0x555555FF)
        r.ImGui_InputText(ctx, "##pan"..i, "",
          r.ImGui_InputTextFlags_ReadOnly())
        r.ImGui_PopStyleColor(ctx, 2)
        r.ImGui_PopStyleVar(ctx)
      else
        local pan_str_cur = pan_track_buf[i] or "C"
        if pan_str_cur == "" then pan_str_cur = "C" end
        local pan_valid   = (pan_str_cur == "") or (parse_pan(pan_str_cur) ~= nil)
        -- Center-align by adjusting frame padding based on string length
        local char_w = 7
        local field_w = 36
        local text_w = #pan_str_cur * char_w
        local pad_x = math.max(2, math.floor((field_w - text_w) / 2))
        r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FramePadding(), pad_x, 3)
        if not pan_valid then
          r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBg(), 0x6e1a1aFF)
        end
        local pan_changed, pan_val = r.ImGui_InputText(ctx, "##pan"..i, pan_str_cur,
          r.ImGui_InputTextFlags_AutoSelectAll())
        if not pan_valid then r.ImGui_PopStyleColor(ctx, 1) end
        r.ImGui_PopStyleVar(ctx)
        if r.ImGui_IsItemFocused(ctx) then
          focused_track_send_next = { g = nil, s = nil, i = i }
        end
        if r.ImGui_IsItemFocused(ctx) and r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Enter and r.ImGui_Key_Enter() or 525) then
          local ctrl = r.ImGui_IsKeyDown(ctx, r.ImGui_Key_LeftCtrl  and r.ImGui_Key_LeftCtrl()  or 641) or
                       r.ImGui_IsKeyDown(ctx, r.ImGui_Key_RightCtrl and r.ImGui_Key_RightCtrl() or 645)
          if ctrl then
            push_undo()
            local cur_pan = pan_track_buf[i] or "C"
            for i3, t3 in ipairs(tracks) do
              local pan_locked3 = t3.stereo or (i3 > 1 and (tracks[i3-1].stereo or false))
              if t3.selected and not pan_locked3 then
                pan_track_buf[i3] = cur_pan
                t3.pan_str = cur_pan
              end
            end
          end
        end
        if pan_changed then
          push_undo_debounced()
          pan_track_buf[i] = pan_val == "" and "C" or pan_val
          t.pan_str = pan_track_buf[i]
        end
      end

      -- Dynamic send dB fields (one per active_sc entry)
      local is_stereo_pair_bottom = (i > 1) and (tracks[i-1].stereo or false)
      for ci, sc in ipairs(active_sc) do
        r.ImGui_TableSetColumnIndex(ctx, 5 + ci)
        r.ImGui_SetNextItemWidth(ctx, -1)
        -- Column is active for this track if its group is in this track's ancestry
        local col_active = (t.group ~= NO_GROUP) and
                           (t.group == sc.g or is_group_descendant(t.group, sc.g))
        if not col_active or is_stereo_pair_bottom then
          r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBg(), 0x1e1e1eFF)
          r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(),    0x333333FF)
          r.ImGui_InputText(ctx, "##send"..i.."_"..ci, "", r.ImGui_InputTextFlags_ReadOnly())
          r.ImGui_PopStyleColor(ctx, 2)
        else
          if not send_track_buf[i] then send_track_buf[i] = {} end
          local skey = sc.g..":"..sc.s
          local send_str_cur = send_track_buf[i][skey] or ""
          local send_valid   = (send_str_cur == "") or (parse_db(send_str_cur) ~= nil)
          local pad_x2 = math.max(2, math.floor((45 - #send_str_cur * 7) / 2))
          r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FramePadding(), pad_x2, 3)
          if not send_valid then r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBg(), 0x6e1a1aFF) end
          local send_changed, send_val = r.ImGui_InputText(ctx, "##send"..i.."_"..ci,
            send_str_cur, r.ImGui_InputTextFlags_AutoSelectAll())
          if not send_valid then r.ImGui_PopStyleColor(ctx, 1) end
          r.ImGui_PopStyleVar(ctx)
          if r.ImGui_IsItemFocused(ctx) then
            focused_track_send_next = { g = sc.g, s = sc.s, i = i }
          end
          -- Ctrl+Enter: apply this value to all selected tracks with this send active
          if r.ImGui_IsItemFocused(ctx) and r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Enter and r.ImGui_Key_Enter() or 525) then
            local ctrl = r.ImGui_IsKeyDown(ctx, r.ImGui_Key_LeftCtrl  and r.ImGui_Key_LeftCtrl()  or 641) or
                         r.ImGui_IsKeyDown(ctx, r.ImGui_Key_RightCtrl and r.ImGui_Key_RightCtrl() or 645)
            if ctrl then
              push_undo()
              local cur_val = send_track_buf[i] and send_track_buf[i][skey] or ""
              for i3, t3 in ipairs(tracks) do
                local is_pb3 = (i3 > 1) and (tracks[i3-1].stereo or false)
                local col_active3 = (t3.group ~= NO_GROUP) and
                  (t3.group == sc.g or is_group_descendant(t3.group, sc.g))
                if t3.selected and col_active3 and not is_pb3 then
                  if not send_track_buf[i3] then send_track_buf[i3] = {} end
                  send_track_buf[i3][skey] = cur_val
                  if not t3.sends then t3.sends = {} end
                  t3.sends[skey] = cur_val
                end
              end
            end
          end
          if send_changed then
            push_undo_debounced()
            send_track_buf[i][skey] = send_val
            if not t.sends then t.sends = {} end
            t.sends[skey] = send_val
          end
        end
      end

      -- Global send dB fields
      for gs = 1, num_gs do
        r.ImGui_TableSetColumnIndex(ctx, 5 + num_send_cols + gs)
        r.ImGui_SetNextItemWidth(ctx, -1)
        if is_stereo_pair_bottom then
          r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBg(), 0x1e1e1eFF)
          r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(),    0x333333FF)
          r.ImGui_InputText(ctx, "##gsend"..i.."_"..gs, "", r.ImGui_InputTextFlags_ReadOnly())
          r.ImGui_PopStyleColor(ctx, 2)
        else
          if not global_send_buf[i] then global_send_buf[i] = {} end
          local gsval = global_send_buf[i][gs] or ""
          local gsvalid = (gsval == "") or (parse_db(gsval) ~= nil)
          local gfw = 45
          local gtw = #gsval * 7
          local gpx = math.max(2, math.floor((gfw - gtw) / 2))
          r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FramePadding(), gpx, 3)
          if not gsvalid then r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBg(), 0x6e1a1aFF) end
          local gsch, gsv2 = r.ImGui_InputText(ctx, "##gsend"..i.."_"..gs, gsval, r.ImGui_InputTextFlags_AutoSelectAll())
          if not gsvalid then r.ImGui_PopStyleColor(ctx) end
          r.ImGui_PopStyleVar(ctx)
          if r.ImGui_IsItemFocused(ctx) then
            focused_track_send_next = { g = nil, s = gs, i = i }
          end
          if gsch then
            push_undo_debounced()
            global_send_buf[i][gs] = gsv2
          end
        end
      end

      -- Track FX button + clear
      r.ImGui_TableSetColumnIndex(ctx, fx_col_idx)
      if is_stereo_pair_bottom then
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x1e1e1eFF)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(),          0x333333FF)
        r.ImGui_Button(ctx, "##fxdis"..i, -1, 0)
        r.ImGui_PopStyleColor(ctx, 2)
      else
        local trk_tmpl = t.fx_chain
        local tkpreview = fx_preview(trk_tmpl) or "-- FX --"
        local tkx_w = trk_tmpl and 26 or 0
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        trk_tmpl and 0x1a3a1aFF or 0x2a2a2aFF)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), trk_tmpl and 0x2a5a2aFF or 0x3a3a3aFF)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(),          trk_tmpl and 0xAAFFAAFF or 0x888888FF)
        if r.ImGui_Button(ctx, tkpreview .. "##tkfxbtn"..i, -1 - tkx_w, 0) then
          open_picker("track", i, nil, nil)
          local tmod_ctrl  = r.ImGui_IsKeyDown(ctx, r.ImGui_Key_LeftCtrl  and r.ImGui_Key_LeftCtrl()  or 641) or r.ImGui_IsKeyDown(ctx, r.ImGui_Key_RightCtrl and r.ImGui_Key_RightCtrl() or 645)
          local tmod_shift = r.ImGui_IsKeyDown(ctx, r.ImGui_Key_LeftShift and r.ImGui_Key_LeftShift() or 640) or r.ImGui_IsKeyDown(ctx, r.ImGui_Key_RightShift and r.ImGui_Key_RightShift() or 644)
          if picker_state then picker_state.mod_ctrl = tmod_ctrl; picker_state.mod_shift = tmod_shift end
        end
        r.ImGui_PopStyleColor(ctx, 3)
        if trk_tmpl then
          r.ImGui_SameLine(ctx, 0, 4)
          r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x5a1a1aFF)
          r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x8a2a2aFF)
          if r.ImGui_Button(ctx, "x##fxclr"..i, 22, 0) then
            local ctrl_clr = r.ImGui_IsKeyDown(ctx, r.ImGui_Key_LeftCtrl  and r.ImGui_Key_LeftCtrl()  or 641) or
                             r.ImGui_IsKeyDown(ctx, r.ImGui_Key_RightCtrl and r.ImGui_Key_RightCtrl() or 645)
            if ctrl_clr then
              -- Ctrl+X: clear FX on all selected tracks
              local sel_names = {}
              for _, st in ipairs(tracks) do
                if st.selected and st.fx_chain then sel_names[#sel_names+1] = st.name end
              end
              if not t.selected and t.fx_chain then sel_names[#sel_names+1] = t.name end
              local msg = #sel_names > 0
                and ("Clear track FX on: " .. table.concat(sel_names, ", ") .. "?")
                or  "Clear track FX?"
              if dlg_ShowMessageBox(msg, "Clear FX", 4) == 6 then
                push_undo()
                t.fx_chain = nil
                for _, st in ipairs(tracks) do
                  if st.selected then st.fx_chain = nil end
                end
              end
            else
              if dlg_ShowMessageBox("Clear track FX?", "Clear FX", 4) == 6 then
                push_undo(); t.fx_chain = nil
              end
            end
          end
          r.ImGui_PopStyleColor(ctx, 2)
        end
      end

    end

    r.ImGui_EndTable(ctx)
  end

  r.ImGui_EndChild(ctx)
  end  -- right_scroll child

  -- ── Buttons below track table ────────────────────────────────────────────────
  r.ImGui_Spacing(ctx)
  if r.ImGui_Button(ctx, "Refresh", 80, 0) then refresh_tracks() end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "Clear Groups", 80, 0) then
    if dlg_ShowMessageBox("Clear all group assignments?", "Clear Groups", 4) == 6 then
      for _, t in ipairs(tracks) do t.group = NO_GROUP end
    end
  end
  r.ImGui_SameLine(ctx, 0, 8)
  -- Bulk send/pan buttons
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x2a3a2aFF)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x3a5a3aFF)
  if r.ImGui_Button(ctx, "Set All##bsndv", 60, 0) then
    modal_pending = {
      title       = "Set All Sends",
      msg         = "Set all send values to:",
      input_label = "Value:",
      input_buf   = "0",
      callback    = function(sc, val)
        if val and val ~= "" then push_undo(); apply_all_sends_value(val, sc) end
      end,
    }
  end
  r.ImGui_PopStyleColor(ctx, 2)
  r.ImGui_SameLine(ctx, 0, 4)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x1a3a1aFF)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x2a5a2aFF)
  if r.ImGui_Button(ctx, "0 All##bsnd0", 60, 0) then
    open_scope_modal("Set All Sends", "Set ALL send values to 0 dB?",
      function(sc) push_undo(); apply_all_sends_value("0", sc) end)
  end
  r.ImGui_PopStyleColor(ctx, 2)
  r.ImGui_SameLine(ctx, 0, 4)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x1a1a3aFF)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x2a2a5aFF)
  if r.ImGui_Button(ctx, "inf All##bsndi", 60, 0) then
    open_scope_modal("Set All Sends", "Set ALL send values to -inf?",
      function(sc) push_undo(); apply_all_sends_value("i", sc) end)
  end
  r.ImGui_PopStyleColor(ctx, 2)
  r.ImGui_SameLine(ctx, 0, 4)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x5a1a1aFF)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x8a2a2aFF)
  if r.ImGui_Button(ctx, "Clr All##bsndx", 60, 0) then
    open_scope_modal("Clear All Sends", "Clear ALL send values?",
      function(sc) push_undo(); apply_all_sends_value("", sc) end)
  end
  r.ImGui_PopStyleColor(ctx, 2)
  r.ImGui_SameLine(ctx, 0, 4)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x2a2a2aFF)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x3a3a3aFF)
  if r.ImGui_Button(ctx, "Ctr Pan##bcp", 60, 0) then
    open_scope_modal("Center Pan", "Center pan values?", function(sc)
      push_undo()
      for i2, t2 in ipairs(tracks) do
        local pan_locked = t2.stereo or (i2 > 1 and (tracks[i2-1].stereo or false))
        if not pan_locked and (sc or t2.selected) then
          pan_track_buf[i2] = "C"
          t2.pan_str = "C"
        end
      end
    end)
  end
  r.ImGui_PopStyleColor(ctx, 2)
  r.ImGui_SameLine(ctx, 0, 4)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x2a2a2aFF)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x3a3a3aFF)
  if r.ImGui_Button(ctx, "Spr Pan##bsp", 60, 0) then
    local spread = math.max(0, math.min(100, math.floor(tonumber(spr_pan_buf) or 50)))
    open_scope_modal("Spread Pan", "Spread panning " .. spread .. "L to " .. spread .. "R?",
      function(sc)
        push_undo()
        -- Collect eligible track indices
        local eligible = {}
        for i2, t2 in ipairs(tracks) do
          local pan_locked = t2.stereo or (i2 > 1 and (tracks[i2-1].stereo or false))
          if not pan_locked and (sc or t2.selected) then
            eligible[#eligible+1] = i2
          end
        end
        local n = #eligible
        if n == 0 then return end
        if n == 1 then
          pan_track_buf[eligible[1]] = "C"
          tracks[eligible[1]].pan_str = "C"
        else
          for k, i2 in ipairs(eligible) do
            -- Evenly space from -spread to +spread
            local pct = -spread + (k - 1) * (spread * 2 / (n - 1))
            local pan_str
            if math.abs(pct) < 0.5 then
              pan_str = "C"
            elseif pct < 0 then
              pan_str = math.floor(-pct + 0.5) .. "L"
            else
              pan_str = math.floor(pct + 0.5) .. "R"
            end
            pan_track_buf[i2] = pan_str
            tracks[i2].pan_str = pan_str
          end
        end
      end)
  end
  r.ImGui_PopStyleColor(ctx, 2)
  r.ImGui_SameLine(ctx, 0, 4)
  r.ImGui_SetNextItemWidth(ctx, 32)
  local spr_char_w = 7
  local spr_text_w = #spr_pan_buf * spr_char_w
  local spr_pad_x  = math.max(2, math.floor((32 - spr_text_w) / 2))
  r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FramePadding(), spr_pad_x, 3)
  local spr_ch, spr_val = r.ImGui_InputText(ctx, "##sprval", spr_pan_buf,
    r.ImGui_InputTextFlags_AutoSelectAll())
  r.ImGui_PopStyleVar(ctx)
  if spr_ch then spr_pan_buf = spr_val end
  r.ImGui_SameLine(ctx, 0, 8)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x2a2a3aFF)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x3a3a5aFF)
  if r.ImGui_Button(ctx, "Set Track FX##settrackfx", 0, 0) then start_guess_fx() end
  r.ImGui_PopStyleColor(ctx, 2)
  r.ImGui_SameLine(ctx, 0, 4)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x1a2a3aFF)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x2a4a5aFF)
  if r.ImGui_Button(ctx, "Guess Track FX##autoguess", 0, 0) then
    if not fx_chain_list then scan_fx_chains() end
    open_scope_modal("Guess Track FX",
      "Auto-apply first matching FX chain to tracks?",
      function(sc)
        push_undo()
        for _, t2 in ipairs(tracks) do
          if sc or t2.selected then
            local tname_lower = (t2.name or ""):lower()
            if tname_lower ~= "" then
              for _, entry in ipairs(fx_chain_list) do
                if entry.rel_path and entry.label:lower():find(tname_lower, 1, true) then
                  t2.fx_chain = entry.rel_path
                  break
                end
              end
            end
          end
        end
      end)
  end
  r.ImGui_PopStyleColor(ctx, 2)
  do
    local run_w  = 80
    local ud_w   = 36
    local sv_w   = 46
    local avail  = r.ImGui_GetContentRegionAvail(ctx)
    local cur_x  = r.ImGui_GetCursorPosX(ctx)
    local right  = cur_x + avail
    -- Save/Load track panel (debug helpers)
    r.ImGui_SameLine(ctx)
    r.ImGui_SetCursorPosX(ctx, right - run_w - (ud_w + 4) * 2 - (sv_w + 4) * 2)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x2a3a2aFF)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x3a5a3aFF)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(),          0xAAFFAAFF)
    if r.ImGui_Button(ctx, "Save##tpsave", sv_w, 0) then
      if dlg_ShowMessageBox("Overwrite saved track panel snapshot?", "Save Track Panel", 4) == 6 then
      -- Serialise track state keyed by GUID into ExtState
      local lines = {}
      for i, t in ipairs(tracks) do
        local guid = t.guid or ""
        if guid ~= "" then
          local sends_str = ""
          if send_track_buf[i] then
            local parts = {}
            for k, v in pairs(send_track_buf[i]) do
              parts[#parts+1] = tostring(k) .. "=" .. tostring(v)
            end
            sends_str = table.concat(parts, ";")
          end
          local gs_str = ""
          if global_send_buf[i] then
            local parts = {}
            for s, v in pairs(global_send_buf[i]) do
              parts[#parts+1] = tostring(s) .. "=" .. tostring(v)
            end
            gs_str = table.concat(parts, ";")
          end
          lines[#lines+1] = table.concat({
            guid,
            tostring(t.group or 0),
            t.stereo and "1" or "0",
            t.pan_str or "C",
            t.fx_chain or "",
            sends_str,
            gs_str,
          }, "\t")
        end
      end
      r.SetExtState(EXT_SECTION, "tp_snapshot", table.concat(lines, "||"), true)
      r.SetExtState(EXT_SECTION, "tp_snapshot_exists", "1", true)
      r.ShowMessageBox("Track panel saved (" .. #lines .. " tracks).", "Save OK", 0)
      end  -- confirm save
    end
    r.ImGui_PopStyleColor(ctx, 3)
    r.ImGui_SameLine(ctx, 0, 4)
    local has_tp_snap = r.GetExtState(EXT_SECTION, "tp_snapshot_exists") == "1"
    if not has_tp_snap then r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0x444444FF) end
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        has_tp_snap and 0x2a2a3aFF or 0x222222FF)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), has_tp_snap and 0x3a3a5aFF or 0x222222FF)
    if r.ImGui_Button(ctx, "Load##tpload", sv_w, 0) and has_tp_snap then
      if dlg_ShowMessageBox("Load saved track panel snapshot?\nThis will overwrite current track panel state.", "Load Track Panel", 4) == 6 then
      local raw = r.GetExtState(EXT_SECTION, "tp_snapshot")
      if raw ~= "" then
        push_undo()
        -- Build GUID lookup
        local by_guid = {}
        for _, line in ipairs(r.HasExtState and {} or {}) do end  -- no-op
        for _, line in next, (function()
          local t2 = {}
          for ln in (raw .. "||"):gmatch("([^|]*)||") do
            if ln ~= "" then t2[#t2+1] = ln end
          end
          return t2
        end)() do
          local parts = {}
          for p in (line .. "\t"):gmatch("([^\t]*)\t") do parts[#parts+1] = p end
          local guid     = parts[1] or ""
          local grp      = tonumber(parts[2]) or 0
          local stereo   = (parts[3] == "1")
          local pan_str  = parts[4] or "C"
          local fx_chain = parts[5] ~= "" and parts[5] or nil
          local sends_str = parts[6] or ""
          local gs_str    = parts[7] or ""
          local sends = {}
          for kv in (sends_str .. ";"):gmatch("([^;]*);") do
            local k, v = kv:match("^([^=]+)=(.*)$")
            if k then sends[k] = v end
          end
          local gs_vals = {}
          for kv in (gs_str .. ";"):gmatch("([^;]*);") do
            local k, v = kv:match("^([^=]+)=(.*)$")
            if k then gs_vals[tonumber(k)] = v end
          end
          by_guid[guid] = { group = grp, stereo = stereo, pan_str = pan_str,
                            fx_chain = fx_chain, sends = sends, gs_vals = gs_vals }
        end
        -- Apply to matching tracks
        local restored = 0
        for i, t in ipairs(tracks) do
          local snap = t.guid and by_guid[t.guid]
          if snap then
            t.group    = (snap.group > 0 and snap.group <= NUM_GROUPS) and snap.group or NO_GROUP
            t.stereo   = snap.stereo
            t.pan_str  = snap.pan_str
            t.fx_chain = snap.fx_chain
            pan_track_buf[i]  = snap.pan_str
            send_track_buf[i] = snap.sends
            t.sends           = snap.sends
            global_send_buf[i] = {}
            for s, v in pairs(snap.gs_vals) do global_send_buf[i][s] = v end
            restored = restored + 1
          end
        end
        r.ShowMessageBox("Track panel loaded (" .. restored .. " tracks matched).", "Load OK", 0)
      end  -- confirm load
      end
    end
    r.ImGui_PopStyleColor(ctx, 2)
    if not has_tp_snap then r.ImGui_PopStyleColor(ctx) end
    -- Undo button
    local has_undo = #undo_stack > 0
    local has_redo = #redo_stack > 0
    r.ImGui_SameLine(ctx, 0, 4)
    if not has_undo then r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0x444444FF) end
    if r.ImGui_Button(ctx, "\xE2\x86\x90##undo", ud_w, 0) and has_undo then do_undo() end
    if not has_undo then r.ImGui_PopStyleColor(ctx) end
    -- Redo button
    r.ImGui_SameLine(ctx, 0, 4)
    if not has_redo then r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0x444444FF) end
    if r.ImGui_Button(ctx, "\xE2\x86\x92##redo", ud_w, 0) and has_redo then do_redo() end
    if not has_redo then r.ImGui_PopStyleColor(ctx) end
    -- RUN button
    r.ImGui_SameLine(ctx, 0, 4)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x2a7a2aFF)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x3aaa3aFF)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(),  0x1a5a1aFF)
    if r.ImGui_Button(ctx, "  RUN  ", run_w, 0) then run_and_preserve() end
    r.ImGui_PopStyleColor(ctx, 3)
  end


  r.ImGui_EndGroup(ctx)

  -- ── Scope modal popup (All / Selected Only / Cancel) ─────────────────────────
  if modal_pending then
    r.ImGui_OpenPopup(ctx, "##scopemodal")
  end
  local mp = modal_pending
  if r.ImGui_BeginPopupModal(ctx, "##scopemodal", nil,
      r.ImGui_WindowFlags_AlwaysAutoResize()) then
    r.ImGui_Text(ctx, mp and mp.title or "")
    r.ImGui_Separator(ctx)
    r.ImGui_Spacing(ctx)
    r.ImGui_Text(ctx, mp and mp.msg or "")
    r.ImGui_Spacing(ctx)
    if mp and mp.input_label then
      r.ImGui_Text(ctx, mp.input_label)
      r.ImGui_SameLine(ctx, 0, 6)
      r.ImGui_SetNextItemWidth(ctx, 80)
      local modal_val = mp.input_buf or ""
      local modal_valid = (modal_val == "") or (parse_db(modal_val) ~= nil)
      if not modal_valid then
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBg(), 0x6e1a1aFF)
      end
      local ic, iv = r.ImGui_InputText(ctx, "##modalinput", modal_val,
        r.ImGui_InputTextFlags_AutoSelectAll())
      if not modal_valid then r.ImGui_PopStyleColor(ctx) end
      if ic then mp.input_buf = iv end
      r.ImGui_Spacing(ctx)
    end
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x1a3a1aFF)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x2a5a2aFF)
    if r.ImGui_Button(ctx, "All##sma", 100, 0) then
      if mp then mp.callback(true, mp.input_buf) end
      modal_pending = nil
      r.ImGui_CloseCurrentPopup(ctx)
    end
    r.ImGui_PopStyleColor(ctx, 2)
    r.ImGui_SameLine(ctx, 0, 8)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x1a2a3aFF)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x2a4a6aFF)
    if r.ImGui_Button(ctx, "Selected Only##sms", 120, 0) then
      if mp then mp.callback(false, mp.input_buf) end
      modal_pending = nil
      r.ImGui_CloseCurrentPopup(ctx)
    end
    r.ImGui_PopStyleColor(ctx, 2)
    r.ImGui_SameLine(ctx, 0, 8)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x3a1a1aFF)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x5a2a2aFF)
    if r.ImGui_Button(ctx, "Cancel##smc", 80, 0) then
      modal_pending = nil
      r.ImGui_CloseCurrentPopup(ctx)
    end
    r.ImGui_PopStyleColor(ctx, 2)
    if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape and r.ImGui_Key_Escape() or 256) then
      modal_pending = nil
      r.ImGui_CloseCurrentPopup(ctx)
    end
    r.ImGui_EndPopup(ctx)
  end

  -- Set Group FX modal
  if guess_fx_grp_modal then
    r.ImGui_SetNextWindowSizeConstraints(ctx, 510, 0, math.huge, math.huge)
    r.ImGui_OpenPopup(ctx, "##guessfxgrpmodal")
  end
  local ggm = guess_fx_grp_modal
  if r.ImGui_BeginPopupModal(ctx, "##guessfxgrpmodal", nil,
      r.ImGui_WindowFlags_AlwaysAutoResize()) then
    if ggm then
      local item = ggm.glist[ggm.cur]
      local grp2 = item
      r.ImGui_PushFont(ctx, font_large, 15)
      r.ImGui_Text(ctx, "Set Group FX  (" .. ggm.cur .. " / " .. #ggm.glist .. ")")
      r.ImGui_PopFont(ctx)
      r.ImGui_Separator(ctx)
      r.ImGui_Spacing(ctx)
      r.ImGui_PushFont(ctx, font_xlarge, 26)
      r.ImGui_Text(ctx, grp2 and grp2.name or "")
      r.ImGui_PopFont(ctx)
      local nav_w2    = 30 + 4 + 30
      local avail_ggm = r.ImGui_GetContentRegionAvail(ctx)
      local cur_ggm_x = r.ImGui_GetCursorPosX(ctx)
      r.ImGui_SameLine(ctx)
      r.ImGui_SetCursorPosX(ctx, cur_ggm_x + avail_ggm - nav_w2)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x2a2a3aFF)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x3a3a5aFF)
      if r.ImGui_Button(ctx, "<-##ggfxprev", 30, 0) and ggm.cur > 1 then
        r.ImGui_CloseCurrentPopup(ctx); guess_fx_grp_modal = nil; ggm.advance(ggm.cur - 1)
      end
      r.ImGui_SameLine(ctx, 0, 4)
      if r.ImGui_Button(ctx, "->##ggfxnext", 30, 0) and ggm.cur < #ggm.glist then
        r.ImGui_CloseCurrentPopup(ctx); guess_fx_grp_modal = nil; ggm.advance(ggm.cur + 1)
      end
      r.ImGui_PopStyleColor(ctx, 2)
      r.ImGui_Spacing(ctx)
      r.ImGui_PushFont(ctx, font_large, 15)
      local cur_ftmpl = grp2 and grp2.get_fx()
      if cur_ftmpl then
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xAAFFAAFF)
        r.ImGui_Text(ctx, "Current: " .. cur_ftmpl)
        r.ImGui_PopStyleColor(ctx)
        r.ImGui_SameLine(ctx, 0, 8)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x5a1a1aFF)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x8a2a2aFF)
        if r.ImGui_Button(ctx, "x##ggfxclrcur", 22, 0) then
          push_undo(); grp2.set_fx(nil)
        end
        r.ImGui_PopStyleColor(ctx, 2)
      else
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0x666666FF)
        r.ImGui_Text(ctx, "Current: -- none --")
        r.ImGui_PopStyleColor(ctx)
      end
      r.ImGui_PopFont(ctx)
      r.ImGui_Spacing(ctx)
      if #ggm.matches == 0 then
        r.ImGui_PushFont(ctx, font_large, 15)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0x666666FF)
        r.ImGui_Text(ctx, "(no matching FX chains found)")
        r.ImGui_PopStyleColor(ctx)
        r.ImGui_PopFont(ctx)
      else
        r.ImGui_PushFont(ctx, font_large, 15)
        r.ImGui_Text(ctx, "Matches:")
        r.ImGui_PopFont(ctx)
        r.ImGui_BeginChild(ctx, "##ggfxlist", -1, math.min(#ggm.matches * 20 + 8, 160))
        for mi, m in ipairs(ggm.matches) do
          local is_sel = (ggm.selected == mi)
          if r.ImGui_Selectable(ctx, m.label .. "##ggfxm"..mi, is_sel,
              r.ImGui_SelectableFlags_AllowDoubleClick()) then
            ggm.selected = mi
            if r.ImGui_IsMouseDoubleClicked(ctx, 0) then
              if grp2 then push_undo(); grp2.set_fx(m.rel_path) end
              local nxt = ggm.cur + 1
              r.ImGui_CloseCurrentPopup(ctx); guess_fx_grp_modal = nil; ggm.advance(nxt)
            end
          end
        end
        r.ImGui_EndChild(ctx)
      end
      r.ImGui_Spacing(ctx)
      local can_apply2 = #ggm.matches > 0
      if not can_apply2 then
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x222222FF)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x222222FF)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(),          0x444444FF)
      else
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x1a3a1aFF)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x2a5a2aFF)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(),          0xFFFFFFFF)
      end
      if r.ImGui_Button(ctx, "Apply##ggfxa", 90, 0) and can_apply2 then
        local sel_e = ggm.matches[ggm.selected]
        if sel_e and grp2 then push_undo(); grp2.set_fx(sel_e.rel_path) end
        local nxt = ggm.cur + 1
        r.ImGui_CloseCurrentPopup(ctx); guess_fx_grp_modal = nil; ggm.advance(nxt)
      end
      r.ImGui_PopStyleColor(ctx, 3)
      r.ImGui_SameLine(ctx, 0, 8)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x1a2a3aFF)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x2a4a6aFF)
      if r.ImGui_Button(ctx, "Skip##ggfxs", 90, 0) or
          r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Space and r.ImGui_Key_Space() or 32) then
        local nxt = ggm.cur + 1
        r.ImGui_CloseCurrentPopup(ctx); guess_fx_grp_modal = nil; ggm.advance(nxt)
      end
      r.ImGui_PopStyleColor(ctx, 2)
      r.ImGui_SameLine(ctx, 0, 8)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x3a1a1aFF)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x5a2a2aFF)
      if r.ImGui_Button(ctx, "Cancel##ggfxc", 90, 0) then
        guess_fx_grp_modal = nil; r.ImGui_CloseCurrentPopup(ctx)
      end
      r.ImGui_PopStyleColor(ctx, 2)
    end
    if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape and r.ImGui_Key_Escape() or 256) then
      guess_fx_grp_modal = nil; r.ImGui_CloseCurrentPopup(ctx)
    end
    if ggm and r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_LeftArrow and r.ImGui_Key_LeftArrow() or 263) and ggm.cur > 1 then
      r.ImGui_CloseCurrentPopup(ctx); guess_fx_grp_modal = nil; ggm.advance(ggm.cur - 1)
    end
    if ggm and r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_RightArrow and r.ImGui_Key_RightArrow() or 262) and ggm.cur < #ggm.glist then
      r.ImGui_CloseCurrentPopup(ctx); guess_fx_grp_modal = nil; ggm.advance(ggm.cur + 1)
    end
    r.ImGui_EndPopup(ctx)
  end

  -- Guess Track FX modal
  if guess_fx_modal then
    r.ImGui_SetNextWindowSizeConstraints(ctx, 510, 0, math.huge, math.huge)
    r.ImGui_OpenPopup(ctx, "##guessfxmodal")
  end
  local gm = guess_fx_modal
  if r.ImGui_BeginPopupModal(ctx, "##guessfxmodal", nil,
      r.ImGui_WindowFlags_AlwaysAutoResize()) then
    if gm then
      local item = gm.tlist[gm.cur]
      local t    = item and item.t
      -- Header
      r.ImGui_PushFont(ctx, font_large,  15)
      r.ImGui_Text(ctx, "Guess Track FX  (" .. gm.cur .. " / " .. #gm.tlist .. ")")
      r.ImGui_PopFont(ctx)
      r.ImGui_Separator(ctx)
      r.ImGui_Spacing(ctx)
      -- Track name (double size) — nav arrows pinned to right edge
      r.ImGui_PushFont(ctx, font_xlarge, 26)
      r.ImGui_Text(ctx, t and t.name or "")
      r.ImGui_PopFont(ctx)
      local nav_w    = 30 + 4 + 30  -- <- gap ->
      local avail_gm = r.ImGui_GetContentRegionAvail(ctx)
      local cur_gm_x = r.ImGui_GetCursorPosX(ctx)
      r.ImGui_SameLine(ctx)
      r.ImGui_SetCursorPosX(ctx, cur_gm_x + avail_gm - nav_w)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x2a2a3aFF)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x3a3a5aFF)
      if r.ImGui_Button(ctx, "<-##gfxprev", 30, 0) and gm.cur > 1 then
        r.ImGui_CloseCurrentPopup(ctx)
        guess_fx_modal = nil
        gm.advance(gm.cur - 1)
      end
      r.ImGui_SameLine(ctx, 0, 4)
      if r.ImGui_Button(ctx, "->##gfxnext", 30, 0) and gm.cur < #gm.tlist then
        r.ImGui_CloseCurrentPopup(ctx)
        guess_fx_modal = nil
        gm.advance(gm.cur + 1)
      end
      r.ImGui_PopStyleColor(ctx, 2)
      r.ImGui_Spacing(ctx)
      r.ImGui_PushFont(ctx, font_large,  15)
      local cur_chain = t and t.fx_chain
      if cur_chain then
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xAAFFAAFF)
        r.ImGui_Text(ctx, "Current: " .. cur_chain)
        r.ImGui_PopStyleColor(ctx)
        r.ImGui_SameLine(ctx, 0, 8)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x5a1a1aFF)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x8a2a2aFF)
        if r.ImGui_Button(ctx, "x##gfxclrcur", 22, 0) then
          push_undo(); t.fx_chain = nil
        end
        r.ImGui_PopStyleColor(ctx, 2)
      else
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0x666666FF)
        r.ImGui_Text(ctx, "Current: -- none --")
        r.ImGui_PopStyleColor(ctx)
      end
      r.ImGui_PopFont(ctx)
      r.ImGui_Spacing(ctx)
      -- Match list
      if #gm.matches == 0 then
        r.ImGui_PushFont(ctx, font_large,  15)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0x666666FF)
        r.ImGui_Text(ctx, "(no matching FX chains found)")
        r.ImGui_PopStyleColor(ctx)
        r.ImGui_PopFont(ctx)
      else
        r.ImGui_PushFont(ctx, font_large,  15)
      r.ImGui_Text(ctx, "Matches:")
      r.ImGui_PopFont(ctx)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ChildBg(), 0x1a1a1aFF)
        r.ImGui_BeginChild(ctx, "##gfxlist", -1, math.min(#gm.matches * 20 + 8, 160))
        for mi, m in ipairs(gm.matches) do
          local is_sel = (gm.selected == mi)
          if r.ImGui_Selectable(ctx, m.label .. "##gfxm"..mi, is_sel,
              r.ImGui_SelectableFlags_AllowDoubleClick()) then
            gm.selected = mi
            if r.ImGui_IsMouseDoubleClicked(ctx, 0) then
              local t2 = gm.tlist[gm.cur] and gm.tlist[gm.cur].t
              if t2 then push_undo(); t2.fx_chain = m.rel_path end
              local nxt = gm.cur + 1
              r.ImGui_CloseCurrentPopup(ctx)
              guess_fx_modal = nil
              gm.advance(nxt)
            end
          end
        end
        r.ImGui_EndChild(ctx)
        r.ImGui_PopStyleColor(ctx)
      end
      r.ImGui_Spacing(ctx)
      -- Buttons
      local can_apply = #gm.matches > 0
      if not can_apply then
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x222222FF)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x222222FF)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(),          0x444444FF)
      else
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x1a3a1aFF)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x2a5a2aFF)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(),          0xFFFFFFFF)
      end
      if r.ImGui_Button(ctx, "Apply##gfxa", 90, 0) and can_apply then
        local sel_entry = gm.matches[gm.selected]
        if sel_entry and t then
          push_undo()
          t.fx_chain = sel_entry.rel_path
        end
        local nxt = gm.cur + 1
        r.ImGui_CloseCurrentPopup(ctx)
        guess_fx_modal = nil
        gm.advance(nxt)
      end
      r.ImGui_PopStyleColor(ctx, 3)
      r.ImGui_SameLine(ctx, 0, 8)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x1a2a3aFF)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x2a4a6aFF)
      if r.ImGui_Button(ctx, "Skip##gfxs", 90, 0) or r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Space and r.ImGui_Key_Space() or 32) then
        local nxt = gm.cur + 1
        r.ImGui_CloseCurrentPopup(ctx)
        guess_fx_modal = nil
        gm.advance(nxt)
      end
      r.ImGui_PopStyleColor(ctx, 2)
      r.ImGui_SameLine(ctx, 0, 8)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x3a1a1aFF)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x5a2a2aFF)
      if r.ImGui_Button(ctx, "Cancel##gfxc", 90, 0) then
        guess_fx_modal = nil
        r.ImGui_CloseCurrentPopup(ctx)
      end
      r.ImGui_PopStyleColor(ctx, 2)
    end
    if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape and r.ImGui_Key_Escape() or 256) then
      guess_fx_modal = nil
      r.ImGui_CloseCurrentPopup(ctx)
    end
    if gm and r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_LeftArrow  and r.ImGui_Key_LeftArrow()  or 263) and gm.cur > 1 then
      r.ImGui_CloseCurrentPopup(ctx)
      guess_fx_modal = nil
      gm.advance(gm.cur - 1)
    end
    if gm and r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_RightArrow and r.ImGui_Key_RightArrow() or 262) and gm.cur < #gm.tlist then
      r.ImGui_CloseCurrentPopup(ctx)
      guess_fx_modal = nil
      gm.advance(gm.cur + 1)
    end
    r.ImGui_EndPopup(ctx)
  end

  -- Conflict modal: Overwrite / Unique Name / Cancel
  if conflict_modal_pending then
    r.ImGui_OpenPopup(ctx, "##conflictmodal")
  end
  local cm = conflict_modal_pending
  if r.ImGui_BeginPopupModal(ctx, "##conflictmodal", nil,
      r.ImGui_WindowFlags_AlwaysAutoResize()) then
    r.ImGui_Text(ctx, cm and cm.title or "")
    r.ImGui_Separator(ctx)
    r.ImGui_Spacing(ctx)
    r.ImGui_Text(ctx, cm and cm.msg or "")
    r.ImGui_Spacing(ctx)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x3a2a1aFF)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x5a4a2aFF)
    if r.ImGui_Button(ctx, "Overwrite##cmo", 100, 0) then
      if cm then cm.callback("overwrite") end
      conflict_modal_pending = nil
      r.ImGui_CloseCurrentPopup(ctx)
    end
    r.ImGui_PopStyleColor(ctx, 2)
    r.ImGui_SameLine(ctx, 0, 8)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x1a2a3aFF)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x2a4a6aFF)
    if r.ImGui_Button(ctx, "Unique Name##cmu", 110, 0) then
      if cm then cm.callback("unique") end
      conflict_modal_pending = nil
      r.ImGui_CloseCurrentPopup(ctx)
    end
    r.ImGui_PopStyleColor(ctx, 2)
    r.ImGui_SameLine(ctx, 0, 8)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x3a1a1aFF)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x5a2a2aFF)
    if r.ImGui_Button(ctx, "Cancel##cmc", 80, 0) then
      if cm then cm.callback(nil) end
      conflict_modal_pending = nil
      r.ImGui_CloseCurrentPopup(ctx)
    end
    r.ImGui_PopStyleColor(ctx, 2)
    if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape and r.ImGui_Key_Escape() or 256) then
      if cm then cm.callback(nil) end
      conflict_modal_pending = nil
      r.ImGui_CloseCurrentPopup(ctx)
    end
    r.ImGui_EndPopup(ctx)
  end

end


-- ── Main loop ─────────────────────────────────────────────────────────────────

local function init()
  ctx = r.ImGui_CreateContext("ReaOrganize")
  font_large  = r.ImGui_CreateFont("sans-serif", 15)
  font_xlarge = r.ImGui_CreateFont("sans-serif", 26)
  r.ImGui_Attach(ctx, font_large)
  r.ImGui_Attach(ctx, font_xlarge)
  r.ImGui_SetNextWindowSize(ctx, WIN_W, WIN_H, r.ImGui_Cond_FirstUseEver())
  refresh_tracks()
  init_groups()
  load_presets()
end

local function loop()
  r.ImGui_SetNextWindowSize(ctx, WIN_W, WIN_H, r.ImGui_Cond_FirstUseEver())
  local visible, open = r.ImGui_Begin(ctx, "ReaOrganize " .. VERSION, true)
  if visible then
    draw_gui()
    r.ImGui_End(ctx)
  end

  -- ── Unified FX Picker popup (always on top as a popup) ─────────────────────
  -- Open popup whenever picker_state is newly set
  if picker_focus_next then
    r.ImGui_OpenPopup(ctx, "##fxpicker")
    picker_focus_next = false
  end
  r.ImGui_SetNextWindowSize(ctx, 460, 500, r.ImGui_Cond_Always())
  if r.ImGui_BeginPopup(ctx, "##fxpicker") then
    -- Search bar
    if picker_scroll_top then r.ImGui_SetKeyboardFocusHere(ctx) end
    r.ImGui_SetNextItemWidth(ctx, -1)
    local ch, nv = r.ImGui_InputTextWithHint(ctx, "##pkgsearch", "Search...", picker_search_buf,
      r.ImGui_InputTextFlags_AutoSelectAll())
    if ch then
      picker_search_buf = nv
      picker_scroll_top = true
      picker_rebuild_filtered()
    end
    -- Filter checkboxes
    r.ImGui_Spacing(ctx)
    local filter_changed = false
    local function fcheck(label, val)
      local c, v = r.ImGui_Checkbox(ctx, label, val)
      if c then filter_changed = true end
      return c and v or (not c and val)
    end
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xCCCCCCFF)
    picker_show_chains = fcheck("FX Chains", picker_show_chains)
    r.ImGui_SameLine(ctx, 0, 12)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xAADDFFFF)
    picker_show_vst3   = fcheck("VST3",      picker_show_vst3)
    r.ImGui_SameLine(ctx, 0, 12)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xFFDDAAFF)
    picker_show_vst    = fcheck("VST",       picker_show_vst)
    r.ImGui_SameLine(ctx, 0, 12)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xFFFFAAFF)
    picker_show_clap   = fcheck("CLAP",      picker_show_clap)
    r.ImGui_SameLine(ctx, 0, 12)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xAAFFAAFF)
    picker_show_js     = fcheck("JS",        picker_show_js)
    r.ImGui_PopStyleColor(ctx, 5)
    if filter_changed then
      picker_rebuild_filtered()
      picker_scroll_top = true
    end
    r.ImGui_Spacing(ctx)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0x666666FF)
    local total = picker_combined_list and #picker_combined_list or 0
    r.ImGui_Text(ctx, #picker_filtered .. " / " .. total .. " items")
    r.ImGui_PopStyleColor(ctx)
    r.ImGui_Spacing(ctx)
    -- List
    if r.ImGui_BeginChild(ctx, "##pklist", -1, -1, 0) then
      if picker_scroll_top then
        r.ImGui_SetScrollHereY(ctx, 0)
        picker_scroll_top = false
      end
      local picked = nil
      local pick_ctrl  = false
    local pick_shift = false
      for _, p in ipairs(picker_filtered) do
        local col =
          p.kind == "chain" and 0xCCCCCCFF or
          p.kind == "vst3"  and 0xAADDFFFF or
          p.kind == "vst"   and 0xFFDDAAFF or
          p.kind == "clap"  and 0xFFFFAAFF or
          p.kind == "js"    and 0xAAFFAAFF or
          0xCCCCCCFF
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), col)
        local clicked = r.ImGui_Selectable(ctx, p.label .. "##pksel", false)
        r.ImGui_PopStyleColor(ctx)
        if clicked then
          picked = p.name
          pick_ctrl = r.ImGui_IsKeyDown(ctx, r.ImGui_Key_LeftCtrl()) or
                      r.ImGui_IsKeyDown(ctx, r.ImGui_Key_RightCtrl())
          pick_shift = r.ImGui_IsKeyDown(ctx, r.ImGui_Key_LeftShift()) or
                       r.ImGui_IsKeyDown(ctx, r.ImGui_Key_RightShift())
          break
        end
      end
      r.ImGui_EndChild(ctx)
      if picked then
        -- Update picker_state with fresh modifiers from picker-selection time
        if picker_state then
          picker_state.mod_ctrl  = pick_ctrl
          picker_state.mod_shift = pick_shift
        end
        apply_picker_result(picked)
        r.ImGui_CloseCurrentPopup(ctx)
        picker_state = nil
      end
    end
    r.ImGui_EndPopup(ctx)
  else
    -- popup closed externally (click outside) — clear state
    if picker_state and not picker_focus_next then
      picker_state = nil
    end
  end

  if open then
    r.defer(loop)
  else
    save_presets()
    if r.ImGui_DestroyContext then r.ImGui_DestroyContext(ctx) end
  end
end

local function on_exit()
  save_presets()
end

init()
r.atexit(on_exit)
r.defer(loop)
