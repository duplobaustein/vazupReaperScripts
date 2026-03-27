-- @description Set Track Layout (A, B, C)
-- @author vazupReaperScripts
-- @version 1.1
-- @repository https://github.com/duplobaustein/vazupReaperScripts/raw/main/index.xml
-- @provides
--   [main] Load_Layout_A.lua
--   [main] Load_Layout_B.lua
--   [main] Load_Layout_C.lua
-- @about
--   Sets the Default7 TCP and MCP layout to A, B, or C for all tracks in the project. Quick and easy!

local layout_name = "A"

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
