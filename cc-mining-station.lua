-- CC:Tweaked mining base station (Advanced Computer)
-- The implementation lives in cc-mining-station-core.lua.
if fs.exists("cc-mining-station-core.lua") then
    dofile("cc-mining-station-core.lua")
    return
end
-- Peripherals: wireless modem, 3x5 monitor (top), speaker (left), chatbox (right)
-- Pair with cc-mining-turtle.lua on your wireless mining turtle.

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

-- ---------------------------------------------------------------------------
-- Sounds
-- ---------------------------------------------------------------------------

local function playOreChime()
    if not speaker then return end
    speaker.playSound("entity.experience_orb.pickup", 1.0, 1.6)
    sleep(0.08)
    speaker.playSound("block.note_block.pling", 0.8, 1.8)
end

local function playFuelAlert()
    if not speaker then return end
    for _ = 1, 3 do
        speaker.playSound("block.note_block.bass", 1.0, 0.6)
        sleep(0.25)
    end
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
    monitor.write(text)
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
    local nameWidth = COL_SPLIT - 8

    monitor.setBackgroundColor(colors.black)
    monitor.clear()

    -- Header spans full width
    writeAt(1, 1, string.rep(" ", math.max(0, math.floor((monW - 22) / 2))) .. "ATM10 Mining Station", colors.cyan)
    writeAt(1, 2, string.format("Station %d  |  Turtle %s  |  %s",
        os.getComputerID(), tostring(TURTLE_ID or "?"), statusLine), colors.lightGray)

    -- Left column: live stats
    writeAt(1, 4, turtleLabel, colors.yellow)
    writeAt(1, 5, string.format("Mined: %d", totalMined), colors.white)
    writeAt(1, 6, string.format("Ores:  %d", oreCount), colors.orange)
    writeAt(1, 7, "Fuel:  " .. tostring(turtleFuel), colors.lightBlue)
    writeAt(1, 8, "Last:  " .. shortName(lastBlock, nameWidth), colors.lime)
    writeAt(1, 9, "Ore:   " .. shortName(lastOre, nameWidth), colors.yellow)

    -- Right column: top blocks (uses extra 4x2 width)
    writeAt(COL_SPLIT, 4, "Top blocks mined:", colors.white)

    local top = topBlocks(12)
    local row = 5
    local half = math.ceil(#top / 2)
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
        if row > monH then break end
    end

    -- Bottom status bar
    writeAt(1, monH, statusLine, colors.yellow)
end

-- ---------------------------------------------------------------------------
-- Message handling
-- ---------------------------------------------------------------------------

local function handleMessage(msg, sender)
    if type(msg) ~= "table" or not msg.type then return end

    if msg.type == "hello" then
        TURTLE_ID = sender
        turtleLabel = msg.label or ("Turtle " .. sender)
        statusLine = "Linked!"
        draw()
        rednet.send(sender, { type = "ack", stationId = os.getComputerID() }, PROTOCOL)
        return
    end

    if TURTLE_ID and sender ~= TURTLE_ID then return end

    if msg.type == "mined" and msg.block then
        stats[msg.block] = (stats[msg.block] or 0) + (msg.count or 1)
        totalMined = totalMined + (msg.count or 1)
        lastBlock = msg.block
        draw()
        return
    end

    if msg.type == "ore" and msg.block then
        oreCount = oreCount + 1
        lastOre = msg.block
        statusLine = "Ore found!"
        draw()
        playOreChime()
        return
    end

    if msg.type == "fuel" then
        turtleFuel = msg.level or "?"
        statusLine = msg.warning and "LOW FUEL" or "Fuel update"
        draw()
        if msg.warning and (os.clock() - lastFuelAlert) > 8 then
            lastFuelAlert = os.clock()
            playFuelAlert()
        end
        return
    end

    if msg.type == "status" then
        if msg.label then turtleLabel = msg.label end
        if msg.fuel then turtleFuel = msg.fuel end
        if msg.status then statusLine = msg.status end
        draw()
        return
    end
end

-- ---------------------------------------------------------------------------
-- Main loop
-- ---------------------------------------------------------------------------

print("Mining station ID: " .. os.getComputerID())
print("Modem: " .. modemSide .. "  Monitor: " .. monW .. "x" .. monH .. "  Speaker: " .. tostring(speaker ~= nil))
draw()

while true do
    local sender, message, protocol = rednet.receive(PROTOCOL, 1)
    if sender and protocol == PROTOCOL then
        handleMessage(message, sender)
    end
end
