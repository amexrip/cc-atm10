-- CC:Tweaked wireless mining turtle (Advanced Turtle + wireless modem)
-- Quarry: 32x32 down, same pattern as built-in excavate.
-- Dump chest is BEHIND the turtle at spawn. Never dumps coal/charcoal/lava buckets.
-- Reports mined blocks to station.lua over rednet protocol atm10_mining.

local PROTOCOL = "atm10_mining"
local BASE_ID = nil -- auto-pair on first hello, or set e.g. 0

local EXCAVATE_SIZE = 32

local FUEL_WARN = 200
local FUEL_CRITICAL = 80
local FLUSH_EVERY = 8

local TURTLE_LABEL = "Mining Turtle"

-- ---------------------------------------------------------------------------
-- Peripherals
-- ---------------------------------------------------------------------------

local function findModemSide()
    for _, side in ipairs(redstone.getSides()) do
        if peripheral.getType(side) == "modem" then
            return side
        end
    end
    return nil
end

local modemSide = findModemSide()
if not modemSide then
    print("No wireless modem on turtle!")
    return
end
rednet.open(modemSide)

-- ---------------------------------------------------------------------------
-- Position (spawn = 0,0,0 facing +z). Chest is behind spawn (face 2).
-- ---------------------------------------------------------------------------

local pos = { x = 0, y = 0, z = 0 }
local facing = 0 -- 0=+z, 1=+x, 2=-z, 3=-x
local returningHome = false
local currentStatus = "Idle"

local function turnRight()
    turtle.turnRight()
    facing = (facing + 1) % 4
end

local function turnLeft()
    turtle.turnLeft()
    facing = (facing + 3) % 4
end

local function faceDir(dir)
    local diff = (dir - facing) % 4
    if diff == 1 then
        turnRight()
    elseif diff == 2 then
        turnRight()
        turnRight()
    elseif diff == 3 then
        turnLeft()
    end
end

local function stepForward()
    if facing == 0 then
        pos.z = pos.z + 1
    elseif facing == 1 then
        pos.x = pos.x + 1
    elseif facing == 2 then
        pos.z = pos.z - 1
    else
        pos.x = pos.x - 1
    end
end

-- ---------------------------------------------------------------------------
-- Wireless
-- ---------------------------------------------------------------------------

local pendingMined = {}
local pendingMinedN = 0
local pendingOres = {}
local lastMinedName = nil
local lastOreName = nil

local function send(msg)
    if not BASE_ID then return end
    rednet.send(BASE_ID, msg, PROTOCOL)
end

local function fuelLevel()
    local f = turtle.getFuelLevel()
    if f == "unlimited" then return "unlimited" end
    return f
end

local function flushReports(status)
    if status then currentStatus = status end
    local mined = {}
    for name, count in pairs(pendingMined) do
        mined[#mined + 1] = { block = name, count = count }
    end
    send({
        type = "update",
        mined = mined,
        ores = pendingOres,
        fuel = fuelLevel(),
        status = currentStatus,
        lastBlock = lastMinedName,
        lastOre = lastOreName,
        x = pos.x,
        y = pos.y,
        z = pos.z,
        label = TURTLE_LABEL .. " #" .. os.getComputerID(),
    })
    pendingMined = {}
    pendingMinedN = 0
    pendingOres = {}
end

local function pairWithBase()
    if BASE_ID then return true end
    print("Searching for base station...")
    for _ = 1, 30 do
        rednet.broadcast({
            type = "hello",
            label = TURTLE_LABEL .. " #" .. os.getComputerID(),
            fuel = fuelLevel(),
            status = "Hello",
        }, PROTOCOL)
        local sender, reply, protocol = rednet.receive(PROTOCOL, 2)
        if sender and protocol == PROTOCOL and type(reply) == "table" and reply.type == "ack" then
            BASE_ID = reply.stationId or sender
            print("Paired with station ID " .. BASE_ID)
            flushReports("Paired")
            return true
        end
        sleep(0.5)
    end
    print("Could not find base. Set BASE_ID at top of mine.lua")
    return false
end

-- ---------------------------------------------------------------------------
-- Fuel / inventory
-- ---------------------------------------------------------------------------

local function itemName(slot)
    local d = turtle.getItemDetail(slot)
    return d and d.name or nil
end

local function isKeepFuelName(name)
    if not name then return false end
    local n = name:lower()
    local item = n:match(":(.+)$") or n
    if item == "coal" or item == "charcoal" then return true end
    if item:find("lava_bucket", 1, true) then return true end
    return false
end

local function isKeepFuelSlot(slot)
    return isKeepFuelName(itemName(slot))
end

local function emptySlots()
    local n = 0
    for slot = 1, 16 do
        if turtle.getItemCount(slot) == 0 then n = n + 1 end
    end
    return n
end

local function tryRefuel()
    local burned = false
    for slot = 1, 16 do
        if isKeepFuelSlot(slot) then
            turtle.select(slot)
            if turtle.refuel(8) then
                burned = true
                local level = fuelLevel()
                if level == "unlimited" or (type(level) == "number" and level > FUEL_WARN) then
                    return true
                end
            end
        end
    end
    return burned
end

local function homeDist()
    return math.abs(pos.x) + math.abs(pos.y) + math.abs(pos.z) + 12
end

local function needsUnload()
    return emptySlots() < 2
end

local function needsFuelTrip()
    local level = fuelLevel()
    if level == "unlimited" then return false end
    if tryRefuel() then
        level = fuelLevel()
    end
    if type(level) ~= "number" then return false end
    if level <= homeDist() then return true end
    if level <= FUEL_CRITICAL then return true end
    return false
end

-- ---------------------------------------------------------------------------
-- Mining + reports (inspect BEFORE dig, or station never sees blocks)
-- ---------------------------------------------------------------------------

local SKIP = {
    ["minecraft:air"] = true,
    ["minecraft:cave_air"] = true,
    ["minecraft:void_air"] = true,
    ["minecraft:bedrock"] = true,
    ["minecraft:water"] = true,
    ["minecraft:lava"] = true,
    ["minecraft:bubble_column"] = true,
}

local ORE_EXTRA = {
    ["minecraft:ancient_debris"] = true,
    ["minecraft:glowstone"] = true,
}

local function isOre(name)
    if not name then return false end
    if ORE_EXTRA[name] then return true end
    local lower = name:lower()
    if lower:find("_ore", 1, true) then return true end
    if lower:find("ore_", 1, true) then return true end
    if lower:match("ore$") then return true end
    return false
end

local function recordBlock(name)
    if not name or SKIP[name] then return end
    lastMinedName = name
    pendingMined[name] = (pendingMined[name] or 0) + 1
    pendingMinedN = pendingMinedN + 1
    if isOre(name) then
        lastOreName = name
        pendingOres[#pendingOres + 1] = { block = name }
    end
    if pendingMinedN >= FLUSH_EVERY then
        flushReports(currentStatus)
    end
end

local function digAhead()
    local hit, data = turtle.inspect()
    if hit and data and data.name then
        if data.name:lower():find("bedrock", 1, true) then return false end
        recordBlock(data.name)
    end
    if turtle.dig() then return true end
    turtle.attack()
    return turtle.dig()
end

local function digDown()
    local hit, data = turtle.inspectDown()
    if hit and data and data.name then
        if data.name:lower():find("bedrock", 1, true) then return false end
        recordBlock(data.name)
    end
    return turtle.digDown()
end

local function digUp()
    local hit, data = turtle.inspectUp()
    if hit and data and data.name then
        recordBlock(data.name)
    end
    return turtle.digUp()
end

local tryForward, tryDown, tryUp, goTo, returnHomeFor

tryForward = function()
    if not returningHome then
        if needsUnload() then
            returnHomeFor("Inventory full - unloading")
        elseif needsFuelTrip() then
            returnHomeFor("Low fuel - returning")
        end
    end
    for _ = 1, 40 do
        if turtle.forward() then
            stepForward()
            return true
        end
        if not digAhead() then
            sleep(0.15)
        else
            sleep(0.05)
        end
    end
    return false
end

tryDown = function()
    if not returningHome then
        if needsUnload() then
            returnHomeFor("Inventory full - unloading")
        elseif needsFuelTrip() then
            returnHomeFor("Low fuel - returning")
        end
    end
    for _ = 1, 20 do
        if turtle.down() then
            pos.y = pos.y - 1
            return true
        end
        if not digDown() then return false end
        sleep(0.05)
    end
    return false
end

tryUp = function()
    for _ = 1, 20 do
        if turtle.up() then
            pos.y = pos.y + 1
            return true
        end
        if not digUp() then
            sleep(0.15)
        else
            sleep(0.05)
        end
    end
    return false
end

local function moveY(target)
    while pos.y < target do
        if not tryUp() then return false end
    end
    while pos.y > target do
        if not tryDown() then return false end
    end
    return true
end

local function moveXZ(tx, tz)
    while pos.x ~= tx do
        if pos.x < tx then faceDir(1) else faceDir(3) end
        if not tryForward() then return false end
    end
    while pos.z ~= tz do
        if pos.z < tz then faceDir(0) else faceDir(2) end
        if not tryForward() then return false end
    end
    return true
end

goTo = function(tx, ty, tz)
    if ty >= pos.y then
        if not moveY(ty) then return false end
        return moveXZ(tx, tz)
    end
    if not moveXZ(tx, tz) then return false end
    return moveY(ty)
end

local function dumpNonFuel()
    faceDir(2)
    for slot = 1, 16 do
        if turtle.getItemCount(slot) > 0 and not isKeepFuelSlot(slot) then
            turtle.select(slot)
            for _ = 1, 5 do
                if turtle.getItemCount(slot) == 0 then break end
                if not turtle.drop() then
                    flushReports("Dump chest full - waiting")
                    sleep(3)
                end
            end
        end
    end
end

returnHomeFor = function(reason)
    if returningHome then return end
    returningHome = true
    local work = { x = pos.x, y = pos.y, z = pos.z, facing = facing }
    print(reason)
    flushReports(reason)
    goTo(0, 0, 0)
    dumpNonFuel()
    tryRefuel()
    local level = fuelLevel()
    while type(level) == "number" and level < FUEL_CRITICAL do
        flushReports("NEEDS FUEL at dump chest")
        print("Put coal/charcoal/lava in me")
        sleep(3)
        tryRefuel()
        level = fuelLevel()
    end
    faceDir(0)
    flushReports("Returning to dig site")
    goTo(work.x, work.y, work.z)
    faceDir(work.facing)
    returningHome = false
    flushReports("Resumed")
end

-- ---------------------------------------------------------------------------
-- Quarry
-- ---------------------------------------------------------------------------

local function snakeLayer(size)
    for n = 1, size do
        for _ = 1, size - 1 do
            if not tryForward() then return false end
        end
        if n < size then
            if n % 2 == 1 then
                turnRight()
                if not tryForward() then return false end
                turnRight()
            else
                turnLeft()
                if not tryForward() then return false end
                turnLeft()
            end
        end
    end
    return true
end

-- Drop through air to the last solid floor, climb one, scan that layer.
-- Returns true if a resume scan already covered the current layer.
local function resumeToLastLayer()
    flushReports("Descending to last layer")
    print("Dropping to last work layer...")
    local dropped = 0
    while true do
        local hit = turtle.inspectDown()
        if hit then break end
        if not turtle.down() then break end
        pos.y = pos.y - 1
        dropped = dropped + 1
        if dropped % 8 == 0 then
            flushReports("Descending y=" .. pos.y)
        end
        if not returningHome and needsFuelTrip() then
            returnHomeFor("Low fuel - returning")
        end
    end
    if dropped == 0 then
        return false
    end
    if not tryUp() then return false end
    goTo(0, pos.y, 0)
    faceDir(0)
    flushReports("Scanning layer y=" .. pos.y .. " for missed blocks")
    print("Scanning layer for leftovers...")
    snakeLayer(EXCAVATE_SIZE)
    goTo(0, pos.y, 0)
    faceDir(0)
    flushReports("Layer scan done - excavating down")
    return true
end

local function excavate(size, skipCurrentLayer)
    local depth = 0
    flushReports("Excavating " .. size .. "x" .. size)
    print("Excavating " .. size .. "x" .. size .. "...")

    while true do
        if skipCurrentLayer then
            skipCurrentLayer = false
        else
            if not snakeLayer(size) then
                break
            end
            goTo(0, pos.y, 0)
            faceDir(0)
        end
        if not tryDown() then
            break
        end
        depth = depth + 1
        flushReports("Depth " .. depth .. " (" .. size .. "x" .. size .. ")")
    end

    flushReports("Returning to surface")
    goTo(0, 0, 0)
    faceDir(0)
    dumpNonFuel()
    faceDir(0)
    flushReports("Excavation done (depth " .. depth .. ")")
    print("Excavation complete at depth " .. depth)
end

-- ---------------------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------------------

print("Mining turtle ID: " .. os.getComputerID())
if BASE_ID then
    print("Using base ID: " .. BASE_ID)
else
    if not pairWithBase() then return end
end

tryRefuel()
if fuelLevel() == 0 then
    print("I need coal, charcoal, or a lava bucket.")
    flushReports("NEEDS FUEL")
    return
end

-- Face +z at spawn. Unsorted dump chest must be directly BEHIND the turtle.
flushReports("Starting excavate " .. EXCAVATE_SIZE)
local alreadyScanned = resumeToLastLayer()
excavate(EXCAVATE_SIZE, alreadyScanned)
flushReports("Idle")
