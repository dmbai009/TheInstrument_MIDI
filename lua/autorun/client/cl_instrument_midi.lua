-- ============================================================================
-- The Instrument MIDI Chooser by dmbai
-- ============================================================================
if SERVER then return end

local MIDI_Core = include("the_instrument_midi/midi_core.lua")

file.CreateDir("the_instrument_midi")

local MIDI_CHUNK_SIZE   = 24000
local MIDI_MAX_CHUNKS   = 24
local MIDI_JOIN_TIMEOUT = 20

local MIDI_CHUNK_DELAY  = 0.2
local MIDI_SCAN_INTERVAL = 0.25
local MIDI_FRAME_BUDGET = 16
local MIDI_EVENT_SCAN_BUDGET = 512
local MIDI_DROP_WARN_AT = 96
local MIDI_DROP_WARN_COOLDOWN = 20

local MIDI_MAX_FILE_BYTES = 4 * 1024 * 1024
local MIDI_MAX_NOTES      = 200000
local MIDI_MAX_DURATION   = 86400
local MIDI_MAX_DECOMPRESSED_BYTES = 16 * 1024 * 1024

local cvNoteRate = CreateClientConVar("theinstrument_midi_note_rate", "80", true, false,
    "Maximum MIDI notes per second this client emits.")

TheInstrument_MIDI_Panels = TheInstrument_MIDI_Panels or {}
do
    local p = TheInstrument_MIDI_Panels
    if IsValid(p.hudButton) then p.hudButton:Remove() end
    if IsValid(p.joinButton) then p.joinButton:Remove() end
    if IsValid(p.menuFrame) then p.menuFrame:Remove() end
    p.hudButton, p.joinButton, p.menuFrame = nil, nil, nil
end

local activeMenuFrame = nil
local activeSpeedSlider = nil
local activeTimeBar = nil
local activeLoopCheck = nil
local activeStatusLabel = nil
local activeBtnStop = nil
local activeBtnPause = nil
local activeBtnPlay = nil

local hudButton = nil
local joinButton = nil

local suppressedWep = nil
local suppressedWasEnabled = false
local pendingJoin = nil

local INST_CLASS = "weapon_the_instrument"
local CTRL_CLASS = "weapon_the_instrument_controller"

local function HasInstrument()
    local ply = LocalPlayer()
    if not IsValid(ply) or not ply:Alive() then return false end

    local wep = ply:GetActiveWeapon()
    if IsValid(wep) then
        local class = wep:GetClass()
        if class == INST_CLASS or class == CTRL_CLASS then
            return true, wep
        end
    end

    if IsValid(ply.ActiveInstrument) then
        return true, ply.ActiveInstrument
    end

    return false
end

local FALLBACK_INSTRUMENTS = {
    { "epiano",      "Electric Piano" },
    { "frenchhorn",  "French Horn" },
    { "guitar",      "Guitar" },
    { "harpsichord", "Harpsichord" },
    { "musicbox",    "Music Box" },
    { "organ",       "Organ" },
    { "pizzicato",   "Pizzicato" },
    { "sitar",       "Sitar" },
    { "steeldrum",   "Steel Drum" },
    { "voice",       "Voice" },
    { "accordion",   "Accordion" },
    { "strings",     "Strings" },
    { "choir",       "Choir" },
    { "bass",        "Bass" },
    { "piano",       "Piano" },
    { "flute",       "Flute" },
    { "pungi",       "Pungi" },
}

local instrumentCache = nil

local function GetAvailableInstruments()
    if instrumentCache then return instrumentCache end

    local list = {}
    local swep = weapons.GetStored(INST_CLASS)
    local src = swep and swep.Instruments
    if istable(src) then
        for i = 1, #src do
            local e = src[i]
            if istable(e) and isstring(e[1]) then
                list[#list + 1] = { folder = e[1], name = isstring(e[2]) and e[2] or e[1] }
            end
        end
    end

    if #list > 0 then
        instrumentCache = list
        return list
    end

    local names = {}
    for _, f in ipairs(FALLBACK_INSTRUMENTS) do names[f[1]] = f[2] end

    local _, dirs = file.Find("sound/instrument/*", "GAME")
    if dirs then
        for _, d in ipairs(dirs) do
            list[#list + 1] = { folder = d, name = names[d] or d }
        end
    end

    if #list > 0 then return list end

    for _, f in ipairs(FALLBACK_INSTRUMENTS) do
        list[#list + 1] = { folder = f[1], name = f[2] }
    end
    return list
end

local function FormatTime(sec)
    sec = math.max(0, math.floor(sec or 0))
    local m = math.floor(sec / 60)
    local s = sec % 60
    return string.format("%02d:%02d", m, s)
end

-- ----------------------------------------------------------------------------
-- 1. TESTABLE MIDI CORE
-- ----------------------------------------------------------------------------
local function ParseMIDI(data)
    return MIDI_Core.ParseMIDI(data, {
        maxFileBytes = MIDI_MAX_FILE_BYTES,
        maxNotes = MIDI_MAX_NOTES,
        maxEvents = MIDI_MAX_NOTES * 2,
        maxDuration = MIDI_MAX_DURATION,
    })
end

-- ----------------------------------------------------------------------------
-- 2. PLAYBACK ENGINE
-- ----------------------------------------------------------------------------
local MIDI_Engine = {
    Song = nil,
    SongName = "",
    Index = 1,
    IsPlaying = false,
    IsPaused = false,
    CurrentTime = 0,
    Speed = 1.0,
    Transpose = 0,
    Volume = 1.0,
    Instrument = "piano",
    Loop = false,
    MuteDrums = true,
    TotalDuration = 0,
    SyncedLeader = nil,

    NoteTokens = 0,
    DroppedNotes = 0,
    LastDropWarn = 0,
}

local function NoteRate()
    return math.Clamp(cvNoteRate:GetFloat(), 1, 120)
end

local function RefillNoteTokens()
    MIDI_Engine.NoteTokens = NoteRate() * 0.5
end

function MIDI_Engine:SendHostAction(action, extra1, extra2)
    if IsValid(self.SyncedLeader) then return end
    net.Start("TheInstrument_MIDI_Band_Action")
        net.WriteString(action)
        if action == "play" then
            net.WriteString(extra1 or self.SongName or "Track")
            net.WriteFloat(extra2 or self.Speed)
        elseif action == "seek" then
            net.WriteFloat(extra1 or self.CurrentTime)
        elseif action == "pause" then
            net.WriteBool(extra1)
        elseif action == "speed" then
            net.WriteFloat(extra1 or self.Speed)
            net.WriteFloat(self.CurrentTime)
        end
    net.SendToServer()
end

function MIDI_Engine:Play(song, songName)
    self.Song = song
    self.SongName = songName or self.SongName or "Track"
    self.Index = 1
    self.CurrentTime = 0
    self.IsPlaying = true
    self.IsPaused = false
    self.TotalDuration = (#song > 0) and song[#song].time or 0
    self.DroppedNotes = 0
    RefillNoteTokens()

    if not IsValid(self.SyncedLeader) then
        self:SendHostAction("play", self.SongName, self.Speed)
    end
end

function MIDI_Engine:TogglePause()
    if not self.IsPlaying then return end
    self.IsPaused = not self.IsPaused
    if not self.IsPaused then RefillNoteTokens() end

    if not IsValid(self.SyncedLeader) then
        self:SendHostAction("pause", self.IsPaused)
    end
end

function MIDI_Engine:Stop()
    if self.IsPlaying and not IsValid(self.SyncedLeader) then
        self:SendHostAction("stop")
    end

    self.IsPlaying = false
    self.IsPaused = false
    self.Song = nil
    self.SongName = ""
    self.Index = 1
    self.CurrentTime = 0
    self.TotalDuration = 0
    self.DroppedNotes = 0
    pendingJoin = nil

    self.Speed = 1.0
    if IsValid(activeSpeedSlider) then
        activeSpeedSlider:SetValue(1.0)
    end

    self.SyncedLeader = nil
end

function MIDI_Engine:Seek(targetTime)
    if not self.Song or self.TotalDuration <= 0 then return end
    self.CurrentTime = math.Clamp(targetTime, 0, self.TotalDuration)

    self.Index = MIDI_Core.LowerBound(self.Song, self.CurrentTime)

    RefillNoteTokens()
    self.DroppedNotes = 0

    if not IsValid(self.SyncedLeader) and self.IsPlaying then
        self:SendHostAction("seek", self.CurrentTime)
    end
end

-- ----------------------------------------------------------------------------
-- 3. NOTE EMISSION
-- ----------------------------------------------------------------------------
local function PlayInstrumentNote(midi_note, velocity)
    local has, wep = HasInstrument()
    if not has or not IsValid(wep) then return end

    if MIDI_Engine.Volume <= 0 then return end

    local ply = LocalPlayer()
    if not IsValid(ply) then return end

    midi_note = math.Clamp(math.Round(tonumber(midi_note) or 60), 0, 127)
    velocity = math.Clamp(tonumber(velocity) or 100, 0, 127)

    local raw_pitch = 100 * (2 ^ ((midi_note - 60) / 12))
    local sample, pitch = "c4.wav", raw_pitch

    if raw_pitch < 50 then
        sample = "c2.wav"; pitch = raw_pitch * 4
    elseif raw_pitch >= 50 and raw_pitch < 100 then
        sample = "c3.wav"; pitch = raw_pitch * 2
    elseif raw_pitch >= 100 and raw_pitch < 200 then
        sample = "c4.wav"; pitch = raw_pitch
    elseif raw_pitch >= 200 and raw_pitch < 400 then
        sample = "c5.wav"; pitch = raw_pitch / 2
    else
        sample = "c6.wav"; pitch = raw_pitch / 4
    end

    local guard = 0
    while pitch > 255 and guard < 32 do
        pitch = pitch * 0.5
        guard = guard + 1
    end
    while pitch < 1 and guard < 64 do
        pitch = pitch * 2
        guard = guard + 1
    end
    pitch = math.Clamp(math.Round(pitch), 1, 255)

    local instFolder = MIDI_Engine.Instrument or "piano"
    local sound_file = "instrument/" .. instFolder .. "/" .. sample
    local vol = math.Clamp((velocity / 127) * MIDI_Engine.Volume, 0.0, 1.0)
    local degree = midi_note % 12

    local speaker = NULL
    local soundPos = ply:GetPos()

    if wep.GetHasParentAmp and wep:GetHasParentAmp() then
        local amp = wep.GetParentAmp and wep:GetParentAmp()
        if IsValid(amp) then
            speaker = amp
            soundPos = amp:WorldSpaceCenter()
        end
    end

    sound.Play(sound_file, soundPos, 75, pitch, vol)

    if wep.UpdatePitchFireTime then pcall(wep.UpdatePitchFireTime, wep, raw_pitch, degree) end
    if wep.UpdateInstrumentFireTime then pcall(wep.UpdateInstrumentFireTime, wep, 3, raw_pitch, degree) end

    local actInst = ply.ActiveInstrument
    if IsValid(actInst) and actInst ~= wep then
        if actInst.UpdatePitchFireTime then pcall(actInst.UpdatePitchFireTime, actInst, raw_pitch, degree) end
        if actInst.UpdateInstrumentFireTime then pcall(actInst.UpdateInstrumentFireTime, actInst, 3, raw_pitch, degree) end
    end

    net.Start("music_mode_note_play_server", true)
        net.WriteEntity(wep)
        net.WriteEntity(ply)
        net.WriteString(sound_file)
        net.WriteInt(75, 32)
        net.WriteInt(pitch, 32)
        net.WriteFloat(vol)
        net.WriteInt(CHAN_STATIC or 6, 32)
        net.WriteFloat(raw_pitch)
        net.WriteInt(3, 32)
        net.WriteInt(degree, 32)
        net.WriteEntity(speaker)
    net.SendToServer()
end

-- ----------------------------------------------------------------------------
-- 4. BAND JOIN & SYNC
-- ----------------------------------------------------------------------------
local function ApplySongToFollower(song, songName, leader, startTime, speed, isPaused)
    local myChosenInstrument = MIDI_Engine.Instrument
    local myChosenTranspose = MIDI_Engine.Transpose
    local myChosenVolume = MIDI_Engine.Volume

    MIDI_Engine.SyncedLeader = leader
    MIDI_Engine.Speed = speed or 1.0
    MIDI_Engine:Play(song, songName)

    MIDI_Engine.Instrument = myChosenInstrument
    MIDI_Engine.Transpose = myChosenTranspose
    MIDI_Engine.Volume = myChosenVolume

    if startTime and startTime > 0 then
        MIDI_Engine:Seek(startTime)
    end
    if isPaused ~= nil then
        MIDI_Engine.IsPaused = isPaused
    end
end

local function BuildNoteChunks(song)
    if not istable(song) or #song == 0 then return nil, 0 end

    local simple = {}
    for i = 1, #song do
        local n = song[i]
        simple[i] = { math.Round(n.time, 3), n.note, n.vel, n.channel or 0 }
    end

    local json = util.TableToJSON(simple)
    if not json or #json > MIDI_MAX_DECOMPRESSED_BYTES then return nil, 0 end

    local comp = util.Compress(json)
    if not comp or #comp == 0 then return nil, 0 end

    local total = #comp
    local count = math.ceil(total / MIDI_CHUNK_SIZE)
    if count < 1 or count > MIDI_MAX_CHUNKS then return nil, total end

    local chunks = {}
    for i = 1, count do
        chunks[i] = string.sub(comp, (i - 1) * MIDI_CHUNK_SIZE + 1, i * MIDI_CHUNK_SIZE)
    end
    return chunks, total
end

local function AbortPendingJoin(reason)
    if not pendingJoin then return end
    pendingJoin = nil
    if reason then
        chat.AddText(Color(255, 150, 100), "[MIDI Band] " .. reason)
    end
end

local function JoinBandWithPlayer(target)
    if not IsValid(target) or not target:GetNW2Bool("MIDI_IsPlaying") then return end

    local songName = target:GetNW2String("MIDI_SongName", "")
    if not MIDI_Core.IsSafeMIDIFilename(songName) then
        chat.AddText(Color(255, 150, 100), "[MIDI Band] Host announced an unsafe song name.")
        return
    end
    local hasLocal = songName ~= "" and file.Exists("the_instrument_midi/" .. songName, "DATA")

    pendingJoin = {
        target = target,
        t = CurTime(),
        needsNotes = not hasLocal,
        expected = nil,
        chunks = {},
        got = 0,
        receivedBytes = 0,
    }

    chat.AddText(Color(255, 210, 80), "[MIDI Band] Connecting to " .. target:Nick() .. "...")
    net.Start("TheInstrument_MIDI_Sync_RequestJoin")
        net.WriteEntity(target)
        net.WriteBool(not hasLocal)
    net.SendToServer()
end

net.Receive("TheInstrument_MIDI_Sync_RequestJoin", function()
    local requester = net.ReadEntity()
    local needsNotes = net.ReadBool()

    if not IsValid(requester) or not MIDI_Engine.Song then return end

    local chunks, totalBytes = nil, 0
    if needsNotes then
        chunks, totalBytes = BuildNoteChunks(MIDI_Engine.Song)
        if not chunks then
            chat.AddText(Color(255, 150, 100),
                "[MIDI Band] \"" .. MIDI_Engine.SongName .. "\" is too large to stream. "
                .. requester:Nick() .. " needs the file in data/the_instrument_midi/.")
        end
    end

    local hasNotes = chunks ~= nil
    local count = hasNotes and #chunks or 0

    net.Start("TheInstrument_MIDI_Sync_SendJoinData")
        net.WriteEntity(requester)
        net.WriteString(MIDI_Engine.SongName)
        net.WriteFloat(MIDI_Engine.CurrentTime)
        net.WriteFloat(MIDI_Engine.Speed)
        net.WriteBool(MIDI_Engine.IsPaused)
        net.WriteBool(hasNotes)
        net.WriteUInt(count, 8)
    net.SendToServer()

    if not hasNotes then return end

    for i = 1, count do
        local chunkIndex = i
        local part = chunks[i]
        timer.Simple((i - 1) * MIDI_CHUNK_DELAY, function()
            if not IsValid(requester) then return end
            net.Start("TheInstrument_MIDI_Sync_Chunk")
                net.WriteEntity(requester)
                net.WriteUInt(chunkIndex, 8)
                net.WriteUInt(#part, 16)
                net.WriteData(part, #part)
            net.SendToServer()
        end)
    end
end)

local function FinishPendingJoin()
    if not pendingJoin then return end

    local parts = {}
    for i = 1, pendingJoin.expected do
        local c = pendingJoin.chunks[i]
        if c == nil then return end
        parts[i] = c
    end

    local comp = table.concat(parts)
    local host = pendingJoin.target
    local songName = pendingJoin.songName
    local curTime = pendingJoin.curTime
    local speed = pendingJoin.speed
    local isPaused = pendingJoin.isPaused
    pendingJoin = nil

    if not comp or #comp > MIDI_CHUNK_SIZE * MIDI_MAX_CHUNKS then
        chat.AddText(Color(255, 80, 80), "[MIDI Band] Received song data was too large.")
        return
    end

    local decompressed, json = pcall(util.Decompress, comp, MIDI_MAX_DECOMPRESSED_BYTES)
    if not decompressed or not json or #json > MIDI_MAX_DECOMPRESSED_BYTES then
        chat.AddText(Color(255, 80, 80), "[MIDI Band] Received song data was corrupt.")
        return
    end

    local decoded, simple = pcall(util.JSONToTable, json)
    if not decoded or not istable(simple) or #simple == 0 then
        chat.AddText(Color(255, 80, 80), "[MIDI Band] Received song data was unreadable.")
        return
    end

    local song, validationError = MIDI_Core.ValidateSong(simple, {
        maxNotes = MIDI_MAX_NOTES,
        maxDuration = MIDI_MAX_DURATION,
    })
    if not song then
        chat.AddText(Color(255, 80, 80),
            "[MIDI Band] Received song data was invalid: " .. (validationError or "unknown error"))
        return
    end

    if not IsValid(host) then return end

    local latency = math.max(0, (host:Ping() + LocalPlayer():Ping()) / 2000)
    local compensatedTime = curTime + (latency * speed)

    ApplySongToFollower(song, songName, host, compensatedTime, speed, isPaused)
    chat.AddText(Color(100, 255, 100), "[MIDI Band] Joined " .. host:Nick() .. " at " .. FormatTime(compensatedTime) .. "!")
end

net.Receive("TheInstrument_MIDI_Sync_SendJoinData", function()
    local host = net.ReadEntity()
    local songName = net.ReadString()
    local curTime = net.ReadFloat()
    local speed = net.ReadFloat()
    local isPaused = net.ReadBool()
    local hasNotes = net.ReadBool()
    local totalChunks = net.ReadUInt(8)

    if not pendingJoin or pendingJoin.target ~= host then return end
    if not IsValid(host) then AbortPendingJoin("Host disconnected.") return end
    if not MIDI_Core.IsSafeMIDIFilename(songName) then
        AbortPendingJoin("Host announced an unsafe song name.")
        return
    end
    if not MIDI_Core.IsFiniteNumber(curTime) or not MIDI_Core.IsFiniteNumber(speed) then
        AbortPendingJoin("Host announced invalid playback state.")
        return
    end

    curTime = math.Clamp(curTime, 0, MIDI_MAX_DURATION)
    speed = math.Clamp(speed, 0.1, 4)

    pendingJoin.t = CurTime()
    pendingJoin.songName = songName
    pendingJoin.curTime = curTime
    pendingJoin.speed = speed
    pendingJoin.isPaused = isPaused

    if not hasNotes then
        pendingJoin = nil
        local localData = songName ~= "" and file.Read("the_instrument_midi/" .. songName, "DATA") or nil
        if not localData then
            chat.AddText(Color(255, 80, 80), "[MIDI Band] Missing local file \"" .. songName .. "\".")
            return
        end
        local song, err = ParseMIDI(localData)
        if not song then
            chat.AddText(Color(255, 80, 80), "[MIDI Band] Error: " .. (err or "failed to read file"))
            return
        end

        local latency = math.max(0, (host:Ping() + LocalPlayer():Ping()) / 2000)
        local compensatedTime = curTime + (latency * speed)

        ApplySongToFollower(song, songName, host, compensatedTime, speed, isPaused)
        chat.AddText(Color(100, 255, 100), "[MIDI Band] Joined " .. host:Nick() .. " at " .. FormatTime(compensatedTime) .. "!")
        return
    end

    if totalChunks < 1 or totalChunks > MIDI_MAX_CHUNKS then
        AbortPendingJoin("Host announced an impossible transfer size.")
        return
    end

    pendingJoin.expected = totalChunks
    pendingJoin.chunks = {}
    pendingJoin.got = 0
    pendingJoin.receivedBytes = 0
end)

net.Receive("TheInstrument_MIDI_Sync_Chunk", function()
    local host = net.ReadEntity()
    local index = net.ReadUInt(8)
    local dataLen = net.ReadUInt(16)
    if dataLen < 1 or dataLen > MIDI_CHUNK_SIZE then return end
    local part = dataLen > 0 and net.ReadData(dataLen) or ""

    if not pendingJoin or pendingJoin.target ~= host then return end
    if not pendingJoin.expected or index < 1 or index > pendingJoin.expected then return end
    if type(part) ~= "string" or #part ~= dataLen then return end
    if pendingJoin.receivedBytes + dataLen > pendingJoin.expected * MIDI_CHUNK_SIZE then
        AbortPendingJoin("Host sent too much song data.")
        return
    end

    pendingJoin.t = CurTime()

    if pendingJoin.chunks[index] == nil then
        pendingJoin.chunks[index] = part
        pendingJoin.got = pendingJoin.got + 1
        pendingJoin.receivedBytes = pendingJoin.receivedBytes + dataLen
    end

    if pendingJoin.got >= pendingJoin.expected then
        FinishPendingJoin()
    end
end)

net.Receive("TheInstrument_MIDI_Band_Action", function()
    local host = net.ReadEntity()
    local action = net.ReadString()

    if not IsValid(MIDI_Engine.SyncedLeader) or MIDI_Engine.SyncedLeader ~= host then return end

    if action == "play" then
        JoinBandWithPlayer(host)

    elseif action == "seek" then
        local targetTime = net.ReadFloat()
        local latency = math.max(0, (host:Ping() + LocalPlayer():Ping()) / 2000)
        MIDI_Engine:Seek(targetTime + (latency * MIDI_Engine.Speed))

    elseif action == "pause" then
        local isPaused = net.ReadBool()
        MIDI_Engine.IsPaused = isPaused
        if not isPaused then RefillNoteTokens() end

    elseif action == "speed" then
        local speed = net.ReadFloat()
        local curTime = net.ReadFloat()
        if not MIDI_Core.IsFiniteNumber(speed) or not MIDI_Core.IsFiniteNumber(curTime) then return end
        speed = math.Clamp(speed, 0.1, 4)
        curTime = math.Clamp(curTime, 0, MIDI_MAX_DURATION)

        local latency = math.max(0, (host:Ping() + LocalPlayer():Ping()) / 2000)
        MIDI_Engine.Speed = speed
        MIDI_Engine.CurrentTime = curTime + (latency * speed)

        MIDI_Engine.Index = MIDI_Core.LowerBound(MIDI_Engine.Song, MIDI_Engine.CurrentTime)

        if IsValid(activeSpeedSlider) then activeSpeedSlider:SetValue(speed) end

    elseif action == "sync" then
        local hostTime = net.ReadFloat()
        if not MIDI_Core.IsFiniteNumber(hostTime) then return end
        hostTime = math.Clamp(hostTime, 0, MIDI_MAX_DURATION)
        if not MIDI_Engine.IsPaused and MIDI_Engine.Song then
            local latency = math.max(0, (host:Ping() + LocalPlayer():Ping()) / 2000)
            local expectedTime = hostTime + (latency * MIDI_Engine.Speed)
            local drift = expectedTime - MIDI_Engine.CurrentTime

            if math.abs(drift) > 0.035 then
                MIDI_Engine.CurrentTime = expectedTime
                MIDI_Engine.Index = MIDI_Core.LowerBound(MIDI_Engine.Song, expectedTime)
            end
        end

    elseif action == "stop" then
        MIDI_Engine:Stop()
        chat.AddText(Color(255, 150, 100), "[MIDI Band] Host stopped playback.")
    end
end)

-- ----------------------------------------------------------------------------
-- 5. KEYBOARD SUPPRESSION
-- ----------------------------------------------------------------------------
local function SuppressInstrumentKeyboard()
    local has, wep = HasInstrument()
    if not has or not IsValid(wep) then return end

    suppressedWep = wep
    suppressedWasEnabled = (wep.GetEnabled and wep:GetEnabled()) and true or false
    wep.IsActive = false
end

local function RestoreInstrumentKeyboard()
    local wep = suppressedWep
    local wasEnabled = suppressedWasEnabled
    suppressedWep = nil
    suppressedWasEnabled = false

    if not IsValid(wep) then return end
    if wasEnabled and wep.SetEnabled then
        wep:SetEnabled()
    end
end

-- ----------------------------------------------------------------------------
-- 6. USER INTERFACE (UI)
-- ----------------------------------------------------------------------------
local function OpenMIDIMenu()
    if not HasInstrument() then
        chat.AddText(Color(255, 80, 80), "[MIDI] Please equip The Instrument first!")
        return
    end

    if IsValid(activeMenuFrame) then
        activeMenuFrame:Close()
        return
    end

    local frame = vgui.Create("DFrame")
    if not IsValid(frame) then return end

    activeMenuFrame = frame
    TheInstrument_MIDI_Panels.menuFrame = frame
    frame:SetSize(450, 600)
    frame:Center()
    frame:SetTitle("The Instrument MIDI Chooser by dmbai")
    frame:MakePopup()

    SuppressInstrumentKeyboard()

    local closed = false
    local function CleanupFrame()
        if closed then return end
        closed = true
        RestoreInstrumentKeyboard()
        activeMenuFrame = nil
        activeSpeedSlider = nil
        activeTimeBar = nil
        activeLoopCheck = nil
        activeStatusLabel = nil
        activeBtnStop = nil
        activeBtnPause = nil
        activeBtnPlay = nil
        TheInstrument_MIDI_Panels.menuFrame = nil
    end
    frame.OnClose = CleanupFrame
    frame.OnRemove = CleanupFrame

    local pnlSearch = vgui.Create("DPanel", frame)
    pnlSearch:Dock(TOP); pnlSearch:SetTall(28); pnlSearch:DockMargin(0, 0, 0, 6)
    pnlSearch.Paint = function() end

    -- Кнопка Refresh справа
    local btnRefresh = vgui.Create("DButton", pnlSearch)
    btnRefresh:Dock(RIGHT); btnRefresh:DockMargin(6, 0, 0, 0); btnRefresh:SetWide(75)
    btnRefresh:SetText("Refresh")

    -- Кнопка Folder слева от Refresh (копирует путь в буфер обмена)
    local btnFolder = vgui.Create("DButton", pnlSearch)
    btnFolder:Dock(RIGHT); btnFolder:DockMargin(6, 0, 0, 0); btnFolder:SetWide(75)
    btnFolder:SetText("Folder")
    btnFolder:SetTooltip("Copy MIDI folder path to clipboard")
    btnFolder.DoClick = function()
        SetClipboardText("garrysmod/data/the_instrument_midi/")
        notification.AddLegacy("Folder path copied to clipboard!", NOTIFY_GENERIC, 4)
        surface.PlaySound("buttons/button14.wav")
        chat.AddText(Color(100, 200, 255), "[MIDI] Path copied: garrysmod/data/the_instrument_midi/")
    end

    -- Поле поиска
    local txtSearch = vgui.Create("DTextEntry", pnlSearch)
    txtSearch:Dock(FILL)
    txtSearch:SetPlaceholderText("Search songs by title...")

    local list = vgui.Create("DListView", frame)
    list:Dock(FILL); list:SetMultiSelect(false)
    list:AddColumn("Files in data/the_instrument_midi/")

    local function PopulateList(filter)
        list:Clear()
        local files = file.Find("the_instrument_midi/*.mid", "DATA") or {}
        local longExtensionFiles = file.Find("the_instrument_midi/*.midi", "DATA")
        for _, filename in ipairs(longExtensionFiles or {}) do
            files[#files + 1] = filename
        end
        table.sort(files)
        for _, f in ipairs(files) do
            if not filter or filter == "" or string.find(string.lower(f), string.lower(filter), 1, true) then
                list:AddLine(f)
            end
        end
    end
    PopulateList()

    txtSearch.OnChange = function(self) PopulateList(self:GetValue()) end
    btnRefresh.DoClick = function() PopulateList(txtSearch:GetValue()) end

    local pnlBottom = vgui.Create("DPanel", frame)
    pnlBottom:Dock(BOTTOM); pnlBottom:SetTall(260); pnlBottom:DockMargin(0, 6, 0, 0)
    pnlBottom.Paint = function(self, w, h) draw.RoundedBox(6, 0, 0, w, h, Color(34, 36, 42)) end

    local lblStatus = vgui.Create("DLabel", pnlBottom)
    lblStatus:Dock(TOP); lblStatus:SetTall(20); lblStatus:DockMargin(12, 4, 12, 2)
    lblStatus:SetFont("DermaDefaultBold"); lblStatus:SetText("Status: Ready (Solo)")
    lblStatus:SetTextColor(Color(180, 180, 180))
    activeStatusLabel = lblStatus

    local pnlInst = vgui.Create("DPanel", pnlBottom)
    pnlInst:Dock(TOP); pnlInst:SetTall(28); pnlInst:DockMargin(12, 2, 12, 4)
    pnlInst.Paint = function() end

    local lblInst = vgui.Create("DLabel", pnlInst)
    lblInst:Dock(LEFT); lblInst:SetWide(140); lblInst:SetText("Instrument:")
    lblInst:SetFont("DermaDefaultBold"); lblInst:SetTextColor(Color(240, 240, 240))

    local comboInst = vgui.Create("DComboBox", pnlInst)
    comboInst:Dock(FILL)
    do
        local instruments = GetAvailableInstruments()
        local matched = false
        for _, entry in ipairs(instruments) do
            local selected = (entry.folder == MIDI_Engine.Instrument)
            if selected then matched = true end
            comboInst:AddChoice(entry.name, entry.folder, selected)
        end
        if not matched then
            comboInst:SetValue(MIDI_Engine.Instrument or "piano")
        end
    end
    comboInst.OnSelect = function(_, _, _, data)
        if isstring(data) and data ~= "" then MIDI_Engine.Instrument = data end
    end

    local sliderVol = vgui.Create("DNumSlider", pnlBottom)
    sliderVol:Dock(TOP); sliderVol:DockMargin(12, 0, 12, 0); sliderVol:SetText("Instrument Volume (%)")
    sliderVol:SetMin(0); sliderVol:SetMax(100); sliderVol:SetDecimals(0); sliderVol:SetValue(MIDI_Engine.Volume * 100)
    sliderVol.Label:SetTextColor(Color(240, 240, 240)); sliderVol.Label:SetFont("DermaDefaultBold")
    if IsValid(sliderVol.TextArea) then sliderVol.TextArea:SetTextColor(Color(255, 255, 255)) end
    sliderVol.OnValueChanged = function(_, val) MIDI_Engine.Volume = val / 100 end

    local sliderSpeed = vgui.Create("DNumSlider", pnlBottom)
    sliderSpeed:Dock(TOP); sliderSpeed:DockMargin(12, 0, 12, 0); sliderSpeed:SetText("Speed (x)")
    sliderSpeed:SetMin(0.5); sliderSpeed:SetMax(2.0); sliderSpeed:SetDecimals(2); sliderSpeed:SetValue(MIDI_Engine.Speed)
    sliderSpeed.Label:SetTextColor(Color(240, 240, 240)); sliderSpeed.Label:SetFont("DermaDefaultBold")
    if IsValid(sliderSpeed.TextArea) then sliderSpeed.TextArea:SetTextColor(Color(255, 255, 255)) end
    activeSpeedSlider = sliderSpeed
    sliderSpeed.OnValueChanged = function(_, val)
        if IsValid(MIDI_Engine.SyncedLeader) then return end
        MIDI_Engine.Speed = val
        if MIDI_Engine.IsPlaying then
            MIDI_Engine:SendHostAction("speed", val)
        end
    end

    local sliderTrans = vgui.Create("DNumSlider", pnlBottom)
    sliderTrans:Dock(TOP); sliderTrans:DockMargin(12, 0, 12, 2); sliderTrans:SetText("Transpose (semitones)")
    sliderTrans:SetMin(-24); sliderTrans:SetMax(24); sliderTrans:SetDecimals(0); sliderTrans:SetValue(MIDI_Engine.Transpose)
    sliderTrans.Label:SetTextColor(Color(240, 240, 240)); sliderTrans.Label:SetFont("DermaDefaultBold")
    if IsValid(sliderTrans.TextArea) then sliderTrans.TextArea:SetTextColor(Color(255, 255, 255)) end
    sliderTrans.OnValueChanged = function(_, val) MIDI_Engine.Transpose = math.Round(val) end

    local pnlInfo = vgui.Create("DPanel", pnlBottom)
    pnlInfo:Dock(TOP); pnlInfo:SetTall(24); pnlInfo:DockMargin(12, 2, 12, 4)
    pnlInfo.Paint = function() end

    local timeBar = vgui.Create("DPanel", pnlInfo)
    timeBar:Dock(LEFT); timeBar:SetWide(150); timeBar:SetCursor("hand")
    activeTimeBar = timeBar

    local isDragging = false
    local function DoSeek(pnl)
        if IsValid(MIDI_Engine.SyncedLeader) then return end
        local mx = pnl:CursorPos()
        local frac = math.Clamp(mx / pnl:GetWide(), 0, 1)
        if MIDI_Engine.Song and MIDI_Engine.TotalDuration > 0 then
            MIDI_Engine:Seek(frac * MIDI_Engine.TotalDuration)
        end
    end
    timeBar.OnMousePressed = function(self, mc)
        if IsValid(MIDI_Engine.SyncedLeader) then return end
        if mc == MOUSE_LEFT then isDragging = true; self:MouseCapture(true); DoSeek(self) end
    end
    timeBar.OnMouseReleased = function(self, mc)
        if mc == MOUSE_LEFT and isDragging then isDragging = false; self:MouseCapture(false) end
    end
    timeBar.OnCursorMoved = function(self) if isDragging then DoSeek(self) end end
    timeBar.Paint = function(self, w, h)
        draw.RoundedBox(4, 0, 4, w, h - 8, Color(22, 24, 28))
        local frac = 0
        if MIDI_Engine.IsPlaying and MIDI_Engine.TotalDuration > 0 then
            frac = math.Clamp(MIDI_Engine.CurrentTime / MIDI_Engine.TotalDuration, 0, 1)
        end
        if frac > 0 then draw.RoundedBox(4, 0, 4, w * frac, h - 8, Color(45, 135, 235)) end
        local thumbX = math.Clamp(w * frac, 4, w - 4)
        draw.RoundedBox(6, thumbX - 4, 1, 8, h - 2, Color(255, 255, 255))
    end

    local lblTime = vgui.Create("DLabel", pnlInfo)
    lblTime:Dock(LEFT); lblTime:DockMargin(6, 0, 0, 0); lblTime:SetWide(90)
    lblTime:SetText("00:00 / 00:00"); lblTime:SetFont("DermaDefaultBold"); lblTime:SetTextColor(Color(200, 200, 200))

    local chkLoop = vgui.Create("DCheckBoxLabel", pnlInfo)
    chkLoop:Dock(RIGHT); chkLoop:SetWide(65); chkLoop:SetText("Loop")
    chkLoop:SetFont("DermaDefaultBold"); chkLoop:SetTextColor(Color(240, 240, 240))
    chkLoop:SetValue(MIDI_Engine.Loop)
    chkLoop.OnChange = function(_, val)
        if IsValid(MIDI_Engine.SyncedLeader) then return end
        MIDI_Engine.Loop = val
    end
    activeLoopCheck = chkLoop

    local chkDrums = vgui.Create("DCheckBoxLabel", pnlInfo)
    chkDrums:Dock(RIGHT); chkDrums:SetWide(95); chkDrums:SetText("No Drums")
    chkDrums:SetFont("DermaDefaultBold"); chkDrums:SetTextColor(Color(240, 240, 240))
    chkDrums:SetTooltip("Mutes percussion Channel 10 for clean melody playback")
    chkDrums:SetValue(MIDI_Engine.MuteDrums)
    chkDrums.OnChange = function(_, val) MIDI_Engine.MuteDrums = val end

    pnlInfo.Think = function()
        if MIDI_Engine.IsPlaying and MIDI_Engine.Song and MIDI_Engine.TotalDuration > 0 then
            lblTime:SetText(FormatTime(MIDI_Engine.CurrentTime) .. " / " .. FormatTime(MIDI_Engine.TotalDuration))
        else
            lblTime:SetText("00:00 / 00:00")
        end
    end

    local pnlBtns = vgui.Create("DPanel", pnlBottom)
    pnlBtns:Dock(BOTTOM); pnlBtns:SetTall(38); pnlBtns:DockMargin(12, 0, 12, 10)
    pnlBtns.Paint = function() end

    local btnPlay = vgui.Create("DButton", pnlBtns)
    btnPlay:Dock(LEFT); btnPlay:SetWide(135); btnPlay:SetText("PLAY")
    btnPlay:SetFont("DermaDefaultBold"); btnPlay:SetTextColor(Color(255, 255, 255))
    btnPlay.Paint = function(self, w, h)
        local inBand = IsValid(MIDI_Engine.SyncedLeader)
        local col
        if inBand then
            col = Color(40, 50, 42, 160)
        else
            col = self:IsHovered() and Color(46, 160, 67) or Color(35, 134, 54)
        end
        draw.RoundedBox(6, 0, 0, w, h, col)
    end
    btnPlay.DoClick = function()
        if IsValid(MIDI_Engine.SyncedLeader) then return end

        local line = list:GetSelectedLine()
        if not line then return end
        local filename = list:GetLine(line):GetValue(1)
        local rawData = file.Read("the_instrument_midi/" .. filename, "DATA")
        if not rawData then
            chat.AddText(Color(255, 50, 50), "[MIDI Player] Error: failed to read file")
            return
        end

        local song, err = ParseMIDI(rawData)
        if not song then
            chat.AddText(Color(255, 50, 50), "[MIDI Player] Error: " .. (err or "failed to read file"))
            return
        end

        MIDI_Engine.SyncedLeader = nil
        pendingJoin = nil
        MIDI_Engine:Play(song, filename)
    end
    activeBtnPlay = btnPlay

    local btnPause = vgui.Create("DButton", pnlBtns)
    btnPause:Dock(FILL); btnPause:DockMargin(8, 0, 8, 0); btnPause:SetText("PAUSE [R]")
    btnPause:SetFont("DermaDefaultBold"); btnPause:SetTextColor(Color(255, 255, 255))
    btnPause.Paint = function(self, w, h)
        local inBand = IsValid(MIDI_Engine.SyncedLeader)
        local col
        if inBand then
            col = Color(55, 50, 38, 160)
        else
            col = self:IsHovered() and Color(210, 140, 30) or Color(180, 115, 20)
        end
        draw.RoundedBox(6, 0, 0, w, h, col)
    end
    btnPause.DoClick = function()
        if IsValid(MIDI_Engine.SyncedLeader) then return end
        MIDI_Engine:TogglePause()
    end
    activeBtnPause = btnPause

    local btnStop = vgui.Create("DButton", pnlBtns)
    btnStop:Dock(RIGHT); btnStop:SetWide(135); btnStop:SetText("STOP")
    btnStop:SetFont("DermaDefaultBold"); btnStop:SetTextColor(Color(255, 255, 255))
    btnStop.Paint = function(self, w, h)
        local inBand = IsValid(MIDI_Engine.SyncedLeader)
        local col
        if inBand then
            col = Color(55, 38, 38, 160)
        else
            col = self:IsHovered() and Color(218, 54, 51) or Color(180, 40, 40)
        end
        draw.RoundedBox(6, 0, 0, w, h, col)
    end
    btnStop.DoClick = function()
        if IsValid(MIDI_Engine.SyncedLeader) then return end
        MIDI_Engine:Stop()
    end
    activeBtnStop = btnStop
end

-- ----------------------------------------------------------------------------
-- 7. QUICK PAUSE ON 'R'
-- ----------------------------------------------------------------------------
local BIND_HOOK_ID = "player_block_bindings_in_music_mode"

local blocked_keys = {
    [KEY_MINUS] = true,
    [KEY_EQUAL] = true,
    [KEY_LALT]  = true,
    [KEY_SPACE] = true,
}

local blocked_binds = {
    ["invnext"] = true,
    ["invprev"] = true,
    ["lastinv"] = true,
}

local function MIDI_BindPress(ply, bind, pressed)
    if ply ~= LocalPlayer() then return end

    if pressed and string.find(bind, "+reload", 1, true) then
        if HasInstrument() and MIDI_Engine.IsPlaying then
            if not IsValid(MIDI_Engine.SyncedLeader) then
                MIDI_Engine:TogglePause()
                surface.PlaySound("ui/buttonclickrelease.wav")
                return true
            end
        end
    end

    local inst = ply:GetActiveWeapon()
    if not IsValid(inst) then return end

    local class = inst:GetClass()
    if class ~= INST_CLASS and class ~= CTRL_CLASS then return end
    if not inst.GetEnabled or not inst:GetEnabled() then return end

    if blocked_binds[bind] then return true end

    local keyName = input.LookupBinding(bind, true)
    if not keyName then return end

    local key = input.GetKeyCode(keyName)
    if not key or key == KEY_NONE then return end

    if (key >= KEY_0 and key <= KEY_SLASH) or blocked_keys[key] then
        return true
    end
end

hook.Add("PlayerBindPress", BIND_HOOK_ID, MIDI_BindPress)
hook.Add("InitPostEntity", "TheInstrument_MIDI_InstallBind", function()
    hook.Add("PlayerBindPress", BIND_HOOK_ID, MIDI_BindPress)
end)

-- ----------------------------------------------------------------------------
-- 8. HUD BUTTONS
-- ----------------------------------------------------------------------------
local nearbyBandPlayers = {}

local function PositionHUDButtons()
    local w = ScrW()
    if IsValid(hudButton) then hudButton:SetPos(w - 135, 30) end
    if IsValid(joinButton) then joinButton:SetPos(w - 145, 68) end
end

local function SetupHUDButtons()
    if IsValid(hudButton) then return end
    if not vgui or not IsValid(LocalPlayer()) then return end

    hudButton = vgui.Create("DButton")
    hudButton:SetSize(120, 34)
    hudButton:SetText("MIDI [F3]")
    hudButton:SetFont("Trebuchet18")
    hudButton:SetTextColor(Color(255, 255, 255))
    hudButton:SetVisible(false)
    hudButton.Paint = function(self, w, h)
        local bg = self:IsHovered() and Color(65, 125, 230, 220) or Color(30, 30, 35, 190)
        draw.RoundedBox(8, 0, 0, w, h, bg)
        surface.SetDrawColor(255, 255, 255, 40); surface.DrawOutlinedRect(0, 0, w, h, 1)
    end
    hudButton.DoClick = function() OpenMIDIMenu() end

    joinButton = vgui.Create("DButton")
    joinButton:SetSize(140, 28)
    joinButton:SetFont("DermaDefaultBold")
    joinButton:SetTextColor(Color(255, 255, 255))
    joinButton:SetVisible(false)

    joinButton.Paint = function(self, w, h)
        local inBand = IsValid(MIDI_Engine.SyncedLeader)
        local baseCol = inBand and Color(180, 45, 45, 220) or (self:IsHovered() and Color(35, 150, 235, 220) or Color(25, 105, 185, 200))
        draw.RoundedBox(6, 0, 0, w, h, baseCol)
        surface.SetDrawColor(255, 255, 255, 50); surface.DrawOutlinedRect(0, 0, w, h, 1)
    end

    joinButton.DoClick = function()
        if IsValid(MIDI_Engine.SyncedLeader) then
            MIDI_Engine:Stop()
            chat.AddText(Color(255, 150, 100), "[MIDI Band] Left band session.")
            return
        end

        if #nearbyBandPlayers == 1 then
            JoinBandWithPlayer(nearbyBandPlayers[1].ply)
            return
        end

        if #nearbyBandPlayers > 1 then
            local menu = DermaMenu()
            for _, info in ipairs(nearbyBandPlayers) do
                local title = info.nick .. " (" .. string.sub(info.song, 1, 24) .. ")"
                menu:AddOption(title, function()
                    JoinBandWithPlayer(info.ply)
                end)
            end
            menu:Open()
        end
    end

    TheInstrument_MIDI_Panels.hudButton = hudButton
    TheInstrument_MIDI_Panels.joinButton = joinButton
    PositionHUDButtons()
end

-- ----------------------------------------------------------------------------
-- 9. THROTTLED SCAN & COMPLETE UI LOCKDOWN
-- ----------------------------------------------------------------------------
local lastScrW, lastScrH = 0, 0

local function MIDI_ThrottledUpdate(hasInst)
    if pendingJoin and CurTime() - pendingJoin.t > MIDI_JOIN_TIMEOUT then
        AbortPendingJoin("Join timed out - host did not finish sending.")
    end

    if ScrW() ~= lastScrW or ScrH() ~= lastScrH then
        lastScrW, lastScrH = ScrW(), ScrH()
        PositionHUDButtons()
    end

    if hasInst then
        if not IsValid(hudButton) then SetupHUDButtons() end
        if IsValid(hudButton) and not hudButton:IsVisible() then hudButton:SetVisible(true) end
    else
        if IsValid(hudButton) and hudButton:IsVisible() then hudButton:SetVisible(false) end
        if IsValid(joinButton) and joinButton:IsVisible() then joinButton:SetVisible(false) end
        nearbyBandPlayers = {}
        return
    end

    local inBand = IsValid(MIDI_Engine.SyncedLeader)

    if IsValid(activeSpeedSlider) then
        activeSpeedSlider:SetMouseInputEnabled(not inBand)
        activeSpeedSlider:SetTooltip(inBand and "Speed is controlled by Band Host" or "")
    end

    if IsValid(activeTimeBar) then
        activeTimeBar:SetMouseInputEnabled(not inBand)
        activeTimeBar:SetCursor(inBand and "arrow" or "hand")
    end

    if IsValid(activeLoopCheck) then
        activeLoopCheck:SetMouseInputEnabled(not inBand)
    end

    if IsValid(activeBtnPlay) then
        activeBtnPlay:SetMouseInputEnabled(not inBand)
        if inBand then
            activeBtnPlay:SetText("PLAY (HOST)")
            activeBtnPlay:SetTooltip("Controlled by Band Host. Use [Leave Band] on HUD to exit.")
        else
            activeBtnPlay:SetText("PLAY")
            activeBtnPlay:SetTooltip("")
        end
    end

    if IsValid(activeBtnPause) then
        activeBtnPause:SetMouseInputEnabled(not inBand)
        if inBand then
            activeBtnPause:SetText(MIDI_Engine.IsPaused and "PAUSED (HOST)" or "PLAYING (HOST)")
            activeBtnPause:SetTooltip("Pause is controlled by Band Host")
        else
            activeBtnPause:SetText(MIDI_Engine.IsPaused and "RESUME [R]" or "PAUSE [R]")
            activeBtnPause:SetTooltip("")
        end
    end

    if IsValid(activeBtnStop) then
        activeBtnStop:SetMouseInputEnabled(not inBand)
        if inBand then
            activeBtnStop:SetText("STOP (HOST)")
            activeBtnStop:SetTooltip("Controlled by Band Host. Use [Leave Band] on HUD to exit.")
        else
            activeBtnStop:SetText("STOP")
            activeBtnStop:SetTooltip("")
        end
    end

    if IsValid(activeStatusLabel) then
        if inBand then
            local leaderNick = MIDI_Engine.SyncedLeader:Nick()
            activeStatusLabel:SetText("Band Member (Host: " .. leaderNick .. ")")
            activeStatusLabel:SetTextColor(Color(80, 180, 255))
        elseif MIDI_Engine.IsPlaying then
            activeStatusLabel:SetText("Band Host / Playing")
            activeStatusLabel:SetTextColor(Color(100, 220, 100))
        else
            activeStatusLabel:SetText("Ready (Solo)")
            activeStatusLabel:SetTextColor(Color(180, 180, 180))
        end
    end

    if not IsValid(joinButton) then return end

    local me = LocalPlayer()
    if not IsValid(me) then return end
    local myPos = me:GetPos()

    nearbyBandPlayers = {}
    for _, ply in ipairs(player.GetAll()) do
        if ply ~= me and ply:GetNW2Bool("MIDI_IsPlaying") then
            if ply:GetPos():DistToSqr(myPos) <= (800 * 800) then
                nearbyBandPlayers[#nearbyBandPlayers + 1] = {
                    ply = ply,
                    nick = ply:Nick(),
                    song = ply:GetNW2String("MIDI_SongName", "Track")
                }
            end
        end
    end

    if inBand then
        local leader = MIDI_Engine.SyncedLeader
        joinButton:SetVisible(true)
        joinButton:SetText("Leave Band")

        if not leader:GetNW2Bool("MIDI_IsPlaying") or leader:GetPos():DistToSqr(myPos) > (950 * 950) then
            MIDI_Engine:Stop()
            chat.AddText(Color(255, 150, 100), "[MIDI Band] Band session ended.")
        end
    elseif #nearbyBandPlayers == 1 then
        joinButton:SetVisible(true)
        local shortNick = string.sub(nearbyBandPlayers[1].nick, 1, 9)
        joinButton:SetText("Join: " .. shortNick)
        joinButton:SetTooltip(nearbyBandPlayers[1].nick .. " is playing " .. nearbyBandPlayers[1].song)
    elseif #nearbyBandPlayers > 1 then
        joinButton:SetVisible(true)
        joinButton:SetText("Join Band (" .. #nearbyBandPlayers .. ")")
        joinButton:SetTooltip("Multiple players playing music! Click to choose.")
    else
        joinButton:SetVisible(false)
    end
end

-- ----------------------------------------------------------------------------
-- 10. INPUT GATE & ENGINE THINK
-- ----------------------------------------------------------------------------
local function MIDI_InputAllowed()
    if gui.IsGameUIVisible() or gui.IsConsoleVisible() then return false end
    local kb = vgui.GetKeyboardFocus()
    if IsValid(kb) then
        if not IsValid(activeMenuFrame) then return false end
        if kb.IsEditing and kb:IsEditing() then return false end
        if kb ~= activeMenuFrame then return false end
    end
    return true
end

local wasF3Down = false
local nextScan = 0
local nextHeartbeat = 0

hook.Add("Think", "TheInstrument_MIDI_Control_Think", function()
    local hasInst = HasInstrument()

    if IsValid(activeMenuFrame) and IsValid(suppressedWep) then
        suppressedWep.IsActive = false
    end

    local isF3Down = MIDI_InputAllowed() and input.IsKeyDown(KEY_F3) or false
    if isF3Down and not wasF3Down and hasInst then OpenMIDIMenu() end
    wasF3Down = isF3Down

    if not hasInst then
        if IsValid(activeMenuFrame) then activeMenuFrame:Close() end
        if MIDI_Engine.IsPlaying then MIDI_Engine:Stop() end
    end

    local now = CurTime()
    if now >= nextScan then
        nextScan = now + MIDI_SCAN_INTERVAL
        MIDI_ThrottledUpdate(hasInst)
    end

    if not IsValid(MIDI_Engine.SyncedLeader) and MIDI_Engine.IsPlaying and not MIDI_Engine.IsPaused then
        if now >= nextHeartbeat then
            nextHeartbeat = now + 1.5
            net.Start("TheInstrument_MIDI_Band_Action", true)
                net.WriteString("sync")
                net.WriteFloat(MIDI_Engine.CurrentTime)
            net.SendToServer()
        end
    end

    if not (MIDI_Engine.IsPlaying and not MIDI_Engine.IsPaused and MIDI_Engine.Song) then return end

    local ft = FrameTime()
    MIDI_Engine.CurrentTime = MIDI_Engine.CurrentTime + (ft * MIDI_Engine.Speed)

    local rate = NoteRate()
    MIDI_Engine.NoteTokens = math.min(MIDI_Engine.NoteTokens + rate * ft, rate * 0.5)

    local budget = MIDI_FRAME_BUDGET
    local dropped = 0
    local song = MIDI_Engine.Song
    local total = #song
    local scanned = 0

    while MIDI_Engine.Index <= total do
        local ev = song[MIDI_Engine.Index]
        if ev.time > MIDI_Engine.CurrentTime then break end

        scanned = scanned + 1
        if scanned > MIDI_EVENT_SCAN_BUDGET then
            local nextIndex = MIDI_Core.UpperBound(song, MIDI_Engine.CurrentTime, MIDI_Engine.Index)
            dropped = dropped + math.max(0, nextIndex - MIDI_Engine.Index)
            MIDI_Engine.Index = nextIndex
            break
        end

        if MIDI_Engine.MuteDrums and ev.channel == 9 then
            MIDI_Engine.Index = MIDI_Engine.Index + 1
        elseif budget > 0 and MIDI_Engine.NoteTokens >= 1 then
            PlayInstrumentNote(ev.note + MIDI_Engine.Transpose, ev.vel)
            budget = budget - 1
            MIDI_Engine.NoteTokens = MIDI_Engine.NoteTokens - 1
            MIDI_Engine.Index = MIDI_Engine.Index + 1
        else
            local nextIndex = MIDI_Core.UpperBound(song, MIDI_Engine.CurrentTime, MIDI_Engine.Index)
            dropped = dropped + math.max(1, nextIndex - MIDI_Engine.Index)
            MIDI_Engine.Index = nextIndex
            break
        end
    end

    if dropped > 0 then
        MIDI_Engine.DroppedNotes = MIDI_Engine.DroppedNotes + dropped
        if MIDI_Engine.DroppedNotes >= MIDI_DROP_WARN_AT
            and CurTime() - MIDI_Engine.LastDropWarn > MIDI_DROP_WARN_COOLDOWN then
            MIDI_Engine.LastDropWarn = CurTime()
            MIDI_Engine.DroppedNotes = 0
            chat.AddText(Color(255, 190, 80),
                "[MIDI] Song is very dense; notes throttled to keep audio smooth.")
        end
    end

    if MIDI_Engine.Index > total then
        if IsValid(MIDI_Engine.SyncedLeader) then
            MIDI_Engine.CurrentTime = MIDI_Engine.TotalDuration
        elseif MIDI_Engine.Loop then
            MIDI_Engine.Index = 1
            MIDI_Engine.CurrentTime = 0
            MIDI_Engine.DroppedNotes = 0
            RefillNoteTokens()
            MIDI_Engine:SendHostAction("seek", 0)
        else
            MIDI_Engine:Stop()
        end
    end
end)

-- ----------------------------------------------------------------------------
-- 11. HOUSEKEEPING
-- ----------------------------------------------------------------------------
local function MIDI_PrunePitchFireTime(wep)
    if not IsValid(wep) then return end
    local t = wep.PitchFireTime
    if type(t) ~= "table" then return end

    local now = CurTime()
    local ttl = wep.PitchDisplayTime or 1
    for freq, entry in pairs(t) do
        if type(entry) ~= "table" or type(entry[1]) ~= "number"
            or type(entry[2]) ~= "number" or now - entry[1] > ttl then
            t[freq] = nil
        end
    end
end

timer.Create("TheInstrument_MIDI_PrunePitchFireTime", 2, 0, function()
    local ply = LocalPlayer()
    if not IsValid(ply) then return end
    MIDI_PrunePitchFireTime(ply:GetActiveWeapon())
    MIDI_PrunePitchFireTime(ply.ActiveInstrument)
end)

concommand.Add("the_instrument_midi", function() OpenMIDIMenu() end)
