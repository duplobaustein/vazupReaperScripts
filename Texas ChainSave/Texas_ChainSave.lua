-- @description Texas ChainSave
-- @author duplobaustein
-- @version 1.0
-- @changelog
--   v1.0 - Initial release
-- @provides
--   [main] Texas_ChainSave.lua
-- @links
--   Repository https://github.com/duplobaustein/vazupReaperScripts
--   Issues     https://github.com/duplobaustein/vazupReaperScripts/issues
-- @screenshot https://raw.githubusercontent.com/duplobaustein/vazupReaperScripts/main/screenshots/texas_chainsave.png
-- @about
--   # Texas ChainSave
--
--   A track FX chain manager for REAPER.
--
--   ## Features
--   - Lists all tracks with their insert FX chains in a scrollable table
--   - Checkbox selection with Shift (range), Alt (exclusive) and Ctrl (folder group) modifiers
--   - Save All or Save Selected chains with shared Prefix / Suffix naming
--   - Per Channel mode steps through tracks one by one with individual naming
--   - Conflict resolution: Unique Name, Overwrite or Skip if file already exists
--   -
--   - Parent / folder tracks highlighted with a white border in the track number column
--   - Configurable output folder
--   - Refresh button preserves existing checkbox selections
--
--   ## Requirements
--   - REAPER 6.0 or later
--   - js_ReaScriptAPI (optional, for native folder browse dialog)

------------------------------------------------------------------------------
-- LAYOUT CONSTANTS
------------------------------------------------------------------------------
local WIN_W       = 1060
local WIN_H       = 580
local ROW_H       = 28
local HDR_H       = 26
local PAD         = 8
local COL_NUM_W   = 44      -- col 1: track number
local COL_CHK_W   = 28      -- col 2: checkbox
local COL_NAME_W  = 198     -- col 3: track name
-- col 4+: FX pills (rest of row)
local BOTTOM_H    = 52
local STATUS_H    = 20
local PILL_H      = 17
local PILL_PAD    = 5
local FONT_LARGE  = 14
local FONT_SMALL  = 12
local BTN_H       = 30
local CHK_SZ      = 14      -- checkbox square size

local sep = package.config:sub(1, 1)

------------------------------------------------------------------------------
-- COLORS
------------------------------------------------------------------------------
local C = {
  bg         = {24, 25, 30},
  hdr        = {40, 42, 52},
  hdr_chk    = {35, 37, 48},
  row_even   = {32, 33, 40},
  row_odd    = {38, 39, 47},
  row_sel    = {38, 48, 68},
  text       = {215, 218, 226},
  text_dim   = {120, 122, 138},
  text_dark  = {15, 15, 20},
  border     = {58, 62, 78},
  btn        = {55, 85, 130},
  btn_h      = {72, 108, 160},
  btn_r      = {126, 55, 55},
  btn_rh     = {155, 72, 72},
  btn_g      = {45, 110, 70},
  btn_gh     = {58, 138, 90},
  btn_n      = {58, 62, 78},
  btn_nh     = {78, 84, 104},
  input      = {46, 48, 60},
  input_a    = {54, 57, 74},
  overlay    = {10, 11, 15},
  dlg        = {43, 45, 56},
  dlg_hdr    = {35, 37, 47},
  pill       = {50, 70, 108},
  pill_brd   = {66, 90, 132},
  sb_bg      = {33, 35, 44},
  sb_t       = {68, 84, 116},
  st_bg      = {30, 32, 40},
  ok         = {105, 192, 110},
  err        = {200, 95, 95},
  chk_fill   = {72, 130, 200},
  chk_border = {90, 140, 210},
  chk_empty  = {50, 53, 66},
}

------------------------------------------------------------------------------
-- GFX UTILITIES
------------------------------------------------------------------------------
local function sc(c, a)
  gfx.r, gfx.g, gfx.b = c[1]/255, c[2]/255, c[3]/255
  gfx.a = a and a/255 or 1
end
local function fr(x,y,w,h)  gfx.rect(x,y,w,h,1) end
local function or_(x,y,w,h) gfx.rect(x,y,w,h,0) end

local function isin(x,y,w,h, px,py)
  return px>=x and px<x+w and py>=y and py<y+h
end

local function fnt(idx, name, sz)
  if name then gfx.setfont(idx, name, sz) else gfx.setfont(idx) end
end

local function mstr(s) return gfx.measurestr(s) end

local function drawclip(s, x, y, maxw)
  if mstr(s) <= maxw then gfx.x,gfx.y=x,y; gfx.drawstr(s); return end
  while #s > 0 and mstr(s.."…") > maxw do s = s:sub(1,-2) end
  gfx.x,gfx.y=x,y; gfx.drawstr(s.."…")
end

local function clamp(v,lo,hi) return v<lo and lo or (v>hi and hi or v) end
local function max2(a,b) return a>b and a or b end

------------------------------------------------------------------------------
-- REAPER HELPERS
------------------------------------------------------------------------------
local function default_rfxchain_dir()
  return reaper.GetResourcePath() .. sep .. "FXChains"
end

local function track_color_rgb(col)
  if col == 0 then return 82, 85, 102 end
  local r, g, b = reaper.ColorFromNative(col)
  return r, g, b
end

local function luminance(r,g,b)
  return r*0.299 + g*0.587 + b*0.114
end

local function strip_fx_prefix(name)
  return name
    :gsub("^VST3?:%s*", "")
    :gsub("^AU:%s*",    "")
    :gsub("^JS:%s*",    "")
    :gsub("^CLAP:%s*",  "")
end

local function sanitize_filename(s)
  return s:gsub('[/\\:*?"<>|]', "_"):match("^%s*(.-)%s*$")
end

local function collect_tracks()
  local list = {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local _, nm = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    local col  = reaper.GetTrackColor(tr)
    local fxs  = {}
    for j = 0, reaper.TrackFX_GetCount(tr) - 1 do
      local ok, fn = reaper.TrackFX_GetFXName(tr, j, "")
      if ok then fxs[#fxs+1] = strip_fx_prefix(fn) end
    end
    local fd = reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH")
    list[#list+1] = {
      tr        = tr,
      idx       = i + 1,
      name      = nm ~= "" and nm or ("Track "..(i+1)),
      col       = col,
      fxs       = fxs,
      selected  = false,     -- unchecked by default
      is_parent = (fd == 1), -- folder parent track
      fd        = fd,        -- raw folder depth value
      parent_i  = nil,       -- filled in below
    }
  end
  -- Compute parent_i for each track via folder-depth stack
  do
    local stack = {} -- stack of list-indices that are open folder parents
    for i, t in ipairs(list) do
      t.parent_i = stack[#stack] -- nil when top-level
      if t.fd == 1 then
        stack[#stack+1] = i
      elseif t.fd < 0 then
        for _ = 1, math.abs(t.fd) do
          if #stack > 0 then stack[#stack] = nil end
        end
      end
    end
  end
  return list
end

local function extract_fxchain(chunk)
  local out, in_chain, depth = {}, false, 0
  for ln in (chunk.."\n"):gmatch("([^\n]*)\n") do
    local t = ln:match("^%s*(.-)%s*$")
    if not in_chain then
      if t:match("^<FXCHAIN") then
        in_chain = true; depth = 1
        out[#out+1] = "<REAPER_FX_CHAIN"
      end
    else
      if t:match("^<") then
        depth = depth + 1; out[#out+1] = ln
      elseif t == ">" then
        depth = depth - 1
        if depth == 0 then out[#out+1] = ">"; break
        else out[#out+1] = ln end
      else
        out[#out+1] = ln
      end
    end
  end
  if #out < 2 then return nil end
  return table.concat(out, "\n")
end

local function save_fx_chain(tr, path)
  if not path:lower():match("%.rfxchain$") then path = path..".RfxChain" end
  local ok, chunk = reaper.GetTrackStateChunk(tr, "", false)
  if not ok then return false, "Cannot read track state" end
  local chain = extract_fxchain(chunk)
  if not chain then return false, "Track has no FX chain" end
  local f, err = io.open(path, "w")
  if not f then return false, "Cannot write: "..(err or path) end
  f:write(chain); f:close()
  return true
end

local function count_selected(tracks)
  local n = 0
  for _, t in ipairs(tracks) do if t.selected then n = n+1 end end
  return n
end

------------------------------------------------------------------------------
-- APPLICATION STATE
------------------------------------------------------------------------------
local S = {
  tracks   = {},
  folder   = default_rfxchain_dir(),
  scroll   = 0,
  mode     = "main",

  -- Save All / Save Selected dialog (shared)
  sa_pre   = "",
  sa_suf   = "",
  sa_foc   = "prefix",
  sa_sel   = false,       -- true = only selected tracks

  -- Per Channel / Per Channel Selected
  pc_i     = 1,
  pc_name  = "",
  pc_pre   = "",          -- remembered per-channel prefix
  pc_suf   = "",          -- remembered per-channel suffix
  pc_foc   = "name",      -- focused field: "name"|"prefix"|"suffix"
  pc_list  = nil,         -- subset list when doing "selected" variant

  -- Folder field
  fol_foc  = false,

  -- Mouse
  mx = 0, my = 0, pclick = false,

  -- Cursor blink
  blink = 0, cur = true,

  -- Status
  status = "", stimer = 0, st_ok = true,

  -- Header checkbox state
  hdr_chk   = false,
  last_chk_i = nil,  -- for Shift+click range deselect

  -- Conflict resolution policy (shared by all save dialogs)
  -- values: "unique" | "overwrite" | "skip_file"
  conflict = "unique",

  -- Batch-save cursor (one track saved per defer tick)
  sa_saving     = false,  -- true while batch is running
  batch_list    = nil,    -- full list of tracks to save
  batch_pre     = "",     -- prefix string for current batch
  batch_suf     = "",     -- suffix string for current batch
  batch_idx     = 0,      -- next track index to process
  batch_saved   = 0,      -- running tally
  batch_skipped = 0,
  batch_current = "",     -- display label for the track being saved now
}

local function set_status(msg, ok, dur)
  S.status = msg; S.st_ok = ok ~= false; S.stimer = dur or 220
end

------------------------------------------------------------------------------
-- CHECKBOX DRAW
------------------------------------------------------------------------------
local function draw_checkbox(cx, cy, checked, hovered)
  local x = cx - CHK_SZ/2
  local y = cy - CHK_SZ/2
  sc(checked and C.chk_fill or C.chk_empty); fr(x,y,CHK_SZ,CHK_SZ)
  sc(checked and C.chk_border or C.border);  or_(x,y,CHK_SZ,CHK_SZ)
  if checked then
    -- Simple checkmark: two line segments via rect approximation
    gfx.r,gfx.g,gfx.b,gfx.a = 1,1,1,1
    -- Short left leg
    for i=0,3 do
      gfx.x = x+2+i; gfx.y = y+6+i
      gfx.lineto(x+3+i, y+7+i, 1)
    end
    -- Long right leg
    for i=0,5 do
      gfx.x = x+5+i; gfx.y = y+9-i
      gfx.lineto(x+6+i, y+8-i, 1)
    end
  end
end

------------------------------------------------------------------------------
-- BUTTON DRAW
------------------------------------------------------------------------------
local function draw_button(x, y, w, h, label, style)
  -- style: nil=blue  "red"=red  "green"=green  "neutral"=grey
  local hov = isin(x,y,w,h, S.mx, S.my)
  local c
  if style == "red"     then c = hov and C.btn_rh or C.btn_r
  elseif style == "green"  then c = hov and C.btn_gh or C.btn_g
  elseif style == "neutral" then c = hov and C.btn_nh or C.btn_n
  else                       c = hov and C.btn_h  or C.btn
  end
  sc(c); fr(x,y,w,h)
  sc(C.border); or_(x,y,w,h)
  sc(C.text); fnt(1,"Arial",FONT_LARGE)
  local tw = mstr(label)
  local _, th = gfx.measurestr(label)
  gfx.x = x+(w-tw)/2; gfx.y = y+(h-th)/2
  gfx.drawstr(label)
  return hov
end

local function draw_input(x, y, w, h, text, focused)
  sc(focused and C.input_a or C.input); fr(x,y,w,h)
  sc(C.border); or_(x,y,w,h)
  sc(C.text); fnt(1,"Arial",FONT_LARGE)
  local cur_str = focused and (S.cur and "|" or " ") or ""
  local disp = text..cur_str
  if mstr(disp) > w-8 then
    while #disp>0 and mstr(disp)>w-8 do disp=disp:sub(2) end
  end
  gfx.x = x+4; gfx.y = y+(h-FONT_LARGE)/2
  gfx.drawstr(disp)
end


------------------------------------------------------------------------------
-- RADIO BUTTON  (mutually exclusive within a group)
------------------------------------------------------------------------------
local RAD_R = 6  -- outer radius
local function draw_radio(cx, cy, checked, hovered)
  -- outer circle (approx with rects)
  local x, y = cx-RAD_R, cy-RAD_R
  local d     = RAD_R*2
  sc(checked and C.chk_fill or C.chk_empty)
  -- filled square then carve corners to fake circle
  fr(x+1,y,  d-2,d); fr(x,y+1,  d,d-2)
  sc(checked and C.chk_border or C.border)
  or_(x+1,y,  d-2,d); or_(x,y+1, d,d-2)
  if checked then
    -- filled dot
    gfx.r,gfx.g,gfx.b,gfx.a = 1,1,1,0.92
    local ir = RAD_R-3
    fr(cx-ir+1, cy-ir, ir*2-2, ir*2)
    fr(cx-ir,   cy-ir+1, ir*2, ir*2-2)
  end
end

-- Draw the three conflict-mode radio buttons inline.
-- Returns a table of hit-areas: {unique, overwrite, skip_file}
local function draw_conflict_radios(x, y, current)
  local opts = {
    {id="unique",    label="Unique Name"},
    {id="overwrite", label="Overwrite"},
    {id="skip_file", label="Skip"},
  }
  local hits = {}
  local cx = x
  fnt(2,"Arial",FONT_SMALL)
  for _, o in ipairs(opts) do
    local checked = (current == o.id)
    local lw = gfx.measurestr(o.label)
    local hw = RAD_R*2 + 5 + lw + 14
    local hov = isin(cx, y-RAD_R-2, hw, RAD_R*2+8, S.mx, S.my)
    draw_radio(cx+RAD_R, y, checked, hov)
    sc(C.text)
    gfx.x = cx+RAD_R*2+5; gfx.y = y-FONT_SMALL/2
    gfx.drawstr(o.label)
    hits[o.id] = {x=cx, y=y-RAD_R-2, w=hw, h=RAD_R*2+8}
    cx = cx + hw
  end
  return hits
end

local function file_exists(path)
  if not path:lower():match("%.rfxchain$") then path = path..".RfxChain" end
  local fh = io.open(path, "r")
  if fh then fh:close(); return true end
  return false
end

-- Returns a unique path by appending (2),(3),... if file already exists.
local function make_unique_path(base_path)
  if not base_path:lower():match("%.rfxchain$") then
    base_path = base_path..".RfxChain"
  end
  if not file_exists(base_path) then return base_path end
  local stem = base_path:match("^(.-)%.RfxChain$") or base_path:match("^(.-)%.rfxchain$")
  local n = 2
  while true do
    local candidate = stem.." ("..n..").RfxChain"
    if not file_exists(candidate) then return candidate end
    n = n + 1
    if n > 999 then return stem.." (999).RfxChain" end  -- safety
  end
end
------------------------------------------------------------------------------
-- MAIN DRAW
------------------------------------------------------------------------------
local function draw()
  local W, H = gfx.w, gfx.h
  local ui   = {}

  sc(C.bg); fr(0,0,W,H)

  -- ── Column X positions ──────────────────────────────────────────────────
  local lx        = PAD
  local ly        = PAD
  local lw        = W - PAD*2
  local lh        = H - PAD - BOTTOM_H - STATUS_H - PAD - ly

  local rows_h    = lh - HDR_H
  local total_h   = #S.tracks * ROW_H
  local max_scr   = max2(0, total_h - rows_h)
  local needs_sb  = max_scr > 0
  local sb_w      = needs_sb and 10 or 0
  S.scroll        = clamp(S.scroll, 0, max_scr)
  local row_w     = lw - sb_w

  local x_num  = lx
  local x_chk  = lx + COL_NUM_W
  local x_name = lx + COL_NUM_W + COL_CHK_W
  local x_fx   = lx + COL_NUM_W + COL_CHK_W + COL_NAME_W

  -- ── Header ───────────────────────────────────────────────────────────────
  sc(C.hdr); fr(lx, ly, lw, HDR_H)
  -- Dividers
  sc(C.border)
  fr(x_chk,  ly, 1, HDR_H)
  fr(x_name, ly, 1, HDR_H)
  fr(x_fx,   ly, 1, HDR_H)

  -- Col labels
  fnt(2,"Arial",FONT_SMALL); sc(C.text_dim)
  do
    local hw = mstr("#")
    gfx.x = lx + (COL_NUM_W - hw) / 2
    gfx.y = ly + 6
    gfx.drawstr("#")
  end
  gfx.x=x_name+6; gfx.y=ly+6; gfx.drawstr("TRACK NAME")
  gfx.x=x_fx+6;   gfx.y=ly+6; gfx.drawstr("INSERT FX")

  -- Col 2 header: select-all checkbox
  local hdr_chk_cx = x_chk + COL_CHK_W/2
  local hdr_chk_cy = ly + HDR_H/2
  draw_checkbox(hdr_chk_cx, hdr_chk_cy, S.hdr_chk,
    isin(x_chk, ly, COL_CHK_W, HDR_H, S.mx, S.my))
  ui.hdr_chk = {x=x_chk, y=ly, w=COL_CHK_W, h=HDR_H}

  -- ── Rows ────────────────────────────────────────────────────────────────
  local rows_y = ly + HDR_H
  ui.row_chk_hits = {}

  for i, t in ipairs(S.tracks) do
    local ry = rows_y + (i-1)*ROW_H - S.scroll
    if ry+ROW_H <= rows_y        then goto cont end
    if ry       >= rows_y+rows_h then break end

    -- Row bg (tinted if selected)
    if t.selected then sc(C.row_sel)
    else sc(i%2==0 and C.row_even or C.row_odd) end
    fr(lx, ry, row_w, ROW_H)

    -- Track # cell with track color
    local r,g,b = track_color_rgb(t.col)
    gfx.r,gfx.g,gfx.b,gfx.a = r/255,g/255,b/255,1
    fr(x_num, ry, COL_NUM_W, ROW_H)
    if luminance(r,g,b)>130 then sc(C.text_dark) else sc(C.text) end
    fnt(2,"Arial",FONT_SMALL)
    local ns = tostring(t.idx)
    local nw = mstr(ns); local _,nh = gfx.measurestr(ns)
    gfx.x = x_num+(COL_NUM_W-nw)/2; gfx.y = ry+(ROW_H-nh)/2
    gfx.drawstr(ns)
    -- White border (2px thick), flush on all sides
    if t.is_parent then
      gfx.r,gfx.g,gfx.b,gfx.a = 1,1,1,0.80
      or_(x_num,   ry,   COL_NUM_W,   ROW_H-1)  -- outer
      or_(x_num+1, ry+1, COL_NUM_W-2, ROW_H-3)  -- inner
    end

    -- Checkbox cell
    local chk_cx = x_chk + COL_CHK_W/2
    local chk_cy = ry + ROW_H/2
    local chk_hov = isin(x_chk, ry, COL_CHK_W, ROW_H, S.mx, S.my)
    draw_checkbox(chk_cx, chk_cy, t.selected, chk_hov)
    ui.row_chk_hits[#ui.row_chk_hits+1] = {idx=i, x=x_chk, y=ry, w=COL_CHK_W, h=ROW_H}

    -- Dividers
    sc(C.border)
    fr(x_chk,  ry, 1, ROW_H)
    fr(x_name, ry, 1, ROW_H)
    fr(x_fx,   ry, 1, ROW_H)

    -- Track name
    sc(C.text); fnt(1,"Arial",FONT_LARGE)
    drawclip(t.name, x_name+6, ry+(ROW_H-FONT_LARGE)/2, COL_NAME_W-12)

    -- FX pills
    fnt(2,"Arial",FONT_SMALL)
    if #t.fxs == 0 then
      sc(C.text_dim)
      gfx.x=x_fx+6; gfx.y=ry+(ROW_H-FONT_SMALL)/2; gfx.drawstr("—")
    else
      local px  = x_fx + 4
      local py  = ry + (ROW_H-PILL_H)/2
      local ex  = lx + row_w - 4
      for _, fn in ipairs(t.fxs) do
        local fw = mstr(fn)+PILL_PAD*2
        if px+fw+mstr("…")+4 > ex then
          sc(C.text_dim); gfx.x=px; gfx.y=py+(PILL_H-FONT_SMALL)/2
          gfx.drawstr("…"); break
        end
        sc(C.pill);     fr(px,py,fw,PILL_H)
        sc(C.pill_brd); or_(px,py,fw,PILL_H)
        sc(C.text)
        gfx.x=px+PILL_PAD; gfx.y=py+(PILL_H-FONT_SMALL)/2
        gfx.drawstr(fn)
        px = px+fw+4
      end
    end
    -- Row grid line
    sc(C.border)
    fr(lx, ry+ROW_H-1, row_w, 1)
    ::cont::
  end

  -- ── Redraw pinned header on top of any overflowing row content ────────
  sc(C.hdr); fr(lx, ly, lw, HDR_H)
  sc(C.border)
  fr(x_chk,  ly, 1, HDR_H)
  fr(x_name, ly, 1, HDR_H)
  fr(x_fx,   ly, 1, HDR_H)
  fnt(2,'Arial',FONT_SMALL); sc(C.text_dim)
  do
    local hw = mstr('#')
    gfx.x = lx + (COL_NUM_W - hw) / 2; gfx.y = ly + 6; gfx.drawstr('#')
  end
  gfx.x=x_name+6; gfx.y=ly+6; gfx.drawstr('TRACK NAME')
  gfx.x=x_fx+6;   gfx.y=ly+6; gfx.drawstr('INSERT FX')
  -- Re-draw select-all checkbox on top
  draw_checkbox(x_chk + COL_CHK_W/2, ly + HDR_H/2, S.hdr_chk,
    isin(x_chk, ly, COL_CHK_W, HDR_H, S.mx, S.my))

  -- Draw list border: top + sides only (no bottom line to avoid phantom row)
  sc(C.border)
  fr(lx,        ly,      lw, 1)   -- top
  fr(lx,        ly,      1,  lh)  -- left
  fr(lx+lw-1,   ly,      1,  lh)  -- right

  -- Scrollbar
  if needs_sb then
    local sbx = lx+lw-sb_w
    sc(C.sb_bg); fr(sbx, rows_y, sb_w, rows_h)
    local th = max2(18, rows_h*rows_h/total_h)
    local ty = rows_y+(S.scroll/max_scr)*(rows_h-th)
    sc(C.sb_t); fr(sbx+2, ty, sb_w-4, th)
  end

  ui.scroll_max = max_scr
  ui.rows_y     = rows_y
  ui.rows_h     = rows_h

  -- ── BOTTOM BAR ───────────────────────────────────────────────────────────
  -- Layout:
  --  [Save All] [Save Selected]  |  [Per Channel] [Per Ch. Selected]  |  [Refresh]  ||  Save to: [...path...] [Browse]

  local bar_y  = ly + lh + PAD
  local btn_y  = bar_y + (BOTTOM_H - BTN_H)/2

  local bx = lx
  local BW = 96   -- base button width

  -- Group 1: Save buttons
  draw_button(bx,       btn_y, BW,    BTN_H, "Save All")
  draw_button(bx+BW+4,  btn_y, BW+20, BTN_H, "Selected", "green")
  ui.sa      = {x=bx,       y=btn_y, w=BW,    h=BTN_H}
  ui.sa_sel  = {x=bx+BW+4,  y=btn_y, w=BW+20, h=BTN_H}

  -- Separator
  local sep1x = bx+BW+4+BW+20+10
  sc(C.border); fr(sep1x, bar_y+6, 1, BOTTOM_H-12)

  -- Group 2: Per Channel buttons
  local g2x = sep1x + 10
  draw_button(g2x,        btn_y, BW+4,  BTN_H, "Per Channel")
  draw_button(g2x+BW+8,   btn_y, BW+30, BTN_H, "Selected", "green")
  ui.pc      = {x=g2x,       y=btn_y, w=BW+4,  h=BTN_H}
  ui.pc_sel  = {x=g2x+BW+8,  y=btn_y, w=BW+30, h=BTN_H}

  -- Separator
  local sep2x = g2x+BW+8+BW+30+10
  sc(C.border); fr(sep2x, bar_y+6, 1, BOTTOM_H-12)

  -- Refresh button
  local rfx = sep2x + 10
  draw_button(rfx, btn_y, 76, BTN_H, "⟳ Refresh", "neutral")
  ui.refresh = {x=rfx, y=btn_y, w=76, h=BTN_H}

  -- Separator before folder
  local sep3x = rfx + 76 + 10
  sc(C.border); fr(sep3x, bar_y+6, 1, BOTTOM_H-12)

  -- Folder input
  fnt(2,"Arial",FONT_SMALL); sc(C.text_dim)
  local flbl   = "Save to:"
  local flbl_w = mstr(flbl)
  local fi_start = sep3x + 10
  gfx.x=fi_start; gfx.y=btn_y+(BTN_H-FONT_SMALL)/2
  gfx.drawstr(flbl)

  local fi_x = fi_start + flbl_w + 6
  local br_w = 72
  local fi_w = W - PAD - fi_x - br_w - 8
  draw_input(fi_x, btn_y, fi_w, BTN_H, S.folder, S.fol_foc)
  ui.fol = {x=fi_x, y=btn_y, w=fi_w, h=BTN_H}

  local br_x = fi_x + fi_w + 6
  draw_button(br_x, btn_y, br_w, BTN_H, "Browse…")
  ui.browse = {x=br_x, y=btn_y, w=br_w, h=BTN_H}

  -- ── STATUS BAR ───────────────────────────────────────────────────────────
  local st_y = bar_y + BOTTOM_H
  sc(C.st_bg); fr(lx, st_y, lw, STATUS_H)
  sc(C.border); or_(lx, st_y, lw, STATUS_H)
  fnt(2,"Arial",FONT_SMALL)
  if S.stimer > 0 then
    sc(S.st_ok and C.ok or C.err)
    gfx.x=lx+6; gfx.y=st_y+4; gfx.drawstr(S.status)
  else
    sc(C.text_dim)
    local sel_n = count_selected(S.tracks)
    gfx.x=lx+6; gfx.y=st_y+4
    gfx.drawstr(string.format(
      "%d track(s)  |  %d selected  |  Ctrl: all descendants  Alt: solo  Shift: range  |  Ctrl+R: rescan  |  Wheel: scroll",
      #S.tracks, sel_n))
  end

  -- ── DIALOGS ──────────────────────────────────────────────────────────────
  local dlg = {}

  if S.mode == "save_all" then
    sc(C.overlay, 200); fr(0,0,W,H)
    local dw, dh = 460, 282
    local dx=(W-dw)/2; local dy=(H-dh)/2
    sc(C.dlg);    fr(dx,dy,dw,dh)
    sc(C.dlg_hdr);fr(dx,dy,dw,32)
    sc(C.border); or_(dx,dy,dw,dh)

    sc(C.text); fnt(1,"Arial",FONT_LARGE)
    local title = S.sa_sel and "Save Selected FX Chains" or "Save All FX Chains"
    gfx.x=dx+12; gfx.y=dy+9; gfx.drawstr(title)

    fnt(1,"Arial",FONT_LARGE-1); sc(C.text)
    local pfw = dw - 104 - 14
    gfx.x=dx+14; gfx.y=dy+52; gfx.drawstr("Prefix:")
    draw_input(dx+90, dy+47, pfw, 26, S.sa_pre, S.sa_foc=="prefix")
    dlg.pre = {x=dx+90, y=dy+47, w=pfw, h=26}

    gfx.x=dx+14; gfx.y=dy+96; gfx.drawstr("Suffix:")
    draw_input(dx+90, dy+91, pfw, 26, S.sa_suf, S.sa_foc=="suffix")
    dlg.suf = {x=dx+90, y=dy+91, w=pfw, h=26}

    -- Preview / live saving progress
    local pre_p = S.sa_pre~="" and (S.sa_pre.." ") or ""
    local suf_p = S.sa_suf~="" and (" "..S.sa_suf) or ""
    if S.batch_current ~= "" then
      -- Highlight box behind the saving line
      sc({30, 70, 40}); fr(dx+10, dy+120, dw-20, 22)
      sc(C.ok); fnt(1,"Arial",FONT_LARGE)
      drawclip("  ↳ "..S.batch_current, dx+14, dy+123, dw-28)
    else
      fnt(2,"Arial",FONT_SMALL); sc(C.text_dim)
      drawclip("Preview: "..pre_p.."Track Name"..suf_p..".RfxChain", dx+14, dy+128, dw-28)
    end

    -- Conflict separator + radios
    sc(C.border); fr(dx+14, dy+148, dw-28, 1)
    fnt(2,"Arial",FONT_SMALL); sc(C.text_dim)
    gfx.x=dx+14; gfx.y=dy+155; gfx.drawstr("If file exists:")
    dlg.conflict_hits = draw_conflict_radios(dx+116, dy+162, S.conflict)

    -- Saving banner above buttons
    if S.sa_saving then
      local bb_y = dy+dh-56
      sc({30, 70, 40}); fr(dx+10, bb_y-30, dw-20, 24)
      sc(C.ok); fnt(1,"Arial",FONT_LARGE)
      local sw = gfx.measurestr("Saving, please wait...")
      gfx.x = dx+(dw-sw)/2; gfx.y = bb_y-26
      gfx.drawstr("Saving, please wait...")
    end
    fnt(1,"Arial",FONT_LARGE)
    local bb_y = dy+dh-56
    draw_button(dx+dw-226, bb_y, 106, 38, "Save")
    draw_button(dx+dw-112, bb_y, 100, 38, "Cancel")
    dlg.save   = {x=dx+dw-226, y=bb_y, w=106, h=38}
    dlg.cancel = {x=dx+dw-112, y=bb_y, w=100, h=38}
    dlg.type   = "save_all"

    fnt(2,"Arial",FONT_SMALL); sc(C.text_dim)
    gfx.x=dx+14; gfx.y=dy+dh-16
    gfx.drawstr("Tab: switch fields  |  Enter: save  |  Esc: cancel")

  elseif S.mode == "per_ch" then
    local list = S.pc_list
    if not list or S.pc_i > #list then
      S.mode = "main"
    else
      local t = list[S.pc_i]
      sc(C.overlay, 200); fr(0,0,W,H)
      local dw, dh = 490, 324
      local dx=(W-dw)/2; local dy=(H-dh)/2
      sc(C.dlg);    fr(dx,dy,dw,dh)
      sc(C.dlg_hdr);fr(dx,dy,dw,32)
      sc(C.border); or_(dx,dy,dw,dh)

      -- Title
      sc(C.text); fnt(1,"Arial",FONT_LARGE)
      local ttl = string.format("[%d / %d]  %s", S.pc_i, #list, t.name)
      drawclip(ttl, dx+12, dy+9, dw-24)

      -- FX list
      fnt(2,"Arial",FONT_SMALL); sc(C.text_dim)
      local fx_str = #t.fxs>0 and table.concat(t.fxs,"  ·  ") or "(no FX on this track)"
      drawclip(fx_str, dx+14, dy+40, dw-28)

      -- Fields: Prefix / Name / Suffix
      local fw = dw - 90 - 14
      fnt(1,"Arial",FONT_LARGE-1); sc(C.text)
      gfx.x=dx+14; gfx.y=dy+66;  gfx.drawstr("Prefix:")
      draw_input(dx+86, dy+61,  fw, 26, S.pc_pre,  S.pc_foc=="prefix")
      dlg.pc_pre = {x=dx+86, y=dy+61,  w=fw, h=26}

      gfx.x=dx+14; gfx.y=dy+104; gfx.drawstr("Name:")
      draw_input(dx+86, dy+99,  fw, 26, S.pc_name, S.pc_foc=="name")
      dlg.pc_name = {x=dx+86, y=dy+99,  w=fw, h=26}

      gfx.x=dx+14; gfx.y=dy+142; gfx.drawstr("Suffix:")
      draw_input(dx+86, dy+137, fw, 26, S.pc_suf,  S.pc_foc=="suffix")
      dlg.pc_suf = {x=dx+86, y=dy+137, w=fw, h=26}

      -- Preview
      fnt(2,"Arial",FONT_SMALL); sc(C.text_dim)
      local pre_p = S.pc_pre~="" and (S.pc_pre.." ") or ""
      local suf_p = S.pc_suf~="" and (" "..S.pc_suf) or ""
      local nm_p  = S.pc_name~="" and S.pc_name or t.name
      drawclip("Preview: "..pre_p..nm_p..suf_p..".RfxChain", dx+14, dy+174, dw-28)

      -- Conflict separator + radios
      sc(C.border); fr(dx+14, dy+194, dw-28, 1)
      fnt(2,"Arial",FONT_SMALL); sc(C.text_dim)
      gfx.x=dx+14; gfx.y=dy+201; gfx.drawstr("If file exists:")
      dlg.conflict_hits = draw_conflict_radios(dx+116, dy+208, S.conflict)

      -- Buttons
      fnt(1,"Arial",FONT_LARGE)
      local bw3=96; local gap=10
      local tot=bw3*3+gap*2
      local bs=dx+(dw-tot)/2
      local bb_y=dy+dh-54

      draw_button(bs,             bb_y, bw3, 40, "Save")
      draw_button(bs+bw3+gap,     bb_y, bw3, 40, "Skip")
      draw_button(bs+(bw3+gap)*2, bb_y, bw3, 40, "Cancel", "red")

      dlg.save   = {x=bs,              y=bb_y, w=bw3, h=40}
      dlg.skip   = {x=bs+bw3+gap,      y=bb_y, w=bw3, h=40}
      dlg.cancel = {x=bs+(bw3+gap)*2,  y=bb_y, w=bw3, h=40}
      dlg.type   = "per_ch"

      fnt(2,"Arial",FONT_SMALL); sc(C.text_dim)
      gfx.x=dx+14; gfx.y=dy+dh-14
      gfx.drawstr("Tab: switch fields  |  Enter: save  |  Esc: cancel")
    end
  end

  ui.dlg = dlg
  return ui
end

------------------------------------------------------------------------------
-- OPERATIONS
------------------------------------------------------------------------------
-- Start a batch: store state, set flag. One track saved per defer tick.
local function batch_start(track_list, pre_str, suf_str)
  S.sa_saving     = true
  S.batch_list    = track_list
  S.batch_pre     = pre_str
  S.batch_suf     = suf_str
  S.batch_idx     = 1
  S.batch_saved   = 0
  S.batch_skipped = 0
  S.batch_current = ""
end

-- Called once per defer tick while sa_saving is true.
-- Saves exactly one track then returns so the UI can repaint.
local function batch_tick()
  local list = S.batch_list
  local pre  = S.batch_pre~="" and (S.batch_pre.." ") or ""
  local suf  = S.batch_suf~="" and (" "..S.batch_suf) or ""

  -- Advance past tracks with no FX
  while S.batch_idx <= #list and #list[S.batch_idx].fxs == 0 do
    S.batch_skipped = S.batch_skipped + 1
    S.batch_idx     = S.batch_idx + 1
  end

  if S.batch_idx > #list then
    -- All done
    S.sa_saving     = false
    S.batch_current = ""
    S.mode          = "main"
    set_status(string.format("Saved %d chain(s). Skipped %d.",
      S.batch_saved, S.batch_skipped))
    return
  end

  local t     = list[S.batch_idx]
  local fname = sanitize_filename(pre..t.name..suf)
  local base  = S.folder..sep..fname
  local path

  if file_exists(base) then
    if S.conflict == "unique" then
      path = make_unique_path(base)
    elseif S.conflict == "overwrite" then
      path = base
    else  -- skip_file
      S.batch_skipped = S.batch_skipped + 1
      S.batch_idx     = S.batch_idx + 1
      return
    end
  else
    path = base
  end

  -- Update display label
  local disp = path:match("([^/\\]+)$") or fname
  if not disp:lower():match("%.rfxchain$") then disp = disp..".RfxChain" end
  S.batch_current = string.format("[%d/%d]  %s",
    S.batch_idx, #list, disp)

  local ok, err = save_fx_chain(t.tr, path)
  if ok then S.batch_saved   = S.batch_saved   + 1
  else
    S.batch_skipped = S.batch_skipped + 1
    reaper.ShowConsoleMsg("[Texas ChainSave] '"..t.name.."': "..(err or "").."\n")
  end
  S.batch_idx = S.batch_idx + 1
end

local function op_pc_save()
  local list = S.pc_list
  local t = list and list[S.pc_i]
  if not t then return end
  local pre   = S.pc_pre~="" and (S.pc_pre.." ") or ""
  local suf   = S.pc_suf~="" and (" "..S.pc_suf) or ""
  local name  = S.pc_name~="" and S.pc_name or t.name
  local fname = sanitize_filename(pre..name..suf)
  local base  = S.folder..sep..fname
  local path
  if file_exists(base) then
    if S.conflict == "unique" then
      path = make_unique_path(base)
    elseif S.conflict == "overwrite" then
      path = base
    else  -- skip_file: advance without saving
      set_status("Skipped (file exists): "..fname..".RfxChain")
      S.pc_i = S.pc_i+1
      if S.pc_i <= #list then S.pc_name = list[S.pc_i].name
      else S.mode = "main"; set_status("Per-channel save complete.") end
      return
    end
  else
    path = base
  end
  local real_fname = path:match("([^/\\]+)%.RfxChain$") or fname
  local ok, err = save_fx_chain(t.tr, path)
  if ok then set_status("Saved: "..real_fname..".RfxChain")
  else
    set_status("Error: "..(err or "?"), false)
    reaper.ShowConsoleMsg("[Texas ChainSave] '"..t.name.."': "..(err or "").."\n")
  end
  S.pc_i = S.pc_i+1
  if S.pc_i <= #list then
    S.pc_name = list[S.pc_i].name  -- reset name; prefix/suffix kept
  else
    S.mode = "main"
    set_status("Per-channel save complete.")
  end
end

local function op_pc_skip()
  local list = S.pc_list
  S.pc_i = S.pc_i+1
  if list and S.pc_i <= #list then
    S.pc_name = list[S.pc_i].name
  else
    S.mode = "main"
    set_status("Per-channel save complete.")
  end
end

local function op_refresh()
  -- Preserve selection state by track name
  local prev = {}
  for _, t in ipairs(S.tracks) do prev[t.name] = t.selected end
  S.tracks = collect_tracks()
  for _, t in ipairs(S.tracks) do
    -- restore prior state; new tracks default to unchecked (false)
    if prev[t.name] ~= nil then t.selected = prev[t.name] end
  end
  S.scroll = 0
  S.last_chk_i = nil
  -- Update hdr_chk to reflect majority state
  local sel = count_selected(S.tracks)
  S.hdr_chk = sel == #S.tracks
  set_status(string.format("Refreshed — %d track(s) found.", #S.tracks))
end

local function start_per_channel(selected_only)
  local list = {}
  for _, t in ipairs(S.tracks) do
    local include = (not selected_only or t.selected)
                 and (#t.fxs > 0)        -- skip tracks with no FX (parents included if they have FX)
    if include then list[#list+1] = t end
  end
  if #list == 0 then
    set_status(selected_only and "No selected tracks with FX." or "No tracks with FX.", false); return
  end
  S.pc_list = list
  S.pc_i    = 1
  S.pc_name = list[1].name  -- pre/suf retained from last session
  S.pc_foc  = "name"
  S.mode    = "per_ch"
end

------------------------------------------------------------------------------
-- KEYBOARD
------------------------------------------------------------------------------
local function handle_key(char)
  local field = nil
  if S.mode == "main" and S.fol_foc then
    field = "folder"
  elseif S.mode == "save_all" then
    field = S.sa_foc=="prefix" and "sa_pre" or "sa_suf"
  elseif S.mode == "per_ch" then
    if S.pc_foc == "prefix" then field = "pc_pre"
    elseif S.pc_foc == "suffix" then field = "pc_suf"
    else field = "pc_name" end
  end

  if char == 8 then     -- Backspace
    if field then S[field] = S[field]:sub(1,-2) end

  elseif char == 9 then   -- Tab
    if S.mode == "save_all" then
      S.sa_foc = S.sa_foc=="prefix" and "suffix" or "prefix"
    elseif S.mode == "per_ch" then
      if S.pc_foc == "prefix" then S.pc_foc = "name"
      elseif S.pc_foc == "name" then S.pc_foc = "suffix"
      else S.pc_foc = "prefix" end
    end

  elseif char == 13 then  -- Enter
    if S.mode == "save_all" then
      if S.sa_foc == "prefix" then S.sa_foc = "suffix"
      else
        local list = {}
        for _, t in ipairs(S.tracks) do
          if not S.sa_sel or t.selected then list[#list+1] = t end
        end
        batch_start(list, S.sa_pre, S.sa_suf)
      end
    elseif S.mode == "per_ch" then
      if S.pc_foc == "prefix" then S.pc_foc = "name"
      elseif S.pc_foc == "name" then S.pc_foc = "suffix"
      else op_pc_save() end
    end

  elseif char == 27 then  -- Esc
    if S.mode ~= "main" then S.mode = "main"
    else S.fol_foc = false end

  elseif char == 18 then  -- Ctrl+R
    op_refresh()

  elseif char >= 32 and char < 127 then
    if field then S[field] = S[field]..string.char(char) end
  end
end

------------------------------------------------------------------------------
-- MAIN LOOP
------------------------------------------------------------------------------
local ui_cache = {}

local function loop()
  local char = gfx.getchar()
  if char == -1 then return end

  S.mx = gfx.mouse_x; S.my = gfx.mouse_y
  local btn_down   = gfx.mouse_cap & 1 == 1
  local just_click = btn_down and not S.pclick
  S.pclick         = btn_down

  S.blink = S.blink+1
  if S.blink >= 20 then S.blink=0; S.cur=not S.cur end

  local wheel = gfx.mouse_wheel
  if wheel ~= 0 then
    S.scroll = S.scroll - wheel/120 * ROW_H * 3
    gfx.mouse_wheel = 0
  end

  if char > 0 then handle_key(char) end
  if S.stimer > 0 then S.stimer = S.stimer-1 end

  ui_cache = draw()

  -- Advance batch by one track per frame (UI stays live between each save)
  if S.sa_saving then
    batch_tick()
  end

  if just_click then
    S.blink=0; S.cur=true

    -- ── Main mode ────────────────────────────────────────────────────────
    if S.mode == "main" then
      local u = ui_cache

      -- Folder focus
      S.fol_foc = isin(u.fol.x,u.fol.y,u.fol.w,u.fol.h, S.mx,S.my)

      -- Header checkbox: select ALL
      if u.hdr_chk and isin(u.hdr_chk.x,u.hdr_chk.y,u.hdr_chk.w,u.hdr_chk.h, S.mx,S.my) then
        local all_on = count_selected(S.tracks) == #S.tracks
        local new_state = not all_on
        for _, t in ipairs(S.tracks) do t.selected = new_state end
        S.hdr_chk = new_state
      end

      -- Checkboxes: per-row  (Ctrl=folder group, Alt=exclusive, Shift=range)
      if u.row_chk_hits then
        local ctrl_held  = gfx.mouse_cap & 4  ~= 0
        local alt_held   = gfx.mouse_cap & 16 ~= 0
        local shift_held = gfx.mouse_cap & 8  ~= 0
        for _, hit in ipairs(u.row_chk_hits) do
          if isin(hit.x,hit.y,hit.w,hit.h, S.mx,S.my) then
            local i = hit.idx
            if ctrl_held then
              -- Ctrl+click: select this parent + ALL descendants (recursive)
              local t_clicked = S.tracks[i]
              local root = t_clicked.is_parent and i or t_clicked.parent_i
              if root then
                -- Walk forward from root using folder-depth to collect every
                -- descendant regardless of nesting depth
                S.tracks[root].selected = true
                local depth = 1  -- root opened a folder
                for j = root + 1, #S.tracks do
                  if depth <= 0 then break end
                  S.tracks[j].selected = true
                  local fd = S.tracks[j].fd
                  if fd == 1 then depth = depth + 1
                  elseif fd < 0 then depth = depth + fd end
                end
              else
                -- Top-level non-parent: just toggle
                S.tracks[i].selected = not S.tracks[i].selected
              end
              S.hdr_chk = (count_selected(S.tracks) == #S.tracks)
            elseif alt_held then
              -- Alt+click: exclusive - only this track selected
              for j, t in ipairs(S.tracks) do t.selected = (j == i) end
              S.hdr_chk = false
            elseif shift_held and S.last_chk_i then
              -- Shift+click: select range between last click and this row
              local lo = math.min(S.last_chk_i, i)
              local hi = math.max(S.last_chk_i, i)
              for j = lo, hi do S.tracks[j].selected = true end
              S.hdr_chk = (count_selected(S.tracks) == #S.tracks)
            else
              S.tracks[i].selected = not S.tracks[i].selected
              S.hdr_chk = (count_selected(S.tracks) == #S.tracks)
            end
            S.last_chk_i = i
            break
          end
        end
      end

      -- Save All
      if isin(u.sa.x,u.sa.y,u.sa.w,u.sa.h, S.mx,S.my) then
        S.mode="save_all"; S.sa_pre=""; S.sa_suf=""; S.sa_foc="prefix"; S.sa_sel=false
      end
      -- Save Selected
      if isin(u.sa_sel.x,u.sa_sel.y,u.sa_sel.w,u.sa_sel.h, S.mx,S.my) then
        if count_selected(S.tracks)==0 then
          set_status("No tracks selected.", false)
        else
          S.mode="save_all"; S.sa_pre=""; S.sa_suf=""; S.sa_foc="prefix"; S.sa_sel=true
        end
      end
      -- Per Channel
      if isin(u.pc.x,u.pc.y,u.pc.w,u.pc.h, S.mx,S.my) then
        start_per_channel(false)
      end
      -- Per Ch. Selected
      if isin(u.pc_sel.x,u.pc_sel.y,u.pc_sel.w,u.pc_sel.h, S.mx,S.my) then
        start_per_channel(true)
      end
      -- Refresh
      if isin(u.refresh.x,u.refresh.y,u.refresh.w,u.refresh.h, S.mx,S.my) then
        op_refresh()
      end
      -- Browse
      if isin(u.browse.x,u.browse.y,u.browse.w,u.browse.h, S.mx,S.my) then
        if reaper.JS_Dialog_BrowseForFolder then
          local ok, path = reaper.JS_Dialog_BrowseForFolder(
            "Select folder for FX Chains", S.folder)
          if ok==1 and path and path~="" then
            S.folder = path; set_status("Output folder: "..path)
          end
        else
          S.fol_foc = true
          set_status("Type path above (install js_ReaScriptAPI for browse dialog).", false)
        end
      end

    -- ── Save All dialog ──────────────────────────────────────────────────
    elseif S.mode=="save_all" and ui_cache.dlg.type=="save_all" then
      local d = ui_cache.dlg
      if isin(d.pre.x,d.pre.y,d.pre.w,d.pre.h, S.mx,S.my) then S.sa_foc="prefix" end
      if isin(d.suf.x,d.suf.y,d.suf.w,d.suf.h, S.mx,S.my) then S.sa_foc="suffix" end
      if d.conflict_hits then
        for id, hit in pairs(d.conflict_hits) do
          if isin(hit.x,hit.y,hit.w,hit.h, S.mx,S.my) then S.conflict=id end
        end
      end
      if isin(d.save.x,d.save.y,d.save.w,d.save.h, S.mx,S.my) then
        local list = {}
        for _, t in ipairs(S.tracks) do
          if not S.sa_sel or t.selected then list[#list+1]=t end
        end
        batch_start(list, S.sa_pre, S.sa_suf)
      end
      if isin(d.cancel.x,d.cancel.y,d.cancel.w,d.cancel.h, S.mx,S.my) then
        S.mode="main"
      end

    -- ── Per Channel dialog ───────────────────────────────────────────────
    elseif S.mode=="per_ch" and ui_cache.dlg.type=="per_ch" then
      local d = ui_cache.dlg
      -- Click to focus fields
      if d.pc_pre  and isin(d.pc_pre.x, d.pc_pre.y, d.pc_pre.w, d.pc_pre.h, S.mx,S.my) then
        S.pc_foc = "prefix" end
      if d.pc_name and isin(d.pc_name.x,d.pc_name.y,d.pc_name.w,d.pc_name.h,S.mx,S.my) then
        S.pc_foc = "name" end
      if d.pc_suf  and isin(d.pc_suf.x, d.pc_suf.y, d.pc_suf.w, d.pc_suf.h, S.mx,S.my) then
        S.pc_foc = "suffix" end
      -- Conflict radio clicks
      if d.conflict_hits then
        for id, hit in pairs(d.conflict_hits) do
          if isin(hit.x,hit.y,hit.w,hit.h, S.mx,S.my) then S.conflict=id end
        end
      end
      if isin(d.save.x,d.save.y,d.save.w,d.save.h, S.mx,S.my)      then op_pc_save() end
      if isin(d.skip.x,d.skip.y,d.skip.w,d.skip.h, S.mx,S.my)      then op_pc_skip() end
      if isin(d.cancel.x,d.cancel.y,d.cancel.w,d.cancel.h, S.mx,S.my) then
        S.mode="main"; set_status("Per-channel save cancelled.")
      end
    end
  end

  gfx.update()
  reaper.defer(loop)
end

------------------------------------------------------------------------------
-- ENTRY POINT
------------------------------------------------------------------------------
local function init()
  S.tracks  = collect_tracks()
  S.hdr_chk = false    -- all unchecked on start
  gfx.init("Texas ChainSave  v1.0", WIN_W, WIN_H, 0)
  gfx.setfont(1, "Arial", FONT_LARGE)
  gfx.setfont(2, "Arial", FONT_SMALL)
  set_status(string.format(
    "Loaded %d track(s).  Default folder: %s", #S.tracks, S.folder), true, 200)
end

init()
reaper.defer(loop)
