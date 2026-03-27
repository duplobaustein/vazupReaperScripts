-- @description Set Razor Start to Mouse Cursor
-- @author vazupReaperScripts
-- @version 1.0
-- @provides [main] Set Razor End to Mouse Cursor.lua
-- @about
--   Sets the start of the razor edit area to the mouse cursor position on the
--   track under the mouse cursor.
--
--   If a razor area exists anywhere in the session (at or to the right of the
--   cursor), its start is moved to the cursor and the area is expanded
--   vertically to cover all tracks between the razor's track and the track
--   under the mouse.
--
--   If no razor area exists anywhere, a tiny 5 ms razor area is created on
--   the track under the mouse cursor, starting at the cursor position.
--
--   Requires the SWS Extension.

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function parseRazorEdits(str)
  local razors = {}
  for s, e, g in (str or ""):gmatch('([%d%.%-]+)%s+([%d%.%-]+)%s+(".-")') do
    table.insert(razors, { start = tonumber(s), finish = tonumber(e), guid = g })
  end
  return razors
end

local function buildRazorString(razors)
  local parts = {}
  for _, r in ipairs(razors) do
    table.insert(parts, string.format("%.10f %.10f %s", r.start, r.finish, r.guid))
  end
  return table.concat(parts, " ")
end

local function setTrackLevelRazor(track, newStart, newFinish)
  local _, str = reaper.GetSetMediaTrackInfo_String(track, "P_RAZOREDITS", "", false)
  local razors = parseRazorEdits(str)
  local found = false
  for _, r in ipairs(razors) do
    if r.guid == '""' then
      r.start  = newStart
      r.finish = newFinish
      found = true
      break
    end
  end
  if not found then
    table.insert(razors, { start = newStart, finish = newFinish, guid = '""' })
  end
  reaper.GetSetMediaTrackInfo_String(track, "P_RAZOREDITS", buildRazorString(razors), true)
end

-- ── Main ──────────────────────────────────────────────────────────────────────

local mouseX, mouseY = reaper.GetMousePosition()
local mouseTrack     = reaper.GetTrackFromPoint(mouseX, mouseY)
local mousePos       = reaper.BR_PositionAtMouseCursor(false)

if not mouseTrack then
  reaper.ShowMessageBox("No track found under mouse cursor.", "Set Razor Start", 0)
  return
end
if not mousePos or mousePos < 0 then
  reaper.ShowMessageBox("Mouse cursor is not over the arrange view timeline.", "Set Razor Start", 0)
  return
end

local mouseTrackIdx = reaper.GetMediaTrackInfo_Value(mouseTrack, "IP_TRACKNUMBER") - 1
local numTracks     = reaper.CountTracks(0)

local bestTrackIdx = nil
local bestTimeDist = math.huge
local bestFinish   = nil

for ti = 0, numTracks - 1 do
  local track = reaper.GetTrack(0, ti)
  local _, str = reaper.GetSetMediaTrackInfo_String(track, "P_RAZOREDITS", "", false)
  local razors = parseRazorEdits(str)
  for _, r in ipairs(razors) do
    if r.guid == '""' and r.start >= mousePos then
      local timeDist = r.start - mousePos
      local isBetter =
        timeDist < bestTimeDist or
        (timeDist == bestTimeDist and
          math.abs(ti - mouseTrackIdx) < math.abs((bestTrackIdx or mouseTrackIdx) - mouseTrackIdx))
      if isBetter then
        bestTimeDist = timeDist
        bestTrackIdx = ti
        bestFinish   = r.finish
      end
    end
  end
end

reaper.Undo_BeginBlock()

if bestTrackIdx == nil then
  local razorStr = string.format("%.10f %.10f \"\"", mousePos, mousePos + 0.005)
  reaper.GetSetMediaTrackInfo_String(mouseTrack, "P_RAZOREDITS", razorStr, true)
else
  local fromIdx = math.min(mouseTrackIdx, bestTrackIdx)
  local toIdx   = math.max(mouseTrackIdx, bestTrackIdx)
  for ti = fromIdx, toIdx do
    setTrackLevelRazor(reaper.GetTrack(0, ti), mousePos, bestFinish)
  end
end

reaper.Undo_EndBlock("Set Razor Start to Mouse Cursor", -1)
reaper.UpdateArrange()
