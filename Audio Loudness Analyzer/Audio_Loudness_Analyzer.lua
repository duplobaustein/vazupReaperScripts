-- @description Audio Loudness Analyzer
-- @author vazupReaperScripts
-- @version 1.3
-- @about
--   Analyzes loaded audio files.
--   Displays a waveform with overlaid LUFS-M, LUFS-S and True Peak curves.
--   Computes LUFS-I (integrated, gated), LUFS-M max, LUFS-S max,
--   True Peak (4x linear), RMS and per-channel sample peaks.
--   Hover over the waveform for a time-synced readout.
--   Streaming target comparison included.
-- @requires ReaImGui >= 0.8

local r = reaper

-- ================================================================
--  K-WEIGHTING FILTER  (ITU-R BS.1770-4 / EBU R128)
-- ================================================================

local function makeKWeightCoefs(fs)
  local pi = math.pi

  -- Stage 1: high-shelf ~1.5 kHz
  local f0 = 1681.974450955533
  local G  = 3.999843853973347
  local Q1 = 0.7071752369554196
  local K  = math.tan(pi * f0 / fs)
  local Vh = 10 ^ (G / 20)
  local Vb = Vh ^ 0.4845957
  local d  = 1 + K / Q1 + K * K
  local s1 = {
    b0 = (Vh + Vb*K/Q1 + K*K) / d,
    b1 = 2*(K*K - Vh)          / d,
    b2 = (Vh - Vb*K/Q1 + K*K) / d,
    a1 = 2*(K*K - 1)           / d,
    a2 = (1 - K/Q1 + K*K)     / d,
  }

  -- Stage 2: high-pass ~38 Hz
  local f1 = 38.13547087602444
  local Q2 = 0.5003270373238773
  local K2 = math.tan(pi * f1 / fs)
  local d2 = 1 + K2/Q2 + K2*K2
  local s2 = {
    b0 = 1/d2,
    b1 = -2/d2,
    b2 = 1/d2,
    a1 = 2*(K2*K2 - 1)        / d2,
    a2 = (1 - K2/Q2 + K2*K2) / d2,
  }

  return s1, s2
end

-- ================================================================
--  ANALYSIS
-- ================================================================

local function analyzeFile(filepath)
  local src = r.PCM_Source_CreateFromFile(filepath)
  if not src then return nil, "Could not open file" end

  local length, isQN = r.GetMediaSourceLength(src)
  local sr            = r.GetMediaSourceSampleRate(src)
  local numch         = r.GetMediaSourceNumChannels(src)
  if isQN or sr == 0 or numch == 0 then return nil, "Not a valid audio file" end

  -- Temp track / item / take
  r.PreventUIRefresh(1)
  local tidx = r.CountTracks(0)
  r.InsertTrackAtIndex(tidx, false)
  local track = r.GetTrack(0, tidx)
  local item  = r.AddMediaItemToTrack(track)
  r.SetMediaItemPosition(item, 0, false)
  r.SetMediaItemLength(item, length, false)
  local take  = r.AddTakeToMediaItem(item)
  r.SetMediaItemTake_Source(take, src)
  local acc   = r.CreateTakeAudioAccessor(take)
  r.PreventUIRefresh(-1)

  -- BS.1770-4 channel weights
  local sqrt2 = math.sqrt(2)
  local w = {}
  for c = 1, numch do w[c] = 1.0 end
  if numch == 6 then
    w[4] = 0.0; w[5] = sqrt2; w[6] = sqrt2
  elseif numch >= 8 then
    w[4] = 0.0
    for c = 5, numch do w[c] = sqrt2 end
  end

  -- Filter coefficients as locals (hot loop)
  local s1c, s2c = makeKWeightCoefs(sr)
  local c1b0,c1b1,c1b2,c1a1,c1a2 = s1c.b0,s1c.b1,s1c.b2,s1c.a1,s1c.a2
  local c2b0,c2b1,c2b2,c2a1,c2a2 = s2c.b0,s2c.b1,s2c.b2,s2c.a1,s2c.a2

  -- Per-channel state
  local fs1z1,fs1z2,fs2z1,fs2z2 = {},{},{},{}
  local peak,rmsSumSq,segSumSq   = {},{},{}
  local segMinCh,segMaxCh        = {},{}
  local segTruePk,prevSmp        = {},{}
  for c = 1, numch do
    fs1z1[c]=0; fs1z2[c]=0; fs2z1[c]=0; fs2z2[c]=0
    peak[c]=0;  rmsSumSq[c]=0; segSumSq[c]=0
    segMinCh[c]=0; segMaxCh[c]=0
    segTruePk[c]=0; prevSmp[c]=0
  end

  -- Segment storage (100 ms each)
  local hopSamples  = math.floor(0.1 * sr)
  local segSmpCount = 0
  local allSegMSQ    = {}   -- [i][c]  K-weighted mean-square
  local allSegMinCh  = {}   -- [i][c]  waveform min per channel
  local allSegMaxCh  = {}   -- [i][c]  waveform max per channel
  local allSegTP     = {}   -- [i]     true-peak across channels

  local CHUNK       = 2048
  local buf         = r.new_array(CHUNK * numch)
  local totalSmp    = math.floor(length * sr)
  local samplesRead = 0
  local readPos     = 0.0

  while samplesRead < totalSmp do
    local toRead = math.min(CHUNK, totalSmp - samplesRead)
    local got    = r.GetAudioAccessorSamples(acc, sr, numch, readPos, toRead, buf)
    if got == 0 then break end

    for s = 0, toRead - 1 do
      for c = 1, numch do
        local x = buf[s * numch + c]
        local p = prevSmp[c]
        local ax = x >= 0 and x or -x

        -- Sample peak
        if ax > peak[c] then peak[c] = ax end

        -- RMS
        rmsSumSq[c] = rmsSumSq[c] + x*x

        -- K-weight stage 1
        local z1,z2 = fs1z1[c],fs1z2[c]
        local y1    = c1b0*x + z1
        fs1z1[c]    = c1b1*x - c1a1*y1 + z2
        fs1z2[c]    = c1b2*x - c1a2*y1

        -- K-weight stage 2
        z1,z2    = fs2z1[c],fs2z2[c]
        local y  = c2b0*y1 + z1
        fs2z1[c] = c2b1*y1 - c2a1*y + z2
        fs2z2[c] = c2b2*y1 - c2a2*y
        segSumSq[c] = segSumSq[c] + y*y

        -- Waveform min/max per channel
        if x < segMinCh[c] then segMinCh[c] = x end
        if x > segMaxCh[c] then segMaxCh[c] = x end

        -- True Peak: 4x linear interp
        local t1 = p*0.75+x*0.25; t1 = t1>=0 and t1 or -t1
        local t2 = p*0.50+x*0.50; t2 = t2>=0 and t2 or -t2
        local t3 = p*0.25+x*0.75; t3 = t3>=0 and t3 or -t3
        local tp = ax>t1 and ax or t1
              tp  = tp>t2 and tp  or t2
              tp  = tp>t3 and tp  or t3
        if tp > segTruePk[c] then segTruePk[c] = tp end

        prevSmp[c] = x
      end

      samplesRead   = samplesRead + 1
      segSmpCount   = segSmpCount + 1

      if segSmpCount >= hopSamples then
        local seg    = {}
        local minRow = {}
        local maxRow = {}
        local wTP    = 0
        for c = 1, numch do
          seg[c]    = segSumSq[c] / segSmpCount
          minRow[c] = segMinCh[c]
          maxRow[c] = segMaxCh[c]
          if segTruePk[c] > wTP then wTP = segTruePk[c] end
          segSumSq[c]=0; segMinCh[c]=0; segMaxCh[c]=0; segTruePk[c]=0
        end
        allSegMSQ[#allSegMSQ+1]   = seg
        allSegMinCh[#allSegMinCh+1] = minRow
        allSegMaxCh[#allSegMaxCh+1] = maxRow
        allSegTP[#allSegTP+1]     = wTP
        segSmpCount = 0
      end
    end
    readPos = samplesRead / sr
  end

  -- Flush trailing partial segment
  if segSmpCount > 0 then
    local seg    = {}
    local minRow = {}
    local maxRow = {}
    local wTP    = 0
    for c = 1, numch do
      seg[c]    = segSumSq[c] / segSmpCount
      minRow[c] = segMinCh[c]
      maxRow[c] = segMaxCh[c]
      if segTruePk[c] > wTP then wTP = segTruePk[c] end
    end
    allSegMSQ[#allSegMSQ+1]    = seg
    allSegMinCh[#allSegMinCh+1] = minRow
    allSegMaxCh[#allSegMaxCh+1] = maxRow
    allSegTP[#allSegTP+1]      = wTP
  end

  -- Cleanup
  r.DestroyAudioAccessor(acc)
  r.PreventUIRefresh(1)
  r.DeleteTrack(track)
  r.PreventUIRefresh(-1)
  r.UpdateArrange()

  local numSegs = #allSegMSQ

  -- RMS
  local rmsAllSq = 0
  local rmsPerCh = {}
  for c = 1, numch do
    rmsPerCh[c] = math.sqrt(rmsSumSq[c] / samplesRead)
    rmsAllSq    = rmsAllSq + rmsSumSq[c]
  end
  local rmsOverall = math.sqrt(rmsAllSq / (samplesRead * numch))

  -- LUFS-I (gated)
  local blockMS = {}
  for i = 4, numSegs do
    local ms = 0
    for c = 1, numch do
      ms = ms + w[c]*(allSegMSQ[i-3][c]+allSegMSQ[i-2][c]+
                      allSegMSQ[i-1][c]+allSegMSQ[i][c])*0.25
    end
    blockMS[#blockMS+1] = ms
  end

  local lufsI
  if #blockMS == 0 then
    lufsI = -math.huge
  else
    local ABS_GATE = 10^((-70+0.691)/10)
    local p1,p1Sum = {},0
    for _,ms in ipairs(blockMS) do
      if ms >= ABS_GATE then p1[#p1+1]=ms; p1Sum=p1Sum+ms end
    end
    if #p1 == 0 then
      lufsI = -math.huge
    else
      local relT = (p1Sum/#p1)*0.1
      local p2s,p2n = 0,0
      for _,ms in ipairs(p1) do
        if ms >= relT then p2s=p2s+ms; p2n=p2n+1 end
      end
      lufsI = p2n>0 and (-0.691+10*math.log(p2s/p2n,10)) or -math.huge
    end
  end

  -- LUFS-M time series (400 ms, ungated)
  local lufsM_ts = {}
  for i = 4, numSegs do
    local ms = 0
    for c = 1, numch do
      ms = ms + w[c]*(allSegMSQ[i-3][c]+allSegMSQ[i-2][c]+
                      allSegMSQ[i-1][c]+allSegMSQ[i][c])*0.25
    end
    lufsM_ts[i] = ms>0 and (-0.691+10*math.log(ms,10)) or -math.huge
  end

  -- LUFS-S time series (3000 ms, ungated)
  local lufsS_ts = {}
  for i = 30, numSegs do
    local ms = 0
    for c = 1, numch do
      local sum = 0
      for j = i-29, i do sum = sum + allSegMSQ[j][c] end
      ms = ms + w[c]*sum/30
    end
    lufsS_ts[i] = ms>0 and (-0.691+10*math.log(ms,10)) or -math.huge
  end

  -- True Peak dBFS per segment
  local truePkDB = {}
  for i = 1, numSegs do
    local tp = allSegTP[i]
    truePkDB[i] = tp>0 and (20*math.log(tp,10)) or -math.huge
  end

  -- Summary maxima
  local lufsM_max, lufsS_max = -math.huge, -math.huge
  for _,v in pairs(lufsM_ts) do
    if v and v ~= -math.huge and v > lufsM_max then lufsM_max = v end
  end
  for _,v in pairs(lufsS_ts) do
    if v and v ~= -math.huge and v > lufsS_max then lufsS_max = v end
  end
  local tpMax = 0
  for _,tp in ipairs(allSegTP) do if tp > tpMax then tpMax = tp end end
  local tpMaxDB = tpMax>0 and (20*math.log(tpMax,10)) or -math.huge

  return {
    filename   = filepath:match("([^/\\]+)$") or filepath,
    length     = length,
    samplerate = sr,
    numch      = numch,
    peak       = peak,
    rmsPerCh   = rmsPerCh,
    rmsOverall = rmsOverall,
    lufsI      = lufsI,
    lufsM_max  = lufsM_max,
    lufsS_max  = lufsS_max,
    tpMaxDB    = tpMaxDB,
    numSegs    = numSegs,
    segMinCh   = allSegMinCh,  -- [i][c]
    segMaxCh   = allSegMaxCh,  -- [i][c]
    lufsM_ts   = lufsM_ts,
    lufsS_ts   = lufsS_ts,
    truePkDB   = truePkDB,
  }
end

-- ================================================================
--  DRAWING
-- ================================================================

local DB_MIN   = -60
local DB_MAX   =  6

-- Colours (0xRRGGBBAA)
local C_BG      = 0x0C1018FF
local C_GRID    = 0x18273AFF
local C_GRIDZ   = 0x263D5AFF
local C_BORDER  = 0x2A3D5AFF
local C_WAVEL   = 0x1E5A8AFF   -- L channel waveform
local C_WAVER   = C_WAVEL      -- R channel waveform (same as L)
local C_WAVEDIV = 0x1C2D3EFF   -- divider between L / R
local C_LUFSM   = 0x00C8FFFF
local C_LUFSS   = 0xFFD000FF
local C_TP      = 0xFF7033FF
local C_TPCLIP  = 0xFF2222FF
local C_HOVER   = 0xFFFFFF30
local C_AXLBL   = 0x4A6680FF
local C_LBLL    = 0x2E7ABBFF   -- "L" label
local C_LBLR    = C_LBLL       -- "R" label (same as L)

local GRID_DBS  = { 0, -6, -14, -18, -23, -40 }

local function dbFrac(db)
  if not db or db ~= db or db <= -math.huge then return 0 end
  return (math.max(DB_MIN, math.min(DB_MAX, db)) - DB_MIN) / (DB_MAX - DB_MIN)
end
local function dbY(db, py, ph)
  return py + ph*(1.0 - dbFrac(db))
end

-- ================================================================
--  COMBINED PANEL: waveform (per-channel) + overlaid curves
-- ================================================================

local function drawPanel(dl, res, px, py, pw, ph, hf, showM, showS, showTP)
  -- Background
  r.ImGui_DrawList_AddRectFilled(dl, px, py, px+pw, py+ph, C_BG)

  local n      = res.numSegs
  local stereo = res.numch >= 2

  -- ---- dB grid lines (drawn before waveform so waveform is on top) ----
  for _, db in ipairs(GRID_DBS) do
    local gy  = dbY(db, py, ph)
    local col = db == 0 and C_GRIDZ or C_GRID
    r.ImGui_DrawList_AddLine(dl, px, gy, px+pw, gy, col, 1.0)
    r.ImGui_DrawList_AddText(dl, px+3, gy-11, C_AXLBL, tostring(db))
  end

  -- ---- Waveform bars ----
  if n > 0 then
    local numChanDraw = stereo and 2 or 1

    for ch = 1, numChanDraw do
      -- Each channel gets half the panel; mono gets the whole panel
      local band_y, band_h
      if stereo then
        band_y = py + (ch-1) * ph * 0.5
        band_h = ph * 0.5
      else
        band_y = py
        band_h = ph
      end

      local mid_y = band_y + band_h * 0.5
      local col   = ch == 1 and C_WAVEL or C_WAVER

      -- Centre line for this channel's band
      r.ImGui_DrawList_AddLine(dl, px, mid_y, px+pw, mid_y, C_WAVEDIV, 1.0)

      for pixi = 0, math.floor(pw)-1 do
        local i0 = math.max(1, math.floor(pixi     / pw * n) + 1)
        local i1 = math.min(n, math.max(i0, math.ceil((pixi+1) / pw * n)))

        local lo, hi = 0.0, 0.0
        for i = i0, i1 do
          local vn = res.segMinCh[i][ch]
          local vx = res.segMaxCh[i][ch]
          if vn and vn < lo then lo = vn end
          if vx and vx > hi then hi = vx end
        end

        local bx   = px + pixi + 0.5
        local yTop = mid_y - band_h * 0.5 * hi
        local yBot = mid_y - band_h * 0.5 * lo
        if yBot - yTop < 1.0 then yBot = yTop + 1.0 end
        -- Clamp to band
        yTop = math.max(band_y,          yTop)
        yBot = math.min(band_y + band_h, yBot)
        r.ImGui_DrawList_AddLine(dl, bx, yTop, bx, yBot, col, 1.0)
      end
    end

    -- Divider line between L and R bands
    if stereo then
      local dy = py + ph * 0.5
      r.ImGui_DrawList_AddLine(dl, px, dy, px+pw, dy, C_BORDER, 1.0)
      -- Channel labels top-left of each band
      r.ImGui_DrawList_AddText(dl, px+4, py+3,        C_LBLL, "L")
      r.ImGui_DrawList_AddText(dl, px+4, py+ph*0.5+3, C_LBLR, "R")
    end
  end

  -- ---- Overlay curves ----
  if n >= 2 then
    local den = n - 1

    local function drawCurve(ts, i_start, col, thick)
      for i = i_start+1, n do
        local v0 = ts[i-1]
        local v1 = ts[i]
        if v0 and v0 ~= -math.huge and v1 and v1 ~= -math.huge then
          local x0 = px + (i-2)/den * pw
          local x1 = px + (i-1)/den * pw
          local y0 = dbY(v0, py, ph)
          local y1 = dbY(v1, py, ph)
          r.ImGui_DrawList_AddLine(dl, x0, y0, x1, y1, col, thick)
        end
      end
    end

    -- Draw order: S (widest, bottom), M, TP (sharpest, top)
    if showS then drawCurve(res.lufsS_ts, 30, C_LUFSS, 2.0) end
    if showM then drawCurve(res.lufsM_ts,  4, C_LUFSM, 1.5) end

    if showTP then
      for i = 2, n do
        local v0 = res.truePkDB[i-1]
        local v1 = res.truePkDB[i]
        if v0 and v0 ~= -math.huge and v1 and v1 ~= -math.huge then
          local x0 = px + (i-2)/den * pw
          local x1 = px + (i-1)/den * pw
          local y0 = dbY(v0, py, ph)
          local y1 = dbY(v1, py, ph)
          local col = (v0 > 0 or v1 > 0) and C_TPCLIP or C_TP
          r.ImGui_DrawList_AddLine(dl, x0, y0, x1, y1, col, 1.0)
        end
      end
    end
  end

  -- Hover cursor
  if hf then
    local hx = px + hf * pw
    r.ImGui_DrawList_AddLine(dl, hx, py, hx, py+ph, C_HOVER, 1.5)
  end

  r.ImGui_DrawList_AddRect(dl, px, py, px+pw, py+ph, C_BORDER, 0, 0, 1.0)
end

-- ================================================================
--  GUI
-- ================================================================

if not r.ImGui_CreateContext then
  r.ShowMessageBox("This script requires ReaImGui.\nInstall via ReaPack.", "WAV Analyzer", 0)
  return
end

local ctx  = r.ImGui_CreateContext("WAV Loudness Analyzer")
local MONO = r.ImGui_CreateFont("Courier New", 13)
r.ImGui_Attach(ctx, MONO)

local PANEL_H = 220

local state = {
  filepath  = "",
  result    = nil,
  errMsg    = nil,
  hoverFrac = nil,
  showM     = true,
  showS     = true,
  showTP    = true,
}

-- Formatting
local function fmtLUFS(v)
  if not v or v ~= v or v == -math.huge then return "-inf LUFS" end
  return string.format("%.1f LUFS", v)
end
local function fmtDB(lin)
  if not lin or lin <= 0 then return "-inf dBFS" end
  return string.format("%.2f dBFS", 20*math.log(lin,10))
end
local function fmtDBv(db)
  if not db or db ~= db or db == -math.huge then return "-inf dBFS" end
  return string.format("%.2f dBFS", db)
end
local function fmtTime(s)
  local m = math.floor(s/60)
  return string.format("%d:%05.2f", m, s-m*60)
end
local function fmtTimeS(s)
  local m = math.floor(s/60)
  return string.format("%d:%04.1f", m, s-m*60)
end

local U_OK    = 0x77DD77FF
local U_LOUD  = 0xFF9944FF
local U_QUIET = 0x88AAFFFF
local U_ERR   = 0xFF5555FF
local U_DIM   = 0x778899FF
local CH_NAMES = {"L","R","C","LFE","Ls","Rs","Lss","Rss"}
local TARGETS  = {
  { name="Spotify / YouTube / Tidal", lufs=-14 },
  { name="Apple Music",               lufs=-16 },
  { name="Broadcast (EBU R128)",      lufs=-23 },
}

-- ================================================================
local function loop()
  r.ImGui_SetNextWindowSize(ctx, 570, 0, r.ImGui_Cond_FirstUseEver())
  local visible, open = r.ImGui_Begin(ctx, "WAV Loudness Analyzer", true)

  if visible then

    -- File row
    r.ImGui_SetNextItemWidth(ctx, 410)
    local ch, np = r.ImGui_InputText(ctx, "##fp", state.filepath)
    if ch then state.filepath=np; state.result=nil; state.errMsg=nil end
    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx, "Browse...", 90, 0) then
      local ok, path = r.GetUserFileNameForRead("", "Select Audio File", "")
      if ok then state.filepath=path; state.result=nil; state.errMsg=nil end
    end

    r.ImGui_Spacing(ctx)

    local canGo = state.filepath ~= ""
    if not canGo then r.ImGui_BeginDisabled(ctx) end
    if r.ImGui_Button(ctx, "  Analyze  ") then
      state.result=nil; state.errMsg=nil; state.hoverFrac=nil
      local res, err = analyzeFile(state.filepath)
      if err then
        state.errMsg = err
      else
        state.result = res
      end
    end
    if not canGo then r.ImGui_EndDisabled(ctx) end
    r.ImGui_SameLine(ctx)
    r.ImGui_TextDisabled(ctx, "  (may take a few seconds for long files)")

    r.ImGui_Spacing(ctx)
    r.ImGui_Separator(ctx)
    r.ImGui_Spacing(ctx)

    if state.errMsg then
      r.ImGui_TextColored(ctx, U_ERR, "Error: " .. state.errMsg)

    elseif state.result then
      local res = state.result
      r.ImGui_PushFont(ctx, MONO, 0)

      local li = res.lufsI
      local lc = (li and li ~= -math.huge) and
                 (li > -14 and U_LOUD or (li < -23 and U_QUIET or U_OK)) or U_DIM

      -- ---- Left column: file info + loudness stats ----
      r.ImGui_BeginGroup(ctx)

        r.ImGui_TextColored(ctx, U_DIM, "File     "); r.ImGui_SameLine(ctx)
        r.ImGui_Text(ctx, res.filename)
        r.ImGui_TextColored(ctx, U_DIM, "Format   "); r.ImGui_SameLine(ctx)
        r.ImGui_Text(ctx, string.format("%s   %d Hz  %d ch",
          fmtTime(res.length), res.samplerate, res.numch))

        r.ImGui_Spacing(ctx)

        r.ImGui_TextColored(ctx, U_DIM,  "LUFS-I   "); r.ImGui_SameLine(ctx)
        r.ImGui_TextColored(ctx, lc,     fmtLUFS(li))

        r.ImGui_TextColored(ctx, C_LUFSM,"LUFS-M ▲ "); r.ImGui_SameLine(ctx)
        r.ImGui_TextColored(ctx, C_LUFSM, fmtLUFS(res.lufsM_max))

        r.ImGui_TextColored(ctx, C_LUFSS,"LUFS-S ▲ "); r.ImGui_SameLine(ctx)
        r.ImGui_TextColored(ctx, C_LUFSS, fmtLUFS(res.lufsS_max))

        local tpc = res.tpMaxDB and res.tpMaxDB > 0 and U_ERR or C_TP
        r.ImGui_TextColored(ctx, C_TP,   "True Pk  "); r.ImGui_SameLine(ctx)
        r.ImGui_TextColored(ctx, tpc,    fmtDBv(res.tpMaxDB) .. "  (4× linear)")

        r.ImGui_TextColored(ctx, U_DIM,  "RMS      "); r.ImGui_SameLine(ctx)
        r.ImGui_Text(ctx, fmtDB(res.rmsOverall))

        r.ImGui_Spacing(ctx)
        for c = 1, res.numch do
          local lbl = (CH_NAMES[c] or ("Ch"..c)) .. " Peak"
          r.ImGui_TextColored(ctx, U_DIM, string.format("%-9s ", lbl))
          r.ImGui_SameLine(ctx)
          if res.peak[c] >= 1.0 then
            r.ImGui_TextColored(ctx, U_ERR, fmtDB(res.peak[c]) .. "  CLIP!")
          else
            r.ImGui_Text(ctx, fmtDB(res.peak[c]))
          end
        end

      r.ImGui_EndGroup(ctx)

      -- ---- Right column: streaming targets ----
      r.ImGui_SameLine(ctx, 0, 28)
      r.ImGui_BeginGroup(ctx)

        r.ImGui_TextColored(ctx, U_DIM, "Streaming targets")
        r.ImGui_Spacing(ctx)
        if li and li ~= -math.huge then
          for _, t in ipairs(TARGETS) do
            local diff = li - t.lufs
            local col, tag
            if     diff >  0.5 then col=U_LOUD;  tag=string.format("+%.1f LU over",  diff)
            elseif diff < -0.5 then col=U_QUIET; tag=string.format("%.1f LU under", diff)
            else                     col=U_OK;    tag="on target"
            end
            r.ImGui_TextColored(ctx, U_DIM, string.format("%-22s %4.0f  ", t.name, t.lufs))
            r.ImGui_SameLine(ctx)
            r.ImGui_TextColored(ctx, col, tag)
          end
        else
          r.ImGui_TextDisabled(ctx, "(No LUFS data)")
        end

      r.ImGui_EndGroup(ctx)

      r.ImGui_PopFont(ctx)
      r.ImGui_Spacing(ctx)
      r.ImGui_Separator(ctx)
      r.ImGui_Spacing(ctx)

      -- ---- Curve toggle row ----
      -- Coloured push-button checkboxes matching each curve colour
      local function toggleBtn(label, colOn, colOff, active)
        local col = active and colOn or colOff
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        col)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(),
          active and (col | 0x28000000) or (col | 0x18000000))
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(),  col)
        if active then
          r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0x000000FF)
        end
        local pressed = r.ImGui_Button(ctx, label, 0, 0)
        r.ImGui_PopStyleColor(ctx, active and 4 or 3)
        return pressed
      end

      r.ImGui_PushFont(ctx, MONO, 0)

      if toggleBtn("  LUFS-M 400ms  ", C_LUFSM, 0x1C3A44FF, state.showM) then
        state.showM = not state.showM
      end
      r.ImGui_SameLine(ctx, 0, 6)
      if toggleBtn("  LUFS-S 3s  ", C_LUFSS, 0x3A3000FF, state.showS) then
        state.showS = not state.showS
      end
      r.ImGui_SameLine(ctx, 0, 6)
      if toggleBtn("  True Peak  ", C_TP, 0x3A1800FF, state.showTP) then
        state.showTP = not state.showTP
      end

      r.ImGui_PopFont(ctx)
      r.ImGui_Spacing(ctx)

      -- ---- Combined panel ----
      local dl         = r.ImGui_GetWindowDrawList(ctx)
      local avail_w, _ = r.ImGui_GetContentRegionAvail(ctx)
      local pw         = avail_w

      state.hoverFrac = nil
      local ppx, ppy  = r.ImGui_GetCursorScreenPos(ctx)
      r.ImGui_InvisibleButton(ctx, "##panel", pw, PANEL_H)
      if r.ImGui_IsItemHovered(ctx) then
        local mx, _ = r.ImGui_GetMousePos(ctx)
        state.hoverFrac = math.max(0, math.min(1, (mx-ppx)/pw))
      end
      drawPanel(dl, res, ppx, ppy, pw, PANEL_H,
        state.hoverFrac, state.showM, state.showS, state.showTP)

      -- Hover tooltip
      if state.hoverFrac and res.numSegs > 1 then
        local si   = math.max(1, math.min(res.numSegs,
                       math.floor(state.hoverFrac * res.numSegs) + 1))
        local tSec = (si-1) * 0.1
        local vm   = res.lufsM_ts[si]
        local vs   = res.lufsS_ts[si]
        local vtp  = res.truePkDB[si]

        r.ImGui_BeginTooltip(ctx)
        r.ImGui_PushFont(ctx, MONO, 0)
        r.ImGui_Text(ctx, string.format("t = %s", fmtTimeS(tSec)))
        r.ImGui_Separator(ctx)
        r.ImGui_TextColored(ctx, C_LUFSM,
          string.format("LUFS-M  %s", fmtLUFS(vm)))
        r.ImGui_TextColored(ctx, C_LUFSS,
          string.format("LUFS-S  %s", fmtLUFS(vs)))
        r.ImGui_TextColored(ctx,
          (vtp and vtp > 0) and U_ERR or C_TP,
          string.format("True Pk %s", fmtDBv(vtp)))
        r.ImGui_PopFont(ctx)
        r.ImGui_EndTooltip(ctx)
      end

    else
      r.ImGui_TextDisabled(ctx, "Select an audio file and click Analyze.")
    end

  end

  r.ImGui_End(ctx)
  if open then r.defer(loop) end
end

r.defer(loop)
