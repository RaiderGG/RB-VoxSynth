-- RB VoxSynth Parser
-- Support for VOCALS and HARM Tracks
local r = reaper
r.gmem_attach("RBVoxSynth")

local NOTE  = 0
local SLIDE = 1

local OFFSETS = {
    ["PART VOCALS"] = 0,
    ["HARM1"]       = 100000,
    ["HARM2"]       = 200000,
    ["HARM3"]       = 300000
}
local PART_IDX = {
    ["PART VOCALS"] = 0,
    ["HARM1"]       = 1,
    ["HARM2"]       = 2,
    ["HARM3"]       = 3
}
local hashes = {}

--------------------------------------------------
-- Helpers
--------------------------------------------------
local function stringstarts(String,Start)
	return string.sub(String,1,string.len(Start))==Start
end

local function ClosestLyric(lyrics, ppq)

    local best = ""
    local dist = math.huge
    local bestIndex

    for i=1,#lyrics do

        local d =
        math.abs(
            lyrics[i].ppq - ppq
        )

        if d < dist then
            dist = d
            best = lyrics[i].text
            bestIndex = i
        end
    end

    return best, bestIndex
end


-- Build note timeline for FX


local function BuildTimeline(take,offset)

    local _, noteCount, _, textCount =
        r.MIDI_CountEvts(take)

    local lyrics = {}


    -- Lyrics
    for i=0,textCount-1 do
        local exists, _, _, ppq, typ, text = r.MIDI_GetTextSysexEvt(take, i)

        if exists and typ == 5 and not stringstarts(text, "[") then
            lyrics[#lyrics+1] = {
                ppq = ppq,
                text = text
            }
        end
    end


    -- Notes
    local notes = {}
    for i=0,noteCount-1 do
        local _,_,_,s,e,_,pitch,_ =r.MIDI_GetNote(take, i)

        if pitch >= 36 and pitch <= 84 then
            local lyric, lyricIdx = ClosestLyric(lyrics, s)
            notes[#notes+1] = {
                startppq = s,
                endppq   = e,
                startsec =
                    r.MIDI_GetProjTimeFromPPQPos(take,s),
                endsec =
                    r.MIDI_GetProjTimeFromPPQPos(take,e),
                pitch = pitch,
                lyric = lyric,
                lyricIdx = lyricIdx
            }
        end
    end

    table.sort(
        notes,
        function(a,b)
            return a.startsec < b.startsec
        end
    )

    -- Write Segments
    local addr = offset + 1
    local count = 0

    local function WriteSeg(typ,startt,endt,p1,p2)
        r.gmem_write(addr + 0,typ)
        r.gmem_write(addr + 1,startt)
        r.gmem_write(addr + 2,endt)
        r.gmem_write(addr + 3,p1)
        r.gmem_write(addr + 4,p2)
        addr = addr + 5
        count = count + 1

    end


    -- Vocal Groups

    local i = 1
    local usedSlideMarkers = {}

    while i <= #notes do

        local current =
            notes[i]

        WriteSeg(
            NOTE,
            current.startsec,
            current.endsec,
            current.pitch,
            current.pitch
        )

        while
            i < #notes
            and notes[i+1].lyric == "+"
            and not usedSlideMarkers[notes[i+1].lyricIdx]
        do

            local nxt =
                notes[i+1]

            -- Slide only inside group
            if nxt.startsec > current.endsec then
                WriteSeg(SLIDE, current.endsec, nxt.startsec, current.pitch, nxt.pitch)
            end

            WriteSeg(NOTE, nxt.startsec, nxt.endsec, nxt.pitch, nxt.pitch)

            current = nxt
            usedSlideMarkers[nxt.lyricIdx] = true
            i = i + 1
        end

        i = i + 1
    end

    r.gmem_write(
        offset,
        count
    )
end


-- FX Management


local FX_NAME = "RB VoxSynth"

local function EnsurePreviewFX(track, partIdx)

    local fxCount =
        r.TrackFX_GetCount(track)
    local fx = -1

    for i = 0, fxCount-1 do
        local _, name =r.TrackFX_GetFXName(track,i)

        if name:find(FX_NAME,1,true) then
            fx = i
            break
        end
    end

--Create FX if not found
    if fx < 0 then
        fx = r.TrackFX_AddByName(track,FX_NAME,false,-1)
            --r.ShowConsoleMsg(string.format(" %s inserted \n", FX_NAME))
    end

    -- Configure slider6 in each FX instance
    if fx >= 0 then
        local target = partIdx 
        local current = r.TrackFX_GetParam(track,fx,5)

        if math.abs(current-target) > 0.001 then
            r.TrackFX_SetParam(track, fx, 5, target)
        end
    end

    return fx

end


-- Find Vocal Tracks
local function ParseProject()
    local trackCount =
        r.CountTracks(0)

    for i=0,trackCount-1 do
        local track =
            r.GetTrack(0,i)
        local _, name =r.GetTrackName(track)
        local offset = OFFSETS[name]           
        local partIdx = PART_IDX[name]

        if partIdx then EnsurePreviewFX(track, partIdx) end
        if offset then
            local item = r.GetTrackMediaItem(track, 0)
            if item then
                local take = r.GetActiveTake(item)
                if take and r.TakeIsMIDI(take)
                then
                    local _,hash = r.MIDI_GetHash(take, false)
                    local key =
                        name .."|" ..hash
                    if hashes[name] ~= key then
                        hashes[name] = key
                        BuildTimeline(take, offset)
                        --r.ShowConsoleMsg(string.format("Track %s updated\n",name))
                    end
                end
            end
        end
    end
end



local function Loop()
    ParseProject()
    r.defer(Loop)
end


Loop()
