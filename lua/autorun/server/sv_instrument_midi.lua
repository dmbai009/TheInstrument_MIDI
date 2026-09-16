-- ============================================================================
-- The Instrument Midi Choser - Server Sync Relay by dmbai (Phase-Locked)
-- ============================================================================
if CLIENT then return end

util.AddNetworkString("TheInstrument_MIDI_Band_Action")
util.AddNetworkString("TheInstrument_MIDI_Sync_RequestJoin")
util.AddNetworkString("TheInstrument_MIDI_Sync_SendJoinData")
util.AddNetworkString("TheInstrument_MIDI_Sync_Chunk")

util.AddNetworkString("music_mode_note_play_server")
util.AddNetworkString("music_mode_note_play_client")

local MIDI_CHUNK_SIZE   = 24000
local MIDI_MAX_CHUNKS   = 24
local MIDI_JOIN_TIMEOUT = 20
local MIDI_MAX_SESSIONS_PER_HOST = 16
local MIDI_NAME_MAX_LEN          = 64

local cvActionCooldown = CreateConVar("theinstrument_midi_action_cooldown", "0.2",
    bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY), "Cooldown for play/stop actions.", 0, 10)

local cvSliderCooldown = CreateConVar("theinstrument_midi_slider_cooldown", "0.03",
    bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY), "Cooldown for seek/speed actions.", 0, 10)

local cvJoinCooldown = CreateConVar("theinstrument_midi_join_cooldown", "1",
    bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY), "Cooldown for join requests.", 0, 30)

local cvPatchRelay = CreateConVar("theinstrument_midi_patch_relay", "1",
    bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY), "1 = unreliable patched relay.", 0, 1)

local cvNoteRate = CreateConVar("theinstrument_midi_note_rate", "120",
    bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY), "Max notes per second.", 0, 1000)

local cvNoteRadius = CreateConVar("theinstrument_midi_note_radius", "2500",
    bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY), "Audible radius.", 0, 32768)

local function IsFiniteNumber(v)
    if type(v) ~= "number" then return false end
    if v ~= v then return false end
    if v == math.huge or v == -math.huge then return false end
    return true
end

local function SafeNumber(v, fallback, minv, maxv)
    if not IsFiniteNumber(v) then return fallback end
    return math.Clamp(v, minv, maxv)
end

local function SanitizeName(str)
    if type(str) ~= "string" then return "" end
    str = string.sub(str, 1, MIDI_NAME_MAX_LEN)
    str = string.gsub(str, "[%z\1-\31\127]", "")
    return str
end

local function IsLivePlayer(ent)
    return IsValid(ent) and ent:IsPlayer()
end

local nextAction = {}
local nextJoin   = {}
local noteBucket = {}

local function CheckCooldown(tbl, ply, cooldown)
    local now = CurTime()
    local allowed = tbl[ply]
    if allowed and now < allowed then return false end
    tbl[ply] = now + cooldown
    return true
end

local function TakeNoteToken(ply)
    local rate = cvNoteRate:GetFloat()
    if not IsFiniteNumber(rate) or rate <= 0 then return true end

    local now = CurTime()
    local b = noteBucket[ply]
    if not b then
        b = { tokens = rate, last = now }
        noteBucket[ply] = b
    end

    local dt = now - b.last
    if dt > 0 then
        b.tokens = math.min(rate, b.tokens + dt * rate)
        b.last = now
    end

    if b.tokens < 1 then return false end
    b.tokens = b.tokens - 1
    return true
end

local pending = {}

local function ClearSession(host, requester)
    local sessions = pending[host]
    if not sessions then return end
    sessions[requester] = nil
    if next(sessions) == nil then pending[host] = nil end
end

local function GetSession(host, requester)
    local sessions = pending[host]
    if not sessions then return nil end
    local s = sessions[requester]
    if not s then return nil end
    if CurTime() - s.t > MIDI_JOIN_TIMEOUT then
        ClearSession(host, requester)
        return nil
    end
    return s
end

local function CountSessions(sessions)
    local n = 0
    for _ in pairs(sessions) do n = n + 1 end
    return n
end

local function ClearPlayerSessions(ply)
    pending[ply] = nil
    for host, sessions in pairs(pending) do
        sessions[ply] = nil
        if next(sessions) == nil then pending[host] = nil end
    end
end

timer.Create("TheInstrument_MIDI_PruneSessions", 10, 0, function()
    local now = CurTime()
    for host, sessions in pairs(pending) do
        if not IsLivePlayer(host) then
            pending[host] = nil
        else
            for requester, s in pairs(sessions) do
                if not IsLivePlayer(requester) or now - s.t > MIDI_JOIN_TIMEOUT then
                    sessions[requester] = nil
                end
            end
            if next(sessions) == nil then pending[host] = nil end
        end
    end
end)

local VALID_ACTIONS = {
    ["play"]  = true,
    ["seek"]  = true,
    ["pause"] = true,
    ["speed"] = true,
    ["sync"]  = true,
    ["stop"]  = true,
}

local SLIDER_ACTIONS = {
    ["seek"]  = true,
    ["speed"] = true,
    ["sync"]  = true,
}

net.Receive("TheInstrument_MIDI_Band_Action", function(len, host)
    local action = net.ReadString()

    if not IsLivePlayer(host) then return end
    if not VALID_ACTIONS[action] then return end

    local cooldown = SLIDER_ACTIONS[action] and cvSliderCooldown:GetFloat() or cvActionCooldown:GetFloat()
    if not CheckCooldown(nextAction, host, cooldown) then return end

    if action == "play" then
        local songName = SanitizeName(net.ReadString())
        local speed = SafeNumber(net.ReadFloat(), 1, 0.1, 4)

        host:SetNW2Bool("MIDI_IsPlaying", true)
        host:SetNW2Bool("MIDI_IsPaused", false)
        host:SetNW2String("MIDI_SongName", songName)
        host:SetNW2Float("MIDI_Speed", speed)

        net.Start("TheInstrument_MIDI_Band_Action")
            net.WriteEntity(host)
            net.WriteString("play")
            net.WriteString(songName)
            net.WriteFloat(speed)
        net.Broadcast()

    elseif action == "seek" then
        local targetTime = SafeNumber(net.ReadFloat(), 0, 0, 86400)
        net.Start("TheInstrument_MIDI_Band_Action")
            net.WriteEntity(host)
            net.WriteString("seek")
            net.WriteFloat(targetTime)
        net.Broadcast()

    elseif action == "pause" then
        local isPaused = net.ReadBool() and true or false
        host:SetNW2Bool("MIDI_IsPaused", isPaused)

        net.Start("TheInstrument_MIDI_Band_Action")
            net.WriteEntity(host)
            net.WriteString("pause")
            net.WriteBool(isPaused)
        net.Broadcast()

    elseif action == "speed" then
        local speed = SafeNumber(net.ReadFloat(), 1, 0.1, 4)
        local curTime = SafeNumber(net.ReadFloat(), 0, 0, 86400)
        host:SetNW2Float("MIDI_Speed", speed)

        net.Start("TheInstrument_MIDI_Band_Action")
            net.WriteEntity(host)
            net.WriteString("speed")
            net.WriteFloat(speed)
            net.WriteFloat(curTime)
        net.Broadcast()

    elseif action == "sync" then
        local curTime = SafeNumber(net.ReadFloat(), 0, 0, 86400)
        net.Start("TheInstrument_MIDI_Band_Action", true)
            net.WriteEntity(host)
            net.WriteString("sync")
            net.WriteFloat(curTime)
        net.Broadcast()

    elseif action == "stop" then
        host:SetNW2Bool("MIDI_IsPlaying", false)
        host:SetNW2Bool("MIDI_IsPaused", false)
        host:SetNW2String("MIDI_SongName", "")

        net.Start("TheInstrument_MIDI_Band_Action")
            net.WriteEntity(host)
            net.WriteString("stop")
        net.Broadcast()
    end
end)

net.Receive("TheInstrument_MIDI_Sync_RequestJoin", function(len, requester)
    local target = net.ReadEntity()
    local needsNotes = net.ReadBool() and true or false

    if not IsLivePlayer(requester) or not IsLivePlayer(target) then return end
    if target == requester or not target:GetNW2Bool("MIDI_IsPlaying") then return end
    if not CheckCooldown(nextJoin, requester, cvJoinCooldown:GetFloat()) then return end

    local sessions = pending[target]
    if not sessions then
        sessions = {}
        pending[target] = sessions
    end

    if sessions[requester] == nil and CountSessions(sessions) >= MIDI_MAX_SESSIONS_PER_HOST then
        return
    end

    sessions[requester] = { t = CurTime(), expected = 0 }

    net.Start("TheInstrument_MIDI_Sync_RequestJoin")
        net.WriteEntity(requester)
        net.WriteBool(needsNotes)
    net.Send(target)
end)

net.Receive("TheInstrument_MIDI_Sync_SendJoinData", function(len, host)
    local requester   = net.ReadEntity()
    local songName    = SanitizeName(net.ReadString())
    local curTime     = net.ReadFloat()
    local speed       = net.ReadFloat()
    local isPaused    = net.ReadBool() and true or false
    local hasNotes    = net.ReadBool() and true or false
    local totalChunks = net.ReadUInt(8)

    if not IsLivePlayer(host) or not IsLivePlayer(requester) then return end

    local session = GetSession(host, requester)
    if not session then return end

    curTime = SafeNumber(curTime, 0, 0, 86400)
    speed   = SafeNumber(speed, 1, 0.1, 4)

    if hasNotes then
        if totalChunks < 1 or totalChunks > MIDI_MAX_CHUNKS then
            ClearSession(host, requester)
            return
        end
        session.expected = totalChunks
        session.t = CurTime()
    else
        totalChunks = 0
    end

    net.Start("TheInstrument_MIDI_Sync_SendJoinData")
        net.WriteEntity(host)
        net.WriteString(songName)
        net.WriteFloat(curTime)
        net.WriteFloat(speed)
        net.WriteBool(isPaused)
        net.WriteBool(hasNotes)
        net.WriteUInt(totalChunks, 8)
    net.Send(requester)

    if not hasNotes then
        ClearSession(host, requester)
    end
end)

net.Receive("TheInstrument_MIDI_Sync_Chunk", function(len, host)
    local requester  = net.ReadEntity()
    local chunkIndex = net.ReadUInt(8)
    local dataLen    = net.ReadUInt(16)

    if dataLen < 1 or dataLen > MIDI_CHUNK_SIZE then return end
    local part = net.ReadData(dataLen)
    if type(part) ~= "string" or #part < 1 then return end

    if not IsLivePlayer(host) or not IsLivePlayer(requester) then return end

    local session = GetSession(host, requester)
    if not session or session.expected < 1 then return end
    if chunkIndex < 1 or chunkIndex > session.expected then return end

    session.t = CurTime()

    net.Start("TheInstrument_MIDI_Sync_Chunk")
        net.WriteEntity(host)
        net.WriteUInt(chunkIndex, 8)
        net.WriteUInt(dataLen, 16)
        net.WriteData(part, dataLen)
    net.Send(requester)

    if chunkIndex == session.expected then
        ClearSession(host, requester)
    end
end)

local function StopPlaybackFor(ply)
    if not IsLivePlayer(ply) then return end
    local wasPlaying = ply:GetNW2Bool("MIDI_IsPlaying")

    ply:SetNW2Bool("MIDI_IsPlaying", false)
    ply:SetNW2Bool("MIDI_IsPaused", false)
    ply:SetNW2String("MIDI_SongName", "")

    if not wasPlaying then return end

    net.Start("TheInstrument_MIDI_Band_Action")
        net.WriteEntity(ply)
        net.WriteString("stop")
    net.Broadcast()
end

hook.Add("PlayerDeath", "TheInstrument_MIDI_StopOnDeath", function(ply)
    StopPlaybackFor(ply)
end)

hook.Add("PlayerDisconnected", "TheInstrument_MIDI_StopOnDisconnect", function(ply)
    StopPlaybackFor(ply)
    ClearPlayerSessions(ply)
    nextAction[ply] = nil
    nextJoin[ply]   = nil
    noteBucket[ply] = nil
end)

local SOUND_PATTERN = "^instrument/[%w_%-]+/c[2-6]%.wav$"

local function WriteNotePayload(wep, own, sound_file, level, pitch, volume,
                                channel, abs_pitch, inst_id, degree, speaker)
    net.WriteEntity(wep)
    net.WriteEntity(own)
    net.WriteString(sound_file)
    net.WriteInt(level, 32)
    net.WriteInt(pitch, 32)
    net.WriteFloat(volume)
    net.WriteInt(channel, 32)
    net.WriteFloat(abs_pitch)
    net.WriteInt(inst_id, 32)
    net.WriteInt(degree, 32)
    net.WriteEntity(speaker)
end

local function GetNoteListeners(performer, origin, radius)
    local targets = {}
    local unlimited = (not IsFiniteNumber(radius)) or radius <= 0
    local radiusSqr = unlimited and 0 or (radius * radius)

    for _, p in ipairs(player.GetAll()) do
        if IsValid(p) and p ~= performer then
            if unlimited or p:GetPos():DistToSqr(origin) <= radiusSqr then
                targets[#targets + 1] = p
            end
        end
    end

    return targets
end

local function MIDI_NotePlayServer(len, ply)
    local wep        = net.ReadEntity()
    local own        = net.ReadEntity()
    local sound_file = net.ReadString()
    local level      = net.ReadInt(32)
    local pitch      = net.ReadInt(32)
    local volume     = net.ReadFloat()
    local channel    = net.ReadInt(32)
    local abs_pitch  = net.ReadFloat()
    local inst_id    = net.ReadInt(32)
    local degree     = net.ReadInt(32)
    local speaker    = net.ReadEntity()

    if not IsValid(wep) or not IsValid(own) then return end
    if type(sound_file) ~= "string" then return end
    if level == nil or pitch == nil or volume == nil or channel == nil then return end

    if not cvPatchRelay:GetBool() then
        net.Start("music_mode_note_play_client")
            WriteNotePayload(wep, own, sound_file, level, pitch, volume,
                             channel, abs_pitch, inst_id, degree, speaker)
        net.Broadcast()
        return
    end

    if own ~= ply then return end
    if not string.match(sound_file, SOUND_PATTERN) then return end
    if not IsFiniteNumber(volume) or not IsFiniteNumber(abs_pitch) then return end

    pitch     = math.floor(SafeNumber(pitch, 100, 1, 255))
    volume    = SafeNumber(volume, 1, 0, 1)
    level     = math.floor(SafeNumber(level, 75, 0, 511))
    channel   = math.floor(SafeNumber(channel, CHAN_STATIC or 6, -1, 135))
    abs_pitch = SafeNumber(abs_pitch, 100, 0, 100000)
    inst_id   = math.floor(SafeNumber(inst_id, 1, 1, 3))
    degree    = math.floor(SafeNumber(degree, 0, 0, 127))

    if not TakeNoteToken(ply) then return end

    local origin
    if IsValid(speaker) then
        origin = speaker:WorldSpaceCenter()
    else
        origin = own:GetPos()
    end

    local targets = GetNoteListeners(own, origin, cvNoteRadius:GetFloat())
    if #targets == 0 then return end

    net.Start("music_mode_note_play_client", true)
        WriteNotePayload(wep, own, sound_file, level, pitch, volume,
                         channel, abs_pitch, inst_id, degree, speaker)
    net.Send(targets)
end

net.Receive("music_mode_note_play_server", MIDI_NotePlayServer)

hook.Add("InitPostEntity", "TheInstrument_MIDI_ReassertNoteRelay", function()
    if net.Receivers and net.Receivers["music_mode_note_play_server"] ~= MIDI_NotePlayServer then
        net.Receive("music_mode_note_play_server", MIDI_NotePlayServer)
    end
end)