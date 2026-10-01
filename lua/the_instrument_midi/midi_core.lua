local Core = {}

local DEFAULT_MAX_FILE_BYTES = 4 * 1024 * 1024
local DEFAULT_MAX_NOTES = 200000
local DEFAULT_MAX_EVENTS = 400000
local DEFAULT_MAX_TRACKS = 512
local DEFAULT_MAX_DURATION = 86400

local function finite(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function option(options, name, fallback)
    local value = options and options[name]
    if not finite(value) then return fallback end
    return value
end

function Core.IsFiniteNumber(value)
    return finite(value)
end

function Core.IsSafeMIDIFilename(name, maxLength)
    if type(name) ~= "string" or #name < 1 or #name > (maxLength or 64) then return false end
    if name == "." or name == ".." then return false end
    if string.find(name, "[%z\1-\31\127/\\:*?\"<>|]") then return false end

    local lower = string.lower(name)
    return string.sub(lower, -4) == ".mid" or string.sub(lower, -5) == ".midi"
end

function Core.LowerBound(song, target, first)
    local low = math.max(1, math.floor(first or 1))
    local high = #song + 1

    while low < high do
        local middle = math.floor((low + high) / 2)
        if song[middle].time < target then
            low = middle + 1
        else
            high = middle
        end
    end

    return low
end

function Core.UpperBound(song, target, first)
    local low = math.max(1, math.floor(first or 1))
    local high = #song + 1

    while low < high do
        local middle = math.floor((low + high) / 2)
        if song[middle].time <= target then
            low = middle + 1
        else
            high = middle
        end
    end

    return low
end

function Core.ValidateSong(simple, options)
    if type(simple) ~= "table" or #simple == 0 then
        return nil, "Song contains no notes"
    end

    local maxNotes = math.floor(option(options, "maxNotes", DEFAULT_MAX_NOTES))
    local maxDuration = option(options, "maxDuration", DEFAULT_MAX_DURATION)
    if #simple > maxNotes then
        return nil, "Song contains too many notes"
    end

    local song = {}
    local previousTime = -1

    for i = 1, #simple do
        local row = simple[i]
        if type(row) ~= "table" then
            return nil, "Invalid note at index " .. i
        end

        local time = row[1]
        local note = row[2]
        local velocity = row[3]
        local channel = row[4]

        if velocity == nil then velocity = 100 end
        if channel == nil then channel = 0 end

        if not finite(time) or time < 0 or time > maxDuration or time < previousTime then
            return nil, "Invalid note time at index " .. i
        end
        if not finite(note) or note % 1 ~= 0 or note < 0 or note > 127 then
            return nil, "Invalid note value at index " .. i
        end
        if not finite(velocity) or velocity % 1 ~= 0 or velocity < 0 or velocity > 127 then
            return nil, "Invalid velocity at index " .. i
        end
        if not finite(channel) or channel % 1 ~= 0 or channel < 0 or channel > 15 then
            return nil, "Invalid channel at index " .. i
        end

        song[i] = { time = time, note = note, vel = velocity, channel = channel }
        previousTime = time
    end

    return song
end

function Core.NewTransferState(expected)
    if not finite(expected) or expected % 1 ~= 0 or expected < 1 then return nil end
    return {
        expected = expected,
        received = 0,
        bytes = 0,
        nextChunkAt = 0,
        seen = {},
    }
end

function Core.AcceptTransferChunk(state, index, byteCount, now, options)
    if type(state) ~= "table" or type(state.seen) ~= "table" then
        return false, "invalid transfer state"
    end

    local maxChunkBytes = math.floor(option(options, "maxChunkBytes", 24000))
    local minInterval = option(options, "minInterval", 0)

    if not finite(index) or index % 1 ~= 0 or index < 1 or index > state.expected then
        return false, "invalid chunk index"
    end
    if not finite(byteCount) or byteCount % 1 ~= 0 or byteCount < 1 or byteCount > maxChunkBytes then
        return false, "invalid chunk size"
    end
    if not finite(now) then return false, "invalid transfer time" end
    if state.seen[index] then return false, "duplicate chunk" end
    if now < state.nextChunkAt then return false, "chunks arrived too quickly" end
    if state.bytes + byteCount > state.expected * maxChunkBytes then
        return false, "transfer exceeds its byte limit"
    end

    state.seen[index] = true
    state.received = state.received + 1
    state.bytes = state.bytes + byteCount
    state.nextChunkAt = now + minInterval
    return true, state.received >= state.expected
end

function Core.ParseMIDI(data, options)
    if type(data) ~= "string" then return nil, "No file data" end

    local length = #data
    local maxFileBytes = math.floor(option(options, "maxFileBytes", DEFAULT_MAX_FILE_BYTES))
    local maxNotes = math.floor(option(options, "maxNotes", DEFAULT_MAX_NOTES))
    local maxEvents = math.floor(option(options, "maxEvents", DEFAULT_MAX_EVENTS))
    local maxTracks = math.floor(option(options, "maxTracks", DEFAULT_MAX_TRACKS))
    local maxDuration = option(options, "maxDuration", DEFAULT_MAX_DURATION)

    if length < 14 then return nil, "File is too small to be a MIDI" end
    if length > maxFileBytes then return nil, "MIDI file is too large" end

    local position = 1

    local function readString(count, limit)
        limit = limit or length
        if count < 0 or position + count - 1 > limit or position + count - 1 > length then
            return nil
        end
        local value = string.sub(data, position, position + count - 1)
        position = position + count
        return value
    end

    local function readByte(limit)
        limit = limit or length
        if position > limit or position > length then return nil end
        local value = string.byte(data, position)
        position = position + 1
        return value
    end

    local function readUInt16(limit)
        local high, low = readByte(limit), readByte(limit)
        if high == nil or low == nil then return nil end
        return high * 256 + low
    end

    local function readUInt32(limit)
        local b1, b2, b3, b4 = readByte(limit), readByte(limit), readByte(limit), readByte(limit)
        if b1 == nil or b2 == nil or b3 == nil or b4 == nil then return nil end
        return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
    end

    local function readVLQ(limit)
        local value = 0
        for _ = 1, 4 do
            local byte = readByte(limit)
            if byte == nil then return nil end
            value = value * 128 + (byte % 128)
            if byte < 128 then return value end
        end
        return nil
    end

    if readString(4) ~= "MThd" then return nil, "Invalid MIDI header" end

    local headerLength = readUInt32()
    if not headerLength or headerLength < 6 or position + headerLength - 1 > length then
        return nil, "Invalid MIDI header length"
    end

    local headerEnd = position + headerLength - 1
    local format = readUInt16(headerEnd)
    local trackCount = readUInt16(headerEnd)
    local division = readUInt16(headerEnd)
    if format == nil or trackCount == nil or division == nil then return nil, "Truncated MIDI header" end
    if format > 1 then return nil, "MIDI format 2 is not supported" end
    if trackCount < 1 or trackCount > maxTracks then return nil, "Invalid MIDI track count" end
    if division == 0 then return nil, "Invalid MIDI timing division" end
    position = headerEnd + 1

    local events = {}
    local sequence = 0
    local parsedEvents = 0
    local parsedTracks = 0

    local function addEvent(event)
        sequence = sequence + 1
        event.sequence = sequence
        events[#events + 1] = event
    end

    while position <= length - 7 and parsedTracks < trackCount do
        local chunkType = readString(4)
        local chunkLength = readUInt32()
        if not chunkType or not chunkLength or position + chunkLength - 1 > length then
            return nil, "Truncated MIDI chunk"
        end

        local chunkEnd = position + chunkLength - 1
        if chunkType ~= "MTrk" then
            position = chunkEnd + 1
        else
            parsedTracks = parsedTracks + 1
            local absoluteTicks = 0
            local runningStatus = nil

            while position <= chunkEnd do
                parsedEvents = parsedEvents + 1
                if parsedEvents > maxEvents then return nil, "MIDI contains too many events" end

                local delta = readVLQ(chunkEnd)
                if delta == nil then return nil, "Invalid MIDI delta time" end
                absoluteTicks = absoluteTicks + delta

                local status = readByte(chunkEnd)
                if status == nil then return nil, "Truncated MIDI event" end

                if status < 128 then
                    if not runningStatus then return nil, "Invalid MIDI running status" end
                    position = position - 1
                    status = runningStatus
                elseif status < 240 then
                    runningStatus = status
                else
                    runningStatus = nil
                end

                if status == 255 then
                    local metaType = readByte(chunkEnd)
                    local metaLength = readVLQ(chunkEnd)
                    if metaType == nil or metaLength == nil then return nil, "Truncated MIDI meta event" end
                    local metaData = readString(metaLength, chunkEnd)
                    if metaData == nil then return nil, "Truncated MIDI meta data" end

                    if metaType == 81 and #metaData == 3 then
                        local b1, b2, b3 = string.byte(metaData, 1, 3)
                        local tempo = b1 * 65536 + b2 * 256 + b3
                        if tempo > 0 then
                            addEvent({ ticks = absoluteTicks, type = "tempo", tempo = tempo })
                        end
                    elseif metaType == 47 then
                        position = chunkEnd + 1
                        break
                    end
                elseif status == 240 or status == 247 then
                    local sysexLength = readVLQ(chunkEnd)
                    if sysexLength == nil or readString(sysexLength, chunkEnd) == nil then
                        return nil, "Truncated MIDI system event"
                    end
                elseif status >= 240 then
                    return nil, "Unsupported MIDI system event"
                else
                    local eventType = status - (status % 16)
                    local channel = status % 16
                    local dataLength = (eventType == 192 or eventType == 208) and 1 or 2
                    local first = readByte(chunkEnd)
                    local second = dataLength == 2 and readByte(chunkEnd) or 0

                    if first == nil or second == nil or first >= 128 or second >= 128 then
                        return nil, "Invalid MIDI channel event"
                    end

                    if eventType == 144 and second > 0 then
                        addEvent({
                            ticks = absoluteTicks,
                            type = "note",
                            note = first,
                            velocity = second,
                            channel = channel,
                        })
                    end
                end
            end

            position = chunkEnd + 1
        end
    end

    if parsedTracks ~= trackCount then return nil, "MIDI is missing one or more tracks" end
    if #events == 0 then return nil, "MIDI contains no playable notes" end

    table.sort(events, function(left, right)
        if left.ticks == right.ticks then return left.sequence < right.sequence end
        return left.ticks < right.ticks
    end)

    local smpte = division >= 32768
    local secondsPerTick = nil
    if smpte then
        local frameCode = 256 - math.floor(division / 256)
        local framesPerSecond = frameCode == 29 and 29.97 or frameCode
        local ticksPerFrame = division % 256
        if (framesPerSecond ~= 24 and framesPerSecond ~= 25 and framesPerSecond ~= 29.97
                and framesPerSecond ~= 30) or ticksPerFrame < 1 then
            return nil, "Invalid SMPTE timing division"
        end
        secondsPerTick = 1 / (framesPerSecond * ticksPerFrame)
    end

    local tempo = 500000
    local currentTime = 0
    local previousTicks = 0
    local notes = {}

    for _, event in ipairs(events) do
        local deltaTicks = event.ticks - previousTicks
        if smpte then
            currentTime = currentTime + deltaTicks * secondsPerTick
        else
            currentTime = currentTime + deltaTicks * (tempo / (division * 1000000))
        end
        previousTicks = event.ticks

        if currentTime > maxDuration then return nil, "MIDI is longer than the allowed duration" end

        if event.type == "tempo" then
            if not smpte then tempo = event.tempo end
        else
            if #notes >= maxNotes then return nil, "MIDI contains too many notes" end
            notes[#notes + 1] = {
                time = currentTime,
                note = event.note,
                vel = event.velocity,
                channel = event.channel,
            }
        end
    end

    if #notes == 0 then return nil, "MIDI contains no note-on events" end
    return notes
end

return Core
