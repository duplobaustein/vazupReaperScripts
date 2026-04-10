-- @description MIDI Program Change Marker/Region Creator
-- @author vazupReaperScripts
-- @version 1.10
-- @repository https://github.com/duplobaustein/vazupReaperScripts
-- @provides
--   MIDI_PC_to_Markers.lua
-- @about
--   Creates named markers or regions from MIDI Program Change events.
--   Map bank/program combinations to custom names, store up to 8 presets,
--   and apply to the whole session or the current time selection.
--   Export and import presets as CSV files.
-- @changelog
--   1.10 - Added checkboxes, Marker/Region selection and total process overhaul.
--   1.00 - Initial release

local ctx = reaper.ImGui_CreateContext("Program Change Naming")

local EXT_SECTION      = "PC_MarkerTool_Presets"
local EXT_NAME_SECTION = "PC_MarkerTool_PresetNames"

local programEntries  = {}
local presetNames     = {}
local focusRequest    = nil
local scopeOptions    = {"Whole Session", "Time Selection"}
local scopeIndex      = 0
local footerHeight    = 300
local rowWidth        = 540

-- Selection state
local selected        = {}
local lastSelectedRow = nil

-- Drag reorder state
local isDragging      = false
local dragSourceRow   = nil
local dragTargetRow   = nil
local rowScreenY      = {}

-- Undo / Redo stacks
local undoStack = {}
local redoStack = {}

local TYPE_OPTIONS = {"Marker", "Region"}

------------------------------------------------------------
-- Entry constructor
------------------------------------------------------------

local function newEntry()
    return {bank=0, program=0, name="", outtype="Marker", lane=0}
end

------------------------------------------------------------
-- Initialize Default Rows
------------------------------------------------------------

for i = 1, 8 do
    table.insert(programEntries, newEntry())
end

------------------------------------------------------------
-- Load Preset Names
------------------------------------------------------------

for i = 1, 8 do
    local name = reaper.GetExtState(EXT_NAME_SECTION, "Slot"..i)
    if name == "" then name = "Preset "..i end
    presetNames[i] = name
end

------------------------------------------------------------
-- Undo / Redo
------------------------------------------------------------

local function deepCopyEntries(tbl)
    local copy = {}
    for _, e in ipairs(tbl) do
        table.insert(copy, {
            bank    = e.bank,
            program = e.program,
            name    = e.name,
            outtype = e.outtype or "Marker",
            lane    = e.lane    or 0
        })
    end
    return copy
end

local function pushUndo()
    table.insert(undoStack, deepCopyEntries(programEntries))
    redoStack = {}
    if #undoStack > 50 then table.remove(undoStack, 1) end
end

local function doUndo()
    if #undoStack == 0 then return end
    table.insert(redoStack, deepCopyEntries(programEntries))
    programEntries = table.remove(undoStack)
    selected = {}
    lastSelectedRow = nil
end

local function doRedo()
    if #redoStack == 0 then return end
    table.insert(undoStack, deepCopyEntries(programEntries))
    programEntries = table.remove(redoStack)
    selected = {}
    lastSelectedRow = nil
end

------------------------------------------------------------
-- Serialization
------------------------------------------------------------

local function serializeTable(tbl)
    local str = ""
    for _, entry in ipairs(tbl) do
        local safeName = entry.name:gsub("[|,]", " ")
        local t = (entry.outtype == "Region") and "R" or "M"
        local l = tostring(entry.lane or 0)
        str = str .. entry.bank .. "," .. entry.program .. "," ..
              safeName .. "," .. t .. "," .. l .. "|"
    end
    return str
end

local function deserializeTable(str)
    local newTable = {}
    for row in string.gmatch(str, "([^|]+)") do
        local parts = {}
        for p in (row .. ","):gmatch("([^,]*),") do
            table.insert(parts, p)
        end
        local bank    = tonumber(parts[1])
        local program = tonumber(parts[2])
        if bank and program then
            local name    = parts[3] or ""
            local outtype = (parts[4] == "R") and "Region" or "Marker"
            local lane    = tonumber(parts[5]) or 0
            table.insert(newTable, {
                bank    = bank,
                program = program,
                name    = name,
                outtype = outtype,
                lane    = lane
            })
        end
    end
    return newTable
end

------------------------------------------------------------
-- Presets
------------------------------------------------------------

local function SavePreset(slot)
    local confirm = reaper.MB(
        "Save current entries to \"" .. presetNames[slot] .. "\"?\n" ..
        "This will overwrite the existing preset.",
        "Save Preset", 4)
    if confirm ~= 6 then return end

    reaper.SetExtState(EXT_SECTION, "Slot"..slot,
        serializeTable(programEntries), true)
    reaper.SetExtState(EXT_NAME_SECTION, "Slot"..slot,
        presetNames[slot], true)
end

local function LoadPreset(slot)
    local confirm = reaper.MB(
        "Load \"" .. presetNames[slot] .. "\"?\n" ..
        "This will replace your current entries.",
        "Load Preset", 4)
    if confirm ~= 6 then return end

    local data = reaper.GetExtState(EXT_SECTION, "Slot"..slot)
    if data ~= "" then
        pushUndo()
        programEntries = deserializeTable(data)
        selected = {}
        lastSelectedRow = nil
    end
end

------------------------------------------------------------
-- Export / Import
------------------------------------------------------------

local function ExportPresets()
    local lines = {}
    table.insert(lines, "# MIDI PC to Markers - Preset Export")
    table.insert(lines, "# slot,preset_name,bank,program,entry_name,type,lane")

    for slot = 1, 8 do
        local data     = reaper.GetExtState(EXT_SECTION, "Slot"..slot)
        local slotName = reaper.GetExtState(EXT_NAME_SECTION, "Slot"..slot)
        if slotName == "" then slotName = "Preset "..slot end

        if data ~= "" then
            local entries = deserializeTable(data)
            for _, entry in ipairs(entries) do
                local safeName     = entry.name:gsub(",", " ")
                local safeSlotName = slotName:gsub(",", " ")
                local t = (entry.outtype == "Region") and "R" or "M"
                table.insert(lines,
                    slot .. "," .. safeSlotName .. "," ..
                    entry.bank .. "," .. entry.program .. "," ..
                    safeName .. "," .. t .. "," .. (entry.lane or 0))
            end
        else
            table.insert(lines,
                slot .. "," .. slotName:gsub(",", " ") .. ",,,,M,0")
        end
    end

    local csv = table.concat(lines, "\n")
    local savePath

    if reaper.JS_Dialog_BrowseForSaveFile then
        local retval, path = reaper.JS_Dialog_BrowseForSaveFile(
            "Export Presets", reaper.GetResourcePath(),
            "MIDI_PC_Presets.csv",
            "CSV Files (.csv)\0*.csv\0All Files\0*.*\0")
        if retval and path ~= "" then
            savePath = path
            if not savePath:match("%.csv$") then savePath = savePath .. ".csv" end
        end
    else
        savePath = reaper.GetResourcePath() .. "/Scripts/MIDI_PC_Presets.csv"
    end

    if not savePath then return end

    local f = io.open(savePath, "w")
    if f then
        f:write(csv)
        f:close()
        reaper.MB("Presets exported to:\n" .. savePath, "Export OK", 0)
    else
        reaper.MB("Could not write file:\n" .. savePath, "Export Error", 0)
    end
end

local function ImportPresets()
    local retval, path = reaper.GetUserFileNameForRead(
        reaper.GetResourcePath() .. "/Scripts",
        "Import Presets CSV", "csv")

    if not retval or path == "" then return end

    local f = io.open(path, "r")
    if not f then
        reaper.MB("Could not open file:\n" .. path, "Import Error", 0)
        return
    end

    local slotData  = {}
    local slotNames = {}

    for line in f:lines() do
        if not line:match("^#") and line ~= "" then
            local parts = {}
            for p in (line .. ","):gmatch("([^,]*),") do
                table.insert(parts, p)
            end
            local s = tonumber(parts[1])
            if s and s >= 1 and s <= 8 then
                slotNames[s] = (parts[2] and parts[2] ~= "") and parts[2]
                               or ("Preset "..s)
                if parts[3] and parts[3] ~= "" and parts[4] and parts[4] ~= "" then
                    if not slotData[s] then slotData[s] = {} end
                    local t = (parts[6] == "R") and "Region" or "Marker"
                    table.insert(slotData[s], {
                        bank    = tonumber(parts[3]) or 0,
                        program = tonumber(parts[4]) or 0,
                        name    = parts[5] or "",
                        outtype = t,
                        lane    = tonumber(parts[7]) or 0
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

    reaper.MB("Presets imported successfully!", "Import OK", 0)
end

------------------------------------------------------------
-- Program Change Collection
------------------------------------------------------------

local function CollectProgramChanges(take)
    local _, _, ccevtcnt, _ = reaper.MIDI_CountEvts(take)
    local currentBank = 0
    local events = {}

    for i = 0, ccevtcnt - 1 do
        local _, _, _, ppqpos, chanmsg, _, msg2, msg3 =
            reaper.MIDI_GetCC(take, i)

        if chanmsg == 176 and msg2 == 0 then
            currentBank = msg3
        end

        if chanmsg == 192 then
            local projTime = reaper.MIDI_GetProjTimeFromPPQPos(take, ppqpos)
            table.insert(events, {
                time    = projTime,
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
    if not item then
        reaper.MB("No MIDI item selected.", "Scan Item", 0)
        return
    end
    local take = reaper.GetActiveTake(item)
    if not take or not reaper.TakeIsMIDI(take) then
        reaper.MB("Selected item is not a MIDI item.", "Scan Item", 0)
        return
    end

    local events = CollectProgramChanges(take)
    local added  = 0

    for _, ev in ipairs(events) do
        local exists = false
        for _, entry in ipairs(programEntries) do
            if entry.bank == ev.bank and entry.program == ev.program then
                exists = true
                break
            end
        end
        if not exists then
            pushUndo()
            table.insert(programEntries, {
                bank    = ev.bank,
                program = ev.program,
                name    = "",
                outtype = "Marker",
                lane    = 0
            })
            added = added + 1
        end
    end

    if added == 0 then
        reaper.MB("No new program changes found.", "Scan Item", 0)
    end
end

------------------------------------------------------------
-- Run
------------------------------------------------------------

local function Run()
    -- Collect all selected MIDI items
    local items = {}
    for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
        local item = reaper.GetSelectedMediaItem(0, i)
        local take = reaper.GetActiveTake(item)
        if take and reaper.TakeIsMIDI(take) then
            table.insert(items, {item = item, take = take})
        end
    end

    if #items == 0 then
        reaper.MB("No MIDI item selected.", "Run", 0)
        return
    end

    local selStart, selEnd =
        reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    local useTimeSelection = (scopeIndex == 1) and (selEnd > selStart)

    reaper.Undo_BeginBlock()

    for _, it in ipairs(items) do
        local itemEnd = reaper.GetMediaItemInfo_Value(it.item, "D_POSITION") +
                        reaper.GetMediaItemInfo_Value(it.item, "D_LENGTH")
        local regionEnd = useTimeSelection and selEnd or itemEnd
        local events    = CollectProgramChanges(it.take)

        -- Build ordered list of named events with row settings
        local namedEvents = {}
        for _, ev in ipairs(events) do
            for _, entry in ipairs(programEntries) do
                if entry.bank    == ev.bank and
                   entry.program == ev.program and
                   entry.name    ~= "" then
                    local inScope = not useTimeSelection or
                                    (ev.time >= selStart and ev.time < selEnd)
                    if inScope then
                        table.insert(namedEvents, {
                            time    = ev.time,
                            name    = entry.name,
                            outtype = entry.outtype or "Marker",
                            -- lane stored but not yet applied:
                            -- REAPER API does not currently expose lane
                            -- placement for markers/regions via Lua.
                            lane    = entry.lane or 0
                        })
                    end
                    break
                end
            end
        end

        for i, nev in ipairs(namedEvents) do
            if nev.outtype == "Marker" then
                reaper.AddProjectMarker2(0, false, nev.time, 0,
                    nev.name, -1, 0)
            else
                local endTime = namedEvents[i+1] and
                                namedEvents[i+1].time or regionEnd
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

    reaper.ImGui_SetNextWindowSizeConstraints(ctx, rowWidth, 200, rowWidth, 9999)
    reaper.ImGui_SetNextWindowSize(ctx, rowWidth, 680,
        reaper.ImGui_Cond_FirstUseEver())

    local visible, open = reaper.ImGui_Begin(ctx,
        "Program Change Naming", true)

    if visible then

        local ctrlHeld  = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Key_ModCtrl())
        local shiftHeld = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Key_ModShift())

        -- CTRL+X: delete selected rows
        if ctrlHeld and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_X()) then
            local count = 0
            for i = 1, #programEntries do
                if selected[i] then count = count + 1 end
            end
            if count > 0 then
                local confirm = reaper.MB(
                    "Delete " .. count .. " selected row(s)?",
                    "Delete Selected", 4)
                if confirm == 6 then
                    pushUndo()
                    local newEntries  = {}
                    local newSelected = {}
                    for i, entry in ipairs(programEntries) do
                        if not selected[i] then
                            table.insert(newEntries,  entry)
                            table.insert(newSelected, false)
                        end
                    end
                    programEntries  = newEntries
                    selected        = newSelected
                    lastSelectedRow = nil
                end
            end
        end

        -- CTRL+Z / CTRL+Y: undo/redo
        if ctrlHeld and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Z()) then
            doUndo()
        end
        if ctrlHeld and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Y()) then
            doRedo()
        end

        reaper.ImGui_Text(ctx, "Bank + Program → Name")
        reaper.ImGui_Separator(ctx)

        local rowToDelete = nil

        -- Child fills everything except footer
        local availH = select(2, reaper.ImGui_GetContentRegionAvail(ctx))
        reaper.ImGui_BeginChild(ctx, "##rows", 0, availH - footerHeight,
            reaper.ImGui_ChildFlags_Borders())

        rowScreenY = {}

        for i, entry in ipairs(programEntries) do
            reaper.ImGui_PushID(ctx, i)

            -- Store screen Y for drag targeting
            local _, ry = reaper.ImGui_GetCursorScreenPos(ctx)
            rowScreenY[i] = ry

            -- Highlight row being dragged
            if isDragging and dragSourceRow == i then
                reaper.ImGui_PushStyleColor(ctx,
                    reaper.ImGui_Col_FrameBg(), 0x666666FF)
            end

            -- Highlight selected rows
            if selected[i] then
                reaper.ImGui_PushStyleColor(ctx,
                    reaper.ImGui_Col_ChildBg(), 0x2255AAFF)
            end

            -- Checkbox
            local isSelected = selected[i] or false
            local cbChanged, _ = reaper.ImGui_Checkbox(ctx, "##sel", isSelected)

            -- Detect drag from checkbox
            if reaper.ImGui_IsItemActive(ctx) and
               reaper.ImGui_IsMouseDragging(ctx, 0, 5) then
                if not isDragging then
                    isDragging    = true
                    dragSourceRow = i
                end
            end

            -- Handle selection (skip if this item started the drag)
            if cbChanged and not (isDragging and dragSourceRow == i) then
                if ctrlHeld then
                    selected[i] = not isSelected
                elseif shiftHeld and lastSelectedRow then
                    local from = math.min(lastSelectedRow, i)
                    local to   = math.max(lastSelectedRow, i)
                    for j = from, to do selected[j] = true end
                else
                    -- Exclusive select (plain click or ALT)
                    for j = 1, #programEntries do selected[j] = false end
                    selected[i] = true
                end
                lastSelectedRow = i
            end

            if isDragging and dragSourceRow == i then
                reaper.ImGui_PopStyleColor(ctx)
            end
            if selected[i] then
                reaper.ImGui_PopStyleColor(ctx)
            end

            reaper.ImGui_SameLine(ctx)

            -- Bank
            reaper.ImGui_Text(ctx, "Bank")
            reaper.ImGui_SameLine(ctx)
            reaper.ImGui_PushItemWidth(ctx, 60)
            if reaper.ImGui_BeginCombo(ctx, "##bank", tostring(entry.bank)) then
                for b = 0, 8 do
                    if reaper.ImGui_Selectable(ctx, tostring(b),
                        entry.bank == b) then
                        if entry.bank ~= b then
                            pushUndo()
                            if ctrlHeld then
                                for j, e in ipairs(programEntries) do
                                    if selected[j] then e.bank = b end
                                end
                            else
                                entry.bank = b
                            end
                        end
                    end
                end
                reaper.ImGui_EndCombo(ctx)
            end
            reaper.ImGui_PopItemWidth(ctx)

            reaper.ImGui_SameLine(ctx)

            -- Program
            reaper.ImGui_Text(ctx, "Prog")
            reaper.ImGui_SameLine(ctx)
            reaper.ImGui_PushItemWidth(ctx, 60)

            if focusRequest and focusRequest.row == i and
               focusRequest.column == "program" then
                reaper.ImGui_SetKeyboardFocusHere(ctx)
                focusRequest = nil
            end

            local programStr = tostring(entry.program)
            local changed
            changed, programStr =
                reaper.ImGui_InputText(ctx, "##program", programStr)

            if reaper.ImGui_IsItemActive(ctx) and
               reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Tab()) then
                if i == #programEntries then
                    table.insert(programEntries, newEntry())
                    focusRequest = {row=#programEntries, column="program"}
                else
                    focusRequest = {row=i+1, column="program"}
                end
            end

            if changed then
                local num = tonumber(programStr)
                if num then
                    entry.program = math.max(0, math.min(127, math.floor(num)))
                end
            end

            reaper.ImGui_PopItemWidth(ctx)
            reaper.ImGui_SameLine(ctx)

            -- Name
            reaper.ImGui_Text(ctx, "Name")
            reaper.ImGui_SameLine(ctx)
            reaper.ImGui_PushItemWidth(ctx, 150)

            if focusRequest and focusRequest.row == i and
               focusRequest.column == "name" then
                reaper.ImGui_SetKeyboardFocusHere(ctx)
                focusRequest = nil
            end

            changed, entry.name =
                reaper.ImGui_InputText(ctx, "##name", entry.name)

            if reaper.ImGui_IsItemActive(ctx) and
               reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Tab()) then
                if i == #programEntries then
                    table.insert(programEntries, newEntry())
                    focusRequest = {row=#programEntries, column="name"}
                else
                    focusRequest = {row=i+1, column="name"}
                end
            end

            reaper.ImGui_PopItemWidth(ctx)
            reaper.ImGui_SameLine(ctx)

            -- Type dropdown (Marker / Region)
            reaper.ImGui_PushItemWidth(ctx, 70)
            local curType = entry.outtype or "Marker"
            if reaper.ImGui_BeginCombo(ctx, "##type", curType) then
                for _, t in ipairs(TYPE_OPTIONS) do
                    if reaper.ImGui_Selectable(ctx, t, curType == t) then
                        if curType ~= t then
                            pushUndo()
                            if ctrlHeld then
                                for j, e in ipairs(programEntries) do
                                    if selected[j] then e.outtype = t end
                                end
                            else
                                entry.outtype = t
                            end
                        end
                    end
                end
                reaper.ImGui_EndCombo(ctx)
            end
            reaper.ImGui_PopItemWidth(ctx)
            reaper.ImGui_SameLine(ctx)

            -- Delete button
            if reaper.ImGui_Button(ctx, "X") then
                rowToDelete = i
            end

            -- Measure row width from first row (screen coords)
            if i == 1 then
                local itemR = reaper.ImGui_GetItemRectMax(ctx)
                local winX  = reaper.ImGui_GetWindowPos(ctx)
                rowWidth = math.floor(itemR - winX + 8 + 1 + 8 + 16)
            end

            reaper.ImGui_PopID(ctx)
        end

        -- Update drag target row based on mouse screen Y
        if isDragging then
            local mouseY = select(2, reaper.ImGui_GetMousePos(ctx))
            dragTargetRow = #programEntries
            for j = 1, #programEntries do
                if rowScreenY[j] and mouseY < rowScreenY[j] then
                    dragTargetRow = math.max(1, j - 1)
                    break
                end
            end
        end

        -- Handle drag release: reorder rows
        if isDragging and reaper.ImGui_IsMouseReleased(ctx, 0) then
            if dragTargetRow and dragTargetRow ~= dragSourceRow then
                pushUndo()
                local movedEntry = table.remove(programEntries, dragSourceRow)
                local movedSel   = selected[dragSourceRow]
                table.remove(selected, dragSourceRow)
                local targetIdx = dragTargetRow
                if dragSourceRow < dragTargetRow then
                    targetIdx = targetIdx - 1
                end
                targetIdx = math.max(1, math.min(#programEntries + 1, targetIdx))
                table.insert(programEntries, targetIdx, movedEntry)
                table.insert(selected,       targetIdx, movedSel)
            end
            isDragging    = false
            dragSourceRow = nil
            dragTargetRow = nil
        end

        reaper.ImGui_EndChild(ctx)

        -- Row delete confirmation (outside child)
        if rowToDelete then
            local confirm = reaper.MB(
                "Delete this row?", "Delete Row", 4)
            if confirm == 6 then
                pushUndo()
                table.remove(programEntries, rowToDelete)
                table.remove(selected,       rowToDelete)
                if lastSelectedRow == rowToDelete then
                    lastSelectedRow = nil
                end
            end
        end

        -- Begin footer measurement
        local _, footerStartY = reaper.ImGui_GetCursorPos(ctx)

        if reaper.ImGui_Button(ctx, "Add Row") then
            pushUndo()
            table.insert(programEntries, newEntry())
        end

        reaper.ImGui_SameLine(ctx)

        if reaper.ImGui_Button(ctx, "Scan Item") then
            ScanItem()
        end

        reaper.ImGui_Separator(ctx)

        reaper.ImGui_Text(ctx, "Preset Slots")
        reaper.ImGui_Separator(ctx)

        for i = 1, 8 do
            reaper.ImGui_PushID(ctx, "slot"..i)

            reaper.ImGui_Text(ctx, "Slot "..i)
            reaper.ImGui_SameLine(ctx)

            reaper.ImGui_PushItemWidth(ctx, 150)
            local changed
            changed, presetNames[i] =
                reaper.ImGui_InputText(ctx, "##slotname", presetNames[i])
            reaper.ImGui_PopItemWidth(ctx)

            reaper.ImGui_SameLine(ctx)

            if reaper.ImGui_Button(ctx, "Load") then
                LoadPreset(i)
            end

            reaper.ImGui_SameLine(ctx)

            if reaper.ImGui_Button(ctx, "Save") then
                SavePreset(i)
            end

            reaper.ImGui_PopID(ctx)
        end

        reaper.ImGui_Separator(ctx)

        if reaper.ImGui_Button(ctx, "Export Presets") then
            ExportPresets()
        end

        reaper.ImGui_SameLine(ctx)

        if reaper.ImGui_Button(ctx, "Import Presets") then
            ImportPresets()
        end

        reaper.ImGui_Separator(ctx)

        -- Bottom action row: Run | Scope: [dropdown] ... Undo | Redo
        if reaper.ImGui_Button(ctx, "Run") then
            Run()
        end

        reaper.ImGui_SameLine(ctx)
        reaper.ImGui_Text(ctx, "Scope:")
        reaper.ImGui_SameLine(ctx)
        reaper.ImGui_PushItemWidth(ctx, 140)
        if reaper.ImGui_BeginCombo(ctx, "##scope",
            scopeOptions[scopeIndex + 1]) then
            for i, label in ipairs(scopeOptions) do
                if reaper.ImGui_Selectable(ctx, label,
                    scopeIndex == i - 1) then
                    scopeIndex = i - 1
                end
            end
            reaper.ImGui_EndCombo(ctx)
        end
        reaper.ImGui_PopItemWidth(ctx)

        -- Undo / Redo right-aligned
        local undoW  = select(1, reaper.ImGui_CalcTextSize(ctx, "Undo")) + 16
        local redoW  = select(1, reaper.ImGui_CalcTextSize(ctx, "Redo")) + 16
        local rightX = reaper.ImGui_GetWindowWidth(ctx) - undoW - redoW - 16

        reaper.ImGui_SameLine(ctx)
        reaper.ImGui_SetCursorPosX(ctx, rightX)

        local canUndo = #undoStack > 0
        local canRedo = #redoStack > 0

        if not canUndo and reaper.ImGui_BeginDisabled then
            reaper.ImGui_BeginDisabled(ctx)
        end
        if reaper.ImGui_Button(ctx, "Undo") then doUndo() end
        if not canUndo and reaper.ImGui_EndDisabled then
            reaper.ImGui_EndDisabled(ctx)
        end

        reaper.ImGui_SameLine(ctx)

        if not canRedo and reaper.ImGui_BeginDisabled then
            reaper.ImGui_BeginDisabled(ctx)
        end
        if reaper.ImGui_Button(ctx, "Redo") then doRedo() end
        if not canRedo and reaper.ImGui_EndDisabled then
            reaper.ImGui_EndDisabled(ctx)
        end

        -- Update footer measurement for next frame
        local _, footerEndY = reaper.ImGui_GetCursorPos(ctx)
        footerHeight = footerEndY - footerStartY + 8

        reaper.ImGui_End(ctx)
    end

    if open then
        reaper.defer(DrawGUI)
    end
end

reaper.defer(DrawGUI)
