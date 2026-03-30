-- @description MIDI PCs to Markers/Regions
-- @author vazupReaperScripts
-- @version 1.0
-- @repository https://github.com/duplobaustein/vazupReaperScripts
-- @provides
--   [main] MIDI_PCs_to_Markers.lua
-- @about
--   Creates named markers or regions from MIDI Program Change events.
--   Map bank/program combinations to custom names, store up to 8 presets,
--   and apply to the whole session or the current time selection.
--   Export and import presets as CSV files for backup. 
--   A MIDI item with PCs has to be selected, when running. 
-- @changelog
--   1.0 - Initial release

local ctx = reaper.ImGui_CreateContext("Program Change Naming")

local EXT_SECTION = "PC_MarkerTool_Presets"
local EXT_NAME_SECTION = "PC_MarkerTool_PresetNames"

local programEntries = {}
local presetNames = {}
local focusRequest = nil
local scopeOptions = {"Whole Session", "Time Selection"}
local scopeIndex = 0  -- 0 = Whole Session, 1 = Time Selection

------------------------------------------------------------
-- Initialize Default Rows
------------------------------------------------------------

for i = 1, 8 do
    table.insert(programEntries, {bank = 0, program = 0, name = ""})
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
-- Serialization
------------------------------------------------------------

local function serializeTable(tbl)
    local str = ""
    for _, entry in ipairs(tbl) do
        local safeName = entry.name:gsub("[|,]", " ")
        str = str .. entry.bank .. "," .. entry.program .. "," .. safeName .. "|"
    end
    return str
end

local function deserializeTable(str)
    local newTable = {}
    for row in string.gmatch(str, "([^|]+)") do
        local bank, program, name = row:match("([^,]+),([^,]+),(.+)")
        if bank and program and name then
            table.insert(newTable, {
                bank = tonumber(bank),
                program = tonumber(program),
                name = name
            })
        end
    end
    return newTable
end

------------------------------------------------------------
-- Presets
------------------------------------------------------------

local function SavePreset(slot)
    reaper.SetExtState(EXT_SECTION, "Slot"..slot,
        serializeTable(programEntries), true)
    reaper.SetExtState(EXT_NAME_SECTION, "Slot"..slot,
        presetNames[slot], true)
end

local function LoadPreset(slot)
    local data = reaper.GetExtState(EXT_SECTION, "Slot"..slot)
    if data ~= "" then
        programEntries = deserializeTable(data)
    end
end

------------------------------------------------------------
-- Export / Import
------------------------------------------------------------

local function ExportPresets()
    -- Build CSV content
    local lines = {}
    table.insert(lines, "# MIDI PC to Markers - Preset Export")
    table.insert(lines, "# slot,preset_name,bank,program,entry_name")

    for slot = 1, 8 do
        local data = reaper.GetExtState(EXT_SECTION, "Slot"..slot)
        local slotName = reaper.GetExtState(EXT_NAME_SECTION, "Slot"..slot)
        if slotName == "" then slotName = "Preset "..slot end

        if data ~= "" then
            local entries = deserializeTable(data)
            for _, entry in ipairs(entries) do
                local safeName = entry.name:gsub(",", " ")
                local safeSlotName = slotName:gsub(",", " ")
                table.insert(lines,
                    slot .. "," .. safeSlotName .. "," ..
                    entry.bank .. "," .. entry.program .. "," .. safeName)
            end
        else
            -- Write a placeholder so the slot/name is preserved
            table.insert(lines,
                slot .. "," .. slotName:gsub(",", " ") .. ",,,")
        end
    end

    local csv = table.concat(lines, "\n")

    -- Try JS file dialog first, fall back to resource path
    local savePath
    if reaper.JS_Dialog_BrowseForSaveFile then
        local retval, path = reaper.JS_Dialog_BrowseForSaveFile(
            "Export Presets", reaper.GetResourcePath(), 
            "MIDI_PC_Presets.csv", "CSV Files (.csv)\0*.csv\0All Files\0*.*\0")
        if retval and path ~= "" then
            savePath = path
            if not savePath:match("%.csv$") then
                savePath = savePath .. ".csv"
            end
        end
    else
        savePath = reaper.GetResourcePath() ..
                   "/Scripts/MIDI_PC_Presets.csv"
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

    -- Parse CSV into slot buckets
    local slotData   = {}  -- slot -> list of entries
    local slotNames  = {}  -- slot -> name

    for line in f:lines() do
        if not line:match("^#") and line ~= "" then
            local slot, slotName, bank, program, entryName =
                line:match("^(%d+),([^,]*),([^,]*),([^,]*),?(.*)")

            if slot then
                local s = tonumber(slot)
                if s and s >= 1 and s <= 8 then
                    slotNames[s] = slotName ~= "" and slotName
                                   or ("Preset " .. s)

                    if bank ~= "" and program ~= "" then
                        if not slotData[s] then slotData[s] = {} end
                        table.insert(slotData[s], {
                            bank    = tonumber(bank)    or 0,
                            program = tonumber(program) or 0,
                            name    = entryName or ""
                        })
                    end
                end
            end
        end
    end
    f:close()

    -- Persist imported slots
    for s = 1, 8 do
        if slotNames[s] then
            presetNames[s] = slotNames[s]
            reaper.SetExtState(EXT_NAME_SECTION, "Slot"..s,
                presetNames[s], true)
        end
        if slotData[s] then
            local serialized = serializeTable(slotData[s])
            reaper.SetExtState(EXT_SECTION, "Slot"..s,
                serialized, true)
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
                time = projTime,
                bank = currentBank,
                program = msg2
            })
        end
    end

    table.sort(events, function(a,b) return a.time < b.time end)
    return events
end

local function ResolveName(bank, program)
    for _, entry in ipairs(programEntries) do
        if entry.bank == bank and
           entry.program == program and
           entry.name ~= "" then
            return entry.name
        end
    end
    return nil
end

------------------------------------------------------------
-- Marker Creation
------------------------------------------------------------

local function CreateMarkers()
    local item = reaper.GetSelectedMediaItem(0, 0)
    if not item then return end
    local take = reaper.GetActiveTake(item)
    if not take or not reaper.TakeIsMIDI(take) then return end

    reaper.Undo_BeginBlock()
    local events = CollectProgramChanges(take)

    local selStart, selEnd = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    local useTimeSelection = (scopeIndex == 1) and (selEnd > selStart)

    for _, ev in ipairs(events) do
        local name = ResolveName(ev.bank, ev.program)
        if name then
            if not useTimeSelection or
               (ev.time >= selStart and ev.time < selEnd) then
                reaper.AddProjectMarker2(0, false, ev.time, 0,
                    name, -1, 0)
            end
        end
    end

    reaper.Undo_EndBlock("Create Named Program Change Markers", -1)
end

------------------------------------------------------------
-- Region Creation
------------------------------------------------------------

local function CreateRegions()
    local item = reaper.GetSelectedMediaItem(0, 0)
    if not item then return end
    local take = reaper.GetActiveTake(item)
    if not take or not reaper.TakeIsMIDI(take) then return end

    local itemEnd = reaper.GetMediaItemInfo_Value(item, "D_POSITION") +
                    reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

    reaper.Undo_BeginBlock()

    local events = CollectProgramChanges(take)

    local selStart, selEnd = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    local useTimeSelection = (scopeIndex == 1) and (selEnd > selStart)

    -- Build list of named events only
    local named = {}
    for _, ev in ipairs(events) do
        local name = ResolveName(ev.bank, ev.program)
        if name then
            if not useTimeSelection or
               (ev.time >= selStart and ev.time < selEnd) then
                table.insert(named, {
                    time = ev.time,
                    name = name
                })
            end
        end
    end

    -- Clamp region end to time selection end if applicable
    local regionEnd = useTimeSelection and selEnd or itemEnd

    -- Create regions using only named events
    for i = 1, #named do
        local startTime = named[i].time
        local endTime = named[i+1] and named[i+1].time or regionEnd

        reaper.AddProjectMarker2(0, true,
            startTime, endTime,
            named[i].name, -1, 0)
    end

    reaper.Undo_EndBlock("Create Named Program Change Regions", -1)
end

------------------------------------------------------------
-- GUI
------------------------------------------------------------

function DrawGUI()

    reaper.ImGui_SetNextWindowSize(ctx, 650, 680,
        reaper.ImGui_Cond_FirstUseEver())

    local visible, open = reaper.ImGui_Begin(ctx,
        "Program Change Naming", true)

    if visible then

        reaper.ImGui_Text(ctx, "Bank + Program → Name")
        reaper.ImGui_Separator(ctx)

        local rowToDelete = nil

        for i, entry in ipairs(programEntries) do
            reaper.ImGui_PushID(ctx, i)

            -- Bank
            reaper.ImGui_Text(ctx, "Bank")
            reaper.ImGui_SameLine(ctx)
            reaper.ImGui_PushItemWidth(ctx, 60)
            if reaper.ImGui_BeginCombo(ctx, "##bank", tostring(entry.bank)) then
                for b = 0, 8 do
                    if reaper.ImGui_Selectable(ctx, tostring(b),
                        entry.bank == b) then
                        entry.bank = b
                    end
                end
                reaper.ImGui_EndCombo(ctx)
            end
            reaper.ImGui_PopItemWidth(ctx)

            reaper.ImGui_SameLine(ctx)

            -- Program
            reaper.ImGui_Text(ctx, "Program")
            reaper.ImGui_SameLine(ctx)
            reaper.ImGui_PushItemWidth(ctx, 90)

            if focusRequest and
               focusRequest.row == i and
               focusRequest.column == "program" then
                reaper.ImGui_SetKeyboardFocusHere(ctx)
                focusRequest = nil
            end

            local programStr = tostring(entry.program)
            local changed
            changed, programStr =
                reaper.ImGui_InputText(ctx, "##program", programStr)

            if reaper.ImGui_IsItemActive(ctx) and
               reaper.ImGui_IsKeyPressed(ctx,
               reaper.ImGui_Key_Tab()) then

                if i == #programEntries then
                    table.insert(programEntries,
                        {bank=0, program=0, name=""})
                    focusRequest =
                        {row = #programEntries, column="program"}
                else
                    focusRequest =
                        {row = i+1, column="program"}
                end
            end

            if changed then
                local num = tonumber(programStr)
                if num then
                    if num < 0 then num = 0 end
                    if num > 127 then num = 127 end
                    entry.program = math.floor(num)
                end
            end

            reaper.ImGui_PopItemWidth(ctx)
            reaper.ImGui_SameLine(ctx)

            -- Name
            reaper.ImGui_Text(ctx, "Name")
            reaper.ImGui_SameLine(ctx)
            reaper.ImGui_PushItemWidth(ctx, 180)

            if focusRequest and
               focusRequest.row == i and
               focusRequest.column == "name" then
                reaper.ImGui_SetKeyboardFocusHere(ctx)
                focusRequest = nil
            end

            changed, entry.name =
                reaper.ImGui_InputText(ctx, "##name", entry.name)

            if reaper.ImGui_IsItemActive(ctx) and
               reaper.ImGui_IsKeyPressed(ctx,
               reaper.ImGui_Key_Tab()) then

                if i == #programEntries then
                    table.insert(programEntries,
                        {bank=0, program=0, name=""})
                    focusRequest =
                        {row = #programEntries, column="name"}
                else
                    focusRequest =
                        {row = i+1, column="name"}
                end
            end

            reaper.ImGui_PopItemWidth(ctx)
            reaper.ImGui_SameLine(ctx)

            if reaper.ImGui_Button(ctx, "X") then
                rowToDelete = i
            end

            reaper.ImGui_PopID(ctx)
        end

        if rowToDelete then
            table.remove(programEntries, rowToDelete)
        end

        if reaper.ImGui_Button(ctx, "Add Row") then
            table.insert(programEntries,
                {bank = 0, program = 0, name = ""})
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
                reaper.ImGui_InputText(ctx,
                "##name", presetNames[i])
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

        reaper.ImGui_Text(ctx, "Scope:")
        reaper.ImGui_SameLine(ctx)
        reaper.ImGui_PushItemWidth(ctx, 160)
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

        reaper.ImGui_SameLine(ctx)

        if reaper.ImGui_Button(ctx, "Export Presets") then
            ExportPresets()
        end

        reaper.ImGui_SameLine(ctx)

        if reaper.ImGui_Button(ctx, "Import Presets") then
            ImportPresets()
        end

        reaper.ImGui_Separator(ctx)

        if reaper.ImGui_Button(ctx, "Create Markers") then
            CreateMarkers()
        end

        reaper.ImGui_SameLine(ctx)

        if reaper.ImGui_Button(ctx, "Create Regions") then
            CreateRegions()
        end

        reaper.ImGui_SameLine(ctx)

        if reaper.ImGui_Button(ctx, "Close") then
            open = false
        end

        reaper.ImGui_End(ctx)
    end

    -- Updated safe close for latest ReaImGui
    if open then
        reaper.defer(DrawGUI)
    end
end

reaper.defer(DrawGUI)
