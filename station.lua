-- CC:Tweaked mining base station (Advanced Computer)
-- Peripherals: wireless modem, 4x2 monitor (top), speaker (left)
-- Pair with mine.lua on your wireless mining turtle.

local PROTOCOL = "atm10_mining"
local TURTLE_ID = nil -- set after first pairing, or hardcode e.g. 42

local FUEL_WARN = 200
local FUEL_CRITICAL = 50

-- ---------------------------------------------------------------------------
-- Peripherals
-- ---------------------------------------------------------------------------

local function findSide(kind)
    for _, side in ipairs(redstone.getSides()) do
        if peripheral.getType(side) == kind then
            return side
        end
    end
    return nil
end

local modemSide = findSide("modem")
if not modemSide then
    print("No wireless modem found!")
    return
end
rednet.open(modemSide)

local monitor = peripheral.find("monitor")
if not monitor then
    print("No monitor found!")
    return
end
monitor.setTextScale(0.5)

local monW, monH = monitor.getSize()
local COL_SPLIT = math.floor(monW / 2) + 1

local speakerSide = findSide("speaker")
local speaker = speakerSide and peripheral.wrap(speakerSide) or nil
if not speaker then
    print("Warning: no speaker found")
end

local AUDIO_FILE = "ready-to-pair.dfpwm"
local AUDIO_URL = "https://raw.githubusercontent.com/amexrip/cc-atm10/main/ready-to-pair.dfpwm"

-- ---------------------------------------------------------------------------
-- Sounds
-- ---------------------------------------------------------------------------

local function playOreChime()
    if not speaker then return end
    speaker.playSound("entity.experience_orb.pickup", 1.0, 1.6)
    sleep(0.05)
    speaker.playSound("block.note_block.pling", 0.8, 1.8)
end

local function playFuelAlert()
    if not speaker then return end
    for _ = 1, 3 do
        speaker.playSound("block.note_block.bass", 1.0, 0.6)
        sleep(0.25)
    end
end

local function ensurePairingSound()
    if fs.exists(AUDIO_FILE) then return true end
    if not http then
        print("HTTP is off; cannot download pairing sound")
        return false
    end
    print("Downloading pairing sound...")
    local h, err = http.get(AUDIO_URL, nil, true)
    if not h then
        print("Pairing sound download failed: " .. tostring(err))
        return false
    end
    local f = fs.open(AUDIO_FILE, "wb")
    f.write(h.readAll())
    f.close()
    h.close()
    return fs.exists(AUDIO_FILE)
end

-- Bluetooth-style clip on the speaker until a turtle pairs.
local function playPairingSound()
    if TURTLE_ID or not speaker then return end
    if not ensurePairingSound() then return end
    local ok, dfpwm = pcall(require, "cc.audio.dfpwm")
    if not ok or not dfpwm then
        print("This CC version cannot play DFPWM audio")
        return
    end
    print("Playing pairing sound on speaker")
    while not TURTLE_ID do
        local decoder = dfpwm.make_decoder()
        local h = fs.open(AUDIO_FILE, "rb")
        if not h then return end
        while not TURTLE_ID do
            local chunk = h.read(16 * 1024)
            if not chunk then break end
            local buffer = decoder(chunk)
            while not TURTLE_ID do
                if speaker.playAudio(buffer, 1.5) then break end
                os.pullEvent("speaker_audio_empty")
            end
        end
        h.close()
        if TURTLE_ID then break end
        sleep(1.2)
    end
    pcall(function() speaker.stop() end)
end

-- ---------------------------------------------------------------------------
-- State + UI
-- ---------------------------------------------------------------------------

local stats = {}
local totalMined = 0
local oreCount = 0
local lastBlock = "-"
local lastOre = "-"
local turtleFuel = "?"
local turtleLabel = "waiting..."
local statusLine = "Listening..."
local lastFuelAlert = 0
local turtlePos = "-"
local pendingOreSounds = 0
local dirty = false

local function shortName(name, maxLen)
    maxLen = maxLen or 22
    if not name then return "-" end
    local s = name:gsub("minecraft:", ""):gsub(":", "/")
    if #s > maxLen then s = s:sub(1, maxLen - 3) .. "..." end
    return s
end

local function writeAt(x, y, text, color)
    monitor.setCursorPos(x, y)
    if color then monitor.setTextColor(color) end
    monitor.setBackgroundColor(colors.black)
    monitor.write(tostring(text))
end

local function topBlocks(limit)
    local list = {}
    for name, count in pairs(stats) do
        list[#list + 1] = { name = name, count = count }
    end
    table.sort(list, function(a, b) return a.count > b.count end)
    local out = {}
    for i = 1, math.min(limit, #list) do
        out[i] = list[i]
    end
    return out
end

local function draw()
    monW, monH = monitor.getSize()
    COL_SPLIT = math.floor(monW / 2) + 1
    local nameWidth = math.max(8, COL_SPLIT - 8)

    monitor.setBackgroundColor(colors.black)
    monitor.clear()

    writeAt(1, 1, string.rep(" ", math.max(0, math.floor((monW - 22) / 2))) .. "ATM10 Mining Station", colors.cyan)
    writeAt(1, 2, string.format("Station %d  |  Turtle %s  |  %s",
        os.getComputerID(), tostring(TURTLE_ID or "?"), statusLine), colors.lightGray)

    writeAt(1, 4, turtleLabel, colors.yellow)
    writeAt(1, 5, string.format("Mined: %d", totalMined), colors.white)
    writeAt(1, 6, string.format("Ores:  %d", oreCount), colors.orange)
    writeAt(1, 7, "Fuel:  " .. tostring(turtleFuel), colors.lightBlue)
    writeAt(1, 8, "Last:  " .. shortName(lastBlock, nameWidth), colors.lime)
    writeAt(1, 9, "Ore:   " .. shortName(lastOre, nameWidth), colors.yellow)
    writeAt(1, 10, "Pos:   " .. tostring(turtlePos), colors.gray)

    writeAt(COL_SPLIT, 4, "Top blocks mined:", colors.white)

    local top = topBlocks(12)
    local row = 5
    local half = math.max(1, math.ceil(#top / 2))
    for i = 1, half do
        local left = top[i]
        local right = top[i + half]
        if left then
            writeAt(COL_SPLIT, row,
                string.format("%2d. %-18s %5d", i, shortName(left.name, 18), left.count), colors.lightGray)
        end
        if right then
            local rightCol = COL_SPLIT + math.floor((monW - COL_SPLIT) / 2)
            writeAt(rightCol, row,
                string.format("%2d. %-18s %5d", i + half, shortName(right.name, 18), right.count), colors.lightGray)
        end
        row = row + 1
        if row > monH - 1 then break end
    end

    writeAt(1, monH, statusLine, colors.yellow)
    dirty = false
end

local function addMined(block, count)
    if not block then return end
    count = count or 1
    stats[block] = (stats[block] or 0) + count
    totalMined = totalMined + count
    lastBlock = block
    dirty = true
end

local function addOre(block)
    if not block then return end
    oreCount = oreCount + 1
    lastOre = block
    pendingOreSounds = pendingOreSounds + 1
    dirty = true
end

-- ---------------------------------------------------------------------------
-- Message handling (no draw here - main loop draws after draining)
-- ---------------------------------------------------------------------------

local function handleMessage(msg, sender)
    if type(msg) ~= "table" or not msg.type then return end

    if msg.type == "hello" then
        TURTLE_ID = sender
        turtleLabel = msg.label or ("Turtle " .. sender)
        statusLine = "Linked!"
        if msg.fuel then turtleFuel = msg.fuel end
        dirty = true
        rednet.send(sender, { type = "ack", stationId = os.getComputerID() }, PROTOCOL)
        return
    end

    if TURTLE_ID and sender ~= TURTLE_ID then return end

    if msg.fuel then
        turtleFuel = msg.fuel
        dirty = true
    end
    if msg.level then
        turtleFuel = msg.level
        dirty = true
    end
    if msg.label then
        turtleLabel = msg.label
        dirty = true
    end
    if msg.status then
        statusLine = msg.status
        dirty = true
    end
    if msg.x and msg.y and msg.z then
        turtlePos = string.format("%d %d %d", msg.x, msg.y, msg.z)
        dirty = true
    end
    if msg.lastBlock then lastBlock = msg.lastBlock dirty = true end
    if msg.lastOre then lastOre = msg.lastOre dirty = true end

    if msg.type == "update" then
        if type(msg.mined) == "table" then
            for _, entry in ipairs(msg.mined) do
                if type(entry) == "table" then
                    addMined(entry.block, entry.count)
                end
            end
        end
        if type(msg.ores) == "table" then
            for _, entry in ipairs(msg.ores) do
                if type(entry) == "table" then
                    addOre(entry.block)
                elseif type(entry) == "string" then
                    addOre(entry)
                end
            end
        end
        return
    end

    if msg.type == "mined" and msg.block then
        addMined(msg.block, msg.count or 1)
        return
    end

    if msg.type == "ore" and msg.block then
        addOre(msg.block)
        statusLine = "Ore found!"
        return
    end

    if msg.type == "fuel" then
        statusLine = msg.warning and "LOW FUEL" or "Fuel update"
        if msg.warning and (os.clock() - lastFuelAlert) > 8 then
            lastFuelAlert = os.clock()
            playFuelAlert()
        end
        return
    end

    if msg.type == "status" then
        return
    end
end

-- ---------------------------------------------------------------------------
-- Main loop: drain every pending rednet message, then redraw once
-- ---------------------------------------------------------------------------

print("Mining station ID: " .. os.getComputerID())
print("Modem: " .. modemSide .. "  Monitor: " .. monW .. "x" .. monH .. "  Speaker: " .. tostring(speaker ~= nil))
if not TURTLE_ID then
    statusLine = "Ready to pair"
end
draw()

local function messageLoop()
    while true do
        local sender, message, protocol = rednet.receive(PROTOCOL, 0.2)
        if sender and protocol == PROTOCOL then
            handleMessage(message, sender)
            for _ = 1, 40 do
                local s2, m2, p2 = rednet.receive(PROTOCOL, 0.05)
                if not s2 then break end
                if p2 == PROTOCOL then
                    handleMessage(m2, s2)
                end
            end
            if dirty then
                draw()
            end
            if pendingOreSounds > 0 then
                playOreChime()
                pendingOreSounds = 0
            end
        end
    end
end

-- Audio runs beside rednet so the station can still accept the turtle hello.
parallel.waitForAll(playPairingSound, messageLoop)
