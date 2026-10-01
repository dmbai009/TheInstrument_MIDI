local Core = dofile("lua/the_instrument_midi/midi_core.lua")

local tests = 0

local function check(condition, message)
    tests = tests + 1
    if not condition then error(message or "check failed", 2) end
end

local function near(actual, expected, epsilon, message)
    check(math.abs(actual - expected) <= epsilon,
        (message or "values differ") .. ": expected " .. expected .. ", got " .. actual)
end

local function bytes(...)
    return string.char(...)
end

local function uint16(value)
    return bytes(math.floor(value / 256) % 256, value % 256)
end

local function uint32(value)
    return bytes(
        math.floor(value / 16777216) % 256,
        math.floor(value / 65536) % 256,
        math.floor(value / 256) % 256,
        value % 256
    )
end

local function midi(track, format, division)
    return "MThd" .. uint32(6) .. uint16(format or 0) .. uint16(1) .. uint16(division or 480)
        .. "MTrk" .. uint32(#track) .. track
end

local basicTrack = table.concat({
    bytes(0, 255, 81, 3, 7, 161, 32), -- 120 BPM
    bytes(0, 144, 60, 100),
    bytes(131, 96, 64, 80),           -- running status, +480 ticks
    bytes(0, 255, 47, 0),
})

local song, err = Core.ParseMIDI(midi(basicTrack))
check(song ~= nil, err)
check(#song == 2, "expected two notes")
check(song[1].note == 60 and song[1].vel == 100 and song[1].channel == 0)
check(song[2].note == 64 and song[2].vel == 80)
near(song[1].time, 0, 0.000001)
near(song[2].time, 0.5, 0.000001)

local tempoTrack = table.concat({
    bytes(0, 144, 60, 100),
    bytes(131, 96, 255, 81, 3, 3, 208, 144), -- 240 BPM at 480 ticks
    bytes(131, 96, 144, 64, 100),
    bytes(0, 255, 47, 0),
})
local tempoSong, tempoError = Core.ParseMIDI(midi(tempoTrack))
check(tempoSong ~= nil, tempoError)
near(tempoSong[2].time, 0.75, 0.000001, "tempo change should affect following ticks")

local smpteTrack = table.concat({
    bytes(0, 144, 60, 100),
    bytes(135, 104, 144, 64, 100), -- +1000 ticks
    bytes(0, 255, 47, 0),
})
local smpteDivision = (256 - 25) * 256 + 40 -- 25 FPS, 40 ticks per frame
local smpteSong, smpteError = Core.ParseMIDI(midi(smpteTrack, 0, smpteDivision))
check(smpteSong ~= nil, smpteError)
near(smpteSong[2].time, 1, 0.000001, "SMPTE timing should be supported")

local limited, limitError = Core.ParseMIDI(midi(basicTrack), { maxNotes = 1 })
check(limited == nil and string.find(limitError, "too many notes", 1, true) ~= nil)

local malformed = Core.ParseMIDI(string.sub(midi(basicTrack), 1, -3))
check(malformed == nil, "truncated track must be rejected")

local formatTwo, formatError = Core.ParseMIDI(midi(basicTrack, 2))
check(formatTwo == nil and string.find(formatError, "format 2", 1, true) ~= nil)

local validated, validationError = Core.ValidateSong({
    { 0, 60, 100, 0 },
    { 0.5, 64, 80, 9 },
})
check(validated ~= nil, validationError)
check(#validated == 2 and validated[2].channel == 9)

local unsorted = Core.ValidateSong({ { 1, 60, 100, 0 }, { 0, 61, 100, 0 } })
check(unsorted == nil, "unsorted notes must be rejected")

local badNote = Core.ValidateSong({ { 0, 200, 100, 0 } })
check(badNote == nil, "out-of-range notes must be rejected")

check(Core.LowerBound(validated, 0.25) == 2)
check(Core.LowerBound(validated, 0.5) == 2)
check(Core.UpperBound(validated, 0.5) == 3)

check(Core.IsSafeMIDIFilename("song.mid"))
check(Core.IsSafeMIDIFilename("песня 01.midi"))
check(not Core.IsSafeMIDIFilename("../song.mid"))
check(not Core.IsSafeMIDIFilename("song.txt"))

local transfer = Core.NewTransferState(2)
check(transfer ~= nil)
local accepted, complete = Core.AcceptTransferChunk(transfer, 1, 100, 1, {
    maxChunkBytes = 24000,
    minInterval = 0.02,
})
check(accepted and not complete)
check(not Core.AcceptTransferChunk(transfer, 1, 100, 1.1), "duplicate chunks must be rejected")
check(not Core.AcceptTransferChunk(transfer, 2, 100, 1.01, { minInterval = 0.02 }),
    "chunks that arrive too quickly must be rejected")
accepted, complete = Core.AcceptTransferChunk(transfer, 2, 100, 1.1, {
    maxChunkBytes = 24000,
    minInterval = 0.02,
})
check(accepted and complete)

local oversizedTransfer = Core.NewTransferState(1)
check(not Core.AcceptTransferChunk(oversizedTransfer, 1, 24001, 0, { maxChunkBytes = 24000 }),
    "oversized chunks must be rejected")

print("midi_core: " .. tests .. " checks passed")
