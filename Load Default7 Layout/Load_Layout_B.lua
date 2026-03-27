-- Set Track Layout B (TCP + MCP)
-- Part of the "Set Track Layout (A, B, C)" package by duplobaustein

local layout_name = "B"

reaper.PreventUIRefresh(1)

local track_count = reaper.CountTracks(0)
for i = 0, track_count - 1 do
  local track = reaper.GetTrack(0, i)
  reaper.GetSetMediaTrackInfo_String(track, "P_TCP_LAYOUT", layout_name, true)
  reaper.GetSetMediaTrackInfo_String(track, "P_MCP_LAYOUT", layout_name, true)
end

reaper.PreventUIRefresh(-1)
reaper.TrackList_AdjustWindows(false)
reaper.UpdateArrange()
