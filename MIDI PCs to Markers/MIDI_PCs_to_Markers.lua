-- @description MIDI Program Change Marker/Region Creator
-- @author vazupReaperScripts
-- @version 1.2
-- @repository https://github.com/duplobaustein/vazupReaperScripts
-- @provides
--   [main] MIDI_PCs_to_Markers.lua
-- @about
--   Creates named markers or regions from MIDI Program Change events.
--   Map bank/program combinations to custom names, store up to 8 presets,
--   and apply to the whole session or the current time selection.
--   Export and import presets as CSV files for easy sharing.
-- @changelog
--   Added Export CSV, preset save/load safety prompts, fixed selection behaviour.

local ctx = reaper.ImGui_CreateContext("Program Change Naming")

local EXT_SECTION      = "PC_MarkerTool_Presets"
local EXT_NAME_SECTION = "PC_MarkerTool_PresetNames"

local programEntries  = {}
local presetNames     = {}
local focusRequest    = nil
local scopeOptions    = {"Whole Session", "Time Selection"}
local scopeIndex      = 0
local rowWidth        = 540

local selected        = {}
local lastSelectedRow = nil

local isDragging      = false
local dragSourceRow   = nil
local dragTargetRow   = nil
local rowScreenY      = {}

local undoStack       = {}
local redoStack       = {}

local TYPE_OPTIONS    = {"Marker", "Region"}
local exportCSVModal  = false
local presetModal     = nil  -- {action="save"|"load", slot=n}

------------------------------------------------------------
-- Entry constructor
------------------------------------------------------------

local function newEntry()
    return {bank=0, program=0, name="", outtype="Marker", lane=0}
end

------------------------------------------------------------
-- Initialize
------------------------------------------------------------

for i = 1, 8 do
    table.insert(programEntries, newEntry())
end

for i = 1, 8 do
    local n = reaper.GetExtState(EXT_NAME_SECTION, "Slot"..i)
    presetNames[i] = (n ~= "") and n or ("Preset "..i)
end

------------------------------------------------------------
-- Undo / Redo
------------------------------------------------------------

local function deepCopy(tbl)
    local c = {}
    for _, e in ipairs(tbl) do
        table.insert(c, {
            bank=e.bank, program=e.program, name=e.name,
            outtype=e.outtype or "Marker", lane=e.lane or 0
        })
    end
    return c
end

local function pushUndo()
    table.insert(undoStack, deepCopy(programEntries))
    redoStack = {}
    if #undoStack > 50 then table.remove(undoStack, 1) end
end

local function doUndo()
    if #undoStack == 0 then return end
    table.insert(redoStack, deepCopy(programEntries))
    programEntries = table.remove(undoStack)
    selected = {}; lastSelectedRow = nil
end

local function doRedo()
    if #redoStack == 0 then return end
    table.insert(undoStack, deepCopy(programEntries))
    programEntries = table.remove(redoStack)
    selected = {}; lastSelectedRow = nil
end

------------------------------------------------------------
-- Serialization
------------------------------------------------------------

local function serializeTable(tbl)
    local s = ""
    for _, e in ipairs(tbl) do
        local t = (e.outtype == "Region") and "R" or "M"
        s = s..e.bank..","..e.program..","..e.name:gsub("[|,]"," ")..","..t..","..(e.lane or 0).."|"
    end
    return s
end

local function deserializeTable(str)
    local t = {}
    for row in str:gmatch("([^|]+)") do
        local parts = {}
        for p in (row..","):gmatch("([^,]*),") do
            table.insert(parts, p)
        end
        local bank = tonumber(parts[1])
        local prog = tonumber(parts[2])
        if bank and prog then
            table.insert(t, {
                bank=bank, program=prog, name=parts[3] or "",
                outtype=(parts[4]=="R") and "Region" or "Marker",
                lane=tonumber(parts[5]) or 0
            })
        end
    end
    return t
end

------------------------------------------------------------
-- Presets
------------------------------------------------------------

local function SavePreset(slot)
    presetModal = {action="save", slot=slot}
end

local function LoadPreset(slot)
    presetModal = {action="load", slot=slot}
end

local function DoSavePreset(slot)
    reaper.SetExtState(EXT_SECTION, "Slot"..slot,
        serializeTable(programEntries), true)
    reaper.SetExtState(EXT_NAME_SECTION, "Slot"..slot,
        presetNames[slot], true)
end

local function DoLoadPreset(slot)
    local data = reaper.GetExtState(EXT_SECTION, "Slot"..slot)
    if data ~= "" then
        pushUndo()
        programEntries = deserializeTable(data)
        selected = {}; lastSelectedRow = nil
    end
end

------------------------------------------------------------
-- Export / Import
------------------------------------------------------------

local function ExportCSV(selOnly)
    local lines = {"bank,program,name"}
    for i, e in ipairs(programEntries) do
        if not selOnly or selected[i] then
            table.insert(lines,
                e.bank..","..e.program..","..e.name:gsub(",", " "))
        end
    end
    local csv  = table.concat(lines, "\n")
    local path
    if reaper.JS_Dialog_BrowseForSaveFile then
        local ok, p = reaper.JS_Dialog_BrowseForSaveFile(
            "Export Rows as CSV", reaper.GetResourcePath(),
            "MIDI_PC_Rows.csv",
            "CSV Files (.csv)\0*.csv\0All Files\0*.*\0")
        if ok and p ~= "" then
            path = p:match("%.csv$") and p or (p..".csv")
        end
    else
        path = reaper.GetResourcePath().."/Scripts/MIDI_PC_Rows.csv"
    end
    if not path then return end
    local f = io.open(path, "w")
    if f then f:write(csv); f:close() end
end

local function ExportPresets()
    local lines = {
        "# MIDI PC to Markers - Preset Export",
        "# slot,preset_name,bank,program,entry_name,type,lane"
    }
    for slot = 1, 8 do
        local data     = reaper.GetExtState(EXT_SECTION, "Slot"..slot)
        local slotName = reaper.GetExtState(EXT_NAME_SECTION, "Slot"..slot)
        if slotName == "" then slotName = "Preset "..slot end
        if data ~= "" then
            for _, e in ipairs(deserializeTable(data)) do
                local t = (e.outtype == "Region") and "R" or "M"
                table.insert(lines,
                    slot..","..slotName:gsub(",", " ")..","..e.bank..","..e.program..","..e.name:gsub(",", " ")..","..t..","..(e.lane or 0))
            end
        else
            table.insert(lines, slot..","..slotName:gsub(",", " ")..",,,,M,0")
        end
    end
    local csv  = table.concat(lines, "\n")
    local path
    if reaper.JS_Dialog_BrowseForSaveFile then
        local ok, p = reaper.JS_Dialog_BrowseForSaveFile(
            "Export Presets", reaper.GetResourcePath(),
            "MIDI_PC_Presets.csv",
            "CSV Files (.csv)\0*.csv\0All Files\0*.*\0")
        if ok and p ~= "" then
            path = p:match("%.csv$") and p or (p..".csv")
        end
    else
        path = reaper.GetResourcePath().."/Scripts/MIDI_PC_Presets.csv"
    end
    if not path then return end
    local f = io.open(path, "w")
    if f then f:write(csv); f:close() end
end

local function ImportPresets()
    local ok, path = reaper.GetUserFileNameForRead(
        reaper.GetResourcePath().."/Scripts", "Import Presets CSV", "csv")
    if not ok or path == "" then return end
    local f = io.open(path, "r")
    if not f then return end
    local slotData, slotNames = {}, {}
    for line in f:lines() do
        if not line:match("^#") and line ~= "" then
            local parts = {}
            for p in (line..","):gmatch("([^,]*),") do
                table.insert(parts, p)
            end
            local s = tonumber(parts[1])
            if s and s >= 1 and s <= 8 then
                slotNames[s] = (parts[2] ~= "") and parts[2] or ("Preset "..s)
                if parts[3] ~= "" and parts[4] ~= "" then
                    if not slotData[s] then slotData[s] = {} end
                    table.insert(slotData[s], {
                        bank=tonumber(parts[3]) or 0,
                        program=tonumber(parts[4]) or 0,
                        name=parts[5] or "",
                        outtype=(parts[6]=="R") and "Region" or "Marker",
                        lane=tonumber(parts[7]) or 0
                    })
                end
            end
        end
    end
    f:close()
    for s = 1, 8 do
        if slotNames[s] then
            presetNames[s] = slotNames[s]
            reaper.SetExtState(EXT_NAME_SECTION, "Slot"..s, presetNames[s], true)
        end
        if slotData[s] then
            reaper.SetExtState(EXT_SECTION, "Slot"..s,
                serializeTable(slotData[s]), true)
        end
    end
end

------------------------------------------------------------
-- Program Change Collection
------------------------------------------------------------

local function CollectProgramChanges(take)
    local _, _, ccevtcnt = reaper.MIDI_CountEvts(take)
    local currentBank = 0
    local events = {}
    for i = 0, ccevtcnt - 1 do
        local _, _, _, ppqpos, chanmsg, _, msg2, msg3 =
            reaper.MIDI_GetCC(take, i)
        if chanmsg == 176 and msg2 == 0 then currentBank = msg3 end
        if chanmsg == 192 then
            table.insert(events, {
                time    = reaper.MIDI_GetProjTimeFromPPQPos(take, ppqpos),
                bank    = currentBank,
                program = msg2
            })
        end
    end
    table.sort(events, function(a, b) return a.time < b.time end)
    return events
end

------------------------------------------------------------
-- Scan Item
------------------------------------------------------------

local function ScanItem()
    local item = reaper.GetSelectedMediaItem(0, 0)
    if not item then return end
    local take = reaper.GetActiveTake(item)
    if not take or not reaper.TakeIsMIDI(take) then return end
    local added = 0
    for _, ev in ipairs(CollectProgramChanges(take)) do
        local exists = false
        for _, e in ipairs(programEntries) do
            if e.bank == ev.bank and e.program == ev.program then
                exists = true; break
            end
        end
        if not exists then
            if added == 0 then pushUndo() end
            table.insert(programEntries, {
                bank=ev.bank, program=ev.program,
                name="", outtype="Marker", lane=0
            })
            added = added + 1
        end
    end
end

------------------------------------------------------------
-- Run
------------------------------------------------------------

local function Run()
    local items = {}
    for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
        local item = reaper.GetSelectedMediaItem(0, i)
        local take = reaper.GetActiveTake(item)
        if take and reaper.TakeIsMIDI(take) then
            table.insert(items, {item=item, take=take})
        end
    end
    if #items == 0 then return end
    local selStart, selEnd =
        reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    local useTS = (scopeIndex == 1) and (selEnd > selStart)
    reaper.Undo_BeginBlock()
    for _, it in ipairs(items) do
        local itemEnd = reaper.GetMediaItemInfo_Value(it.item, "D_POSITION") +
                        reaper.GetMediaItemInfo_Value(it.item, "D_LENGTH")
        local regionEnd = useTS and selEnd or itemEnd
        local named = {}
        for _, ev in ipairs(CollectProgramChanges(it.take)) do
            for _, entry in ipairs(programEntries) do
                if entry.bank == ev.bank and entry.program == ev.program
                   and entry.name ~= "" then
                    local inScope = not useTS or
                                    (ev.time >= selStart and ev.time < selEnd)
                    if inScope then
                        table.insert(named, {
                            time=ev.time, name=entry.name,
                            outtype=entry.outtype or "Marker"
                        })
                    end
                    break
                end
            end
        end
        for i, nev in ipairs(named) do
            if nev.outtype == "Marker" then
                reaper.AddProjectMarker2(0, false, nev.time, 0, nev.name, -1, 0)
            else
                local endTime = named[i+1] and named[i+1].time or regionEnd
                reaper.AddProjectMarker2(0, true, nev.time, endTime,
                    nev.name, -1, 0)
            end
        end
    end
    reaper.Undo_EndBlock("MIDI PC: Create Markers/Regions", -1)
end

------------------------------------------------------------
-- GUI
------------------------------------------------------------

function DrawGUI()

    reaper.ImGui_SetNextWindowSize(ctx, rowWidth, 680,
        reaper.ImGui_Cond_FirstUseEver())

    local visible, open = reaper.ImGui_Begin(ctx,
        "Program Change Naming", true)

    if visible then

        -- Snapshot modifier keys once per frame
        local ctrl  = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Ctrl())
        local shift = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Shift())

        -- Keyboard shortcuts (only when not typing in an input field)
        if not reaper.ImGui_IsAnyItemActive(ctx) then
            if ctrl and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Z()) then
                doUndo()
            end
            if ctrl and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Y()) then
                doRedo()
            end
        end

        reaper.ImGui_Text(ctx, "Bank + Program -> Name")
        reaper.ImGui_Separator(ctx)

        local rowToDelete = nil

        rowScreenY = {}

        for i, entry in ipairs(programEntries) do
            reaper.ImGui_PushID(ctx, i)

            local _, ry = reaper.ImGui_GetCursorScreenPos(ctx)
            rowScreenY[i] = ry

            -- Snapshot BEFORE anything mutates these
            local snapDrag = isDragging and dragSourceRow == i
            local snapSel  = selected[i] or false

            -- Push style colors using snapshots (guaranteed symmetric pop)
            if snapDrag then
                reaper.ImGui_PushStyleColor(ctx,
                    reaper.ImGui_Col_FrameBg(), 0x666666FF)
            end
            if snapSel then
                reaper.ImGui_PushStyleColor(ctx,
                    reaper.ImGui_Col_ChildBg(), 0x2255AAFF)
            end

            -- Checkbox
            local cbChanged, cbValue = reaper.ImGui_Checkbox(ctx, "##sel", snapSel)

            -- Drag detection
            if reaper.ImGui_IsItemActive(ctx) and
               reaper.ImGui_IsMouseDragging(ctx, 0, 5) and not isDragging then
                isDragging = true; dragSourceRow = i
            end

            -- Selection logic
            if cbChanged then
                local altHeld = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Alt())
                if altHeld then
                    -- ALT: exclusive select
                    for j = 1, #programEntries do selected[j] = false end
                    selected[i] = true
                elseif shift and lastSelectedRow then
                    -- SHIFT: range select, additive
                    for j = math.min(lastSelectedRow, i),
                            math.max(lastSelectedRow, i) do
                        selected[j] = true
                    end
                else
                    -- Plain click or CTRL: additive toggle
                    selected[i] = cbValue
                end
                lastSelectedRow = i
            end

            -- Pop using same snapshots
            if snapSel  then reaper.ImGui_PopStyleColor(ctx) end
            if snapDrag then reaper.ImGui_PopStyleColor(ctx) end

            reaper.ImGui_SameLine(ctx)

            -- Bank dropdown
            reaper.ImGui_Text(ctx, "Bank"); reaper.ImGui_SameLine(ctx)
            reaper.ImGui_PushItemWidth(ctx, 60)
            if reaper.ImGui_BeginCombo(ctx, "##bank", tostring(entry.bank)) then
                for b = 0, 8 do
                    if reaper.ImGui_Selectable(ctx, tostring(b), entry.bank == b)
                    then
                        pushUndo()
                        if ctrl then
                            for j, e in ipairs(programEntries) do
                                if selected[j] then e.bank = b end
                            end
                        else
                            entry.bank = b
                        end
                    end
                end
                reaper.ImGui_EndCombo(ctx)
            end
            reaper.ImGui_PopItemWidth(ctx)
            reaper.ImGui_SameLine(ctx)

            -- Program input
            reaper.ImGui_Text(ctx, "Prog"); reaper.ImGui_SameLine(ctx)
            reaper.ImGui_PushItemWidth(ctx, 60)
            if focusRequest and focusRequest.row == i and
               focusRequest.column == "program" then
                reaper.ImGui_SetKeyboardFocusHere(ctx); focusRequest = nil
            end
            local progStr = tostring(entry.program)
            local ch
            ch, progStr = reaper.ImGui_InputText(ctx, "##prog", progStr)
            if reaper.ImGui_IsItemActive(ctx) and
               reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Tab()) then
                if i == #programEntries then
                    table.insert(programEntries, newEntry())
                end
                focusRequest = {row=i+1, column="program"}
            end
            if ch then
                local n = tonumber(progStr)
                if n then entry.program = math.max(0, math.min(127, math.floor(n))) end
            end
            reaper.ImGui_PopItemWidth(ctx)
            reaper.ImGui_SameLine(ctx)

            -- Name input
            reaper.ImGui_Text(ctx, "Name"); reaper.ImGui_SameLine(ctx)
            reaper.ImGui_PushItemWidth(ctx, 150)
            if focusRequest and focusRequest.row == i and
               focusRequest.column == "name" then
                reaper.ImGui_SetKeyboardFocusHere(ctx); focusRequest = nil
            end
            ch, entry.name = reaper.ImGui_InputText(ctx, "##name", entry.name)
            if reaper.ImGui_IsItemActive(ctx) and
               reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Tab()) then
                if i == #programEntries then
                    table.insert(programEntries, newEntry())
                end
                focusRequest = {row=i+1, column="name"}
            end
            reaper.ImGui_PopItemWidth(ctx)
            reaper.ImGui_SameLine(ctx)

            -- Type dropdown
            reaper.ImGui_PushItemWidth(ctx, 70)
            local curType = entry.outtype or "Marker"
            if reaper.ImGui_BeginCombo(ctx, "##type", curType) then
                for _, t in ipairs(TYPE_OPTIONS) do
                    if reaper.ImGui_Selectable(ctx, t, curType == t) then
                        pushUndo()
                        if ctrl then
                            for j, e in ipairs(programEntries) do
                                if selected[j] then e.outtype = t end
                            end
                        else
                            entry.outtype = t
                        end
                    end
                end
                reaper.ImGui_EndCombo(ctx)
            end
            reaper.ImGui_PopItemWidth(ctx)
            reaper.ImGui_SameLine(ctx)

            -- Delete button: CTRL+X deletes all selected, plain X deletes this row
            if reaper.ImGui_Button(ctx, "X") then
                if ctrl then
                    pushUndo()
                    local ne, ns = {}, {}
                    for j, e in ipairs(programEntries) do
                        if not selected[j] then
                            table.insert(ne, e); table.insert(ns, false)
                        end
                    end
                    programEntries = ne; selected = ns; lastSelectedRow = nil
                else
                    rowToDelete = i
                end
            end

            -- Measure row width from first row
            if i == 1 then
                local rx = reaper.ImGui_GetItemRectMax(ctx)
                local wx = reaper.ImGui_GetWindowPos(ctx)
                rowWidth = math.floor(rx - wx + 18)
            end

            reaper.ImGui_PopID(ctx)
        end

        -- Drag targeting
        if isDragging then
            local my = select(2, reaper.ImGui_GetMousePos(ctx))
            dragTargetRow = #programEntries
            for j = 1, #programEntries do
                if rowScreenY[j] and my < rowScreenY[j] then
                    dragTargetRow = math.max(1, j-1); break
                end
            end
            if reaper.ImGui_IsMouseReleased(ctx, 0) then
                if dragTargetRow ~= dragSourceRow then
                    pushUndo()
                    local me = table.remove(programEntries, dragSourceRow)
                    local ms = table.remove(selected, dragSourceRow)
                    local ti = dragTargetRow
                    if dragSourceRow < dragTargetRow then ti = ti - 1 end
                    ti = math.max(1, math.min(#programEntries+1, ti))
                    table.insert(programEntries, ti, me)
                    table.insert(selected, ti, ms)
                end
                isDragging = false; dragSourceRow = nil; dragTargetRow = nil
            end
        end

        if rowToDelete then
            pushUndo()
            table.remove(programEntries, rowToDelete)
            table.remove(selected, rowToDelete)
            if lastSelectedRow == rowToDelete then lastSelectedRow = nil end
        end


        -- Add Row / Scan Item
        if reaper.ImGui_Button(ctx, "Add Row") then
            pushUndo(); table.insert(programEntries, newEntry())
        end
        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_Button(ctx, "Scan Item") then ScanItem() end

        reaper.ImGui_Separator(ctx)
        reaper.ImGui_Text(ctx, "Preset Slots")
        reaper.ImGui_Separator(ctx)

        for i = 1, 8 do
            reaper.ImGui_PushID(ctx, "slot"..i)
            reaper.ImGui_Text(ctx, "Slot "..i); reaper.ImGui_SameLine(ctx)
            reaper.ImGui_PushItemWidth(ctx, 150)
            local _, nn = reaper.ImGui_InputText(ctx, "##sn", presetNames[i])
            presetNames[i] = nn
            reaper.ImGui_PopItemWidth(ctx)
            reaper.ImGui_SameLine(ctx)
            if reaper.ImGui_Button(ctx, "Load") then LoadPreset(i) end
            reaper.ImGui_SameLine(ctx)
            if reaper.ImGui_Button(ctx, "Save") then SavePreset(i) end
            reaper.ImGui_PopID(ctx)
        end

        -- Open preset modal popup here, outside any PushID scope
        if presetModal and not reaper.ImGui_IsPopupOpen(ctx, "Preset Confirm") then
            reaper.ImGui_OpenPopup(ctx, "Preset Confirm")
        end

        reaper.ImGui_Separator(ctx)
        if reaper.ImGui_Button(ctx, "Export Presets") then ExportPresets() end
        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_Button(ctx, "Import Presets") then ImportPresets() end
        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_Button(ctx, "Export CSV") then
            exportCSVModal = true
        end

        if exportCSVModal and not reaper.ImGui_IsPopupOpen(ctx, "Export CSV") then
            reaper.ImGui_OpenPopup(ctx, "Export CSV")
        end

        -- Preset confirm modal
        if presetModal then
            local flags = reaper.ImGui_WindowFlags_AlwaysAutoResize()
            if reaper.ImGui_BeginPopupModal(ctx, "Preset Confirm", nil, flags) then
                local slot = presetModal.slot
                if presetModal.action == "save" then
                    reaper.ImGui_Text(ctx,
                        "Save current rows to \"" .. presetNames[slot] .. "\"?")
                    reaper.ImGui_Text(ctx, "This will overwrite the existing preset.")
                else
                    reaper.ImGui_Text(ctx,
                        "Load \"" .. presetNames[slot] .. "\"?")
                    reaper.ImGui_Text(ctx, "This will replace your current rows.")
                end
                reaper.ImGui_Separator(ctx)
                if reaper.ImGui_Button(ctx, "Yes") then
                    if presetModal.action == "save" then
                        DoSavePreset(slot)
                    else
                        DoLoadPreset(slot)
                    end
                    reaper.ImGui_CloseCurrentPopup(ctx)
                    presetModal = nil
                end
                reaper.ImGui_SameLine(ctx)
                if reaper.ImGui_Button(ctx, "No") then
                    reaper.ImGui_CloseCurrentPopup(ctx)
                    presetModal = nil
                end
                reaper.ImGui_EndPopup(ctx)
            end
        end

        -- Export CSV modal
        if exportCSVModal then
            local flags = reaper.ImGui_WindowFlags_AlwaysAutoResize()
            if reaper.ImGui_BeginPopupModal(ctx, "Export CSV", nil, flags) then
                reaper.ImGui_Text(ctx, "Export which rows?")
                reaper.ImGui_Separator(ctx)
                if reaper.ImGui_Button(ctx, "All") then
                    reaper.ImGui_CloseCurrentPopup(ctx)
                    exportCSVModal = false
                    ExportCSV(false)
                end
                reaper.ImGui_SameLine(ctx)
                if reaper.ImGui_Button(ctx, "Selected") then
                    reaper.ImGui_CloseCurrentPopup(ctx)
                    exportCSVModal = false
                    ExportCSV(true)
                end
                reaper.ImGui_SameLine(ctx)
                if reaper.ImGui_Button(ctx, "Cancel") then
                    reaper.ImGui_CloseCurrentPopup(ctx)
                    exportCSVModal = false
                end
                reaper.ImGui_EndPopup(ctx)
            end
        end

        reaper.ImGui_Separator(ctx)

        -- Run + Scope + Undo + Redo on one line
        if reaper.ImGui_Button(ctx, "Run") then Run() end
        reaper.ImGui_SameLine(ctx)
        reaper.ImGui_Text(ctx, "Scope:"); reaper.ImGui_SameLine(ctx)
        reaper.ImGui_PushItemWidth(ctx, 140)
        if reaper.ImGui_BeginCombo(ctx, "##scope",
            scopeOptions[scopeIndex+1]) then
            for i, lbl in ipairs(scopeOptions) do
                if reaper.ImGui_Selectable(ctx, lbl, scopeIndex == i-1) then
                    scopeIndex = i-1
                end
            end
            reaper.ImGui_EndCombo(ctx)
        end
        reaper.ImGui_PopItemWidth(ctx)
        reaper.ImGui_SameLine(ctx)

        local canUndo = #undoStack > 0
        local canRedo = #redoStack > 0
        if not canUndo then reaper.ImGui_BeginDisabled(ctx) end
        if reaper.ImGui_Button(ctx, "Undo") then doUndo() end
        if not canUndo then reaper.ImGui_EndDisabled(ctx) end
        reaper.ImGui_SameLine(ctx)
        if not canRedo then reaper.ImGui_BeginDisabled(ctx) end
        if reaper.ImGui_Button(ctx, "Redo") then doRedo() end
        if not canRedo then reaper.ImGui_EndDisabled(ctx) end


        reaper.ImGui_End(ctx)
    end  -- if visible

    if open then reaper.defer(DrawGUI) end
end

reaper.defer(DrawGUI)
