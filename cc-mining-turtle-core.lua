-- Wireless 32x32 layered quarry turtle for CC:Tweaked.
-- Loaded by cc-mining-turtle.lua.

local PROTOCOL = "atm10_quarry_v2"
local BASE_ID = nil -- Set to the station computer ID to skip pairing.
local PAIR_FILE = "quarry_station_id"
local SIZE = 32
local FUEL_CHEST_SIDE = "left"
local UNSORTED_CHEST_SIDE = "back"
local FUEL_TRIGGER = 2000
local FUEL_TARGET = 50000
local ROLE = "miner"
local LABEL = "Mining Turtle"

local function findModem()
    for _, side in ipairs(peripheral.getNames()) do
        if peripheral.getType(side) == "modem" then return side end
    end
    for _, side in ipairs(redstone.getSides()) do
        if peripheral.getType(side) == "modem" then return side end
    end
end

local modem = findModem()
if not modem then error("No wireless modem attached") end
rednet.open(modem)

if not BASE_ID and fs.exists(PAIR_FILE) then
    local file = fs.open(PAIR_FILE, "r")
    local stored = file and tonumber(file.readAll()) or nil
    if file then file.close() end
    BASE_ID = stored
end

local function send(message)
    message.role = ROLE
    if BASE_ID then rednet.send(BASE_ID, message, PROTOCOL) end
end

local function pair()
    if BASE_ID then return true end
    print("Searching for mining station...")
    for _ = 1, 30 do
        rednet.broadcast({
            type = "hello", role = ROLE,
            label = LABEL .. " #" .. os.getComputerID(),
        }, PROTOCOL)
        local sender, reply, protocol = rednet.receive(PROTOCOL, 2)
        if sender and protocol == PROTOCOL and type(reply) == "table" and reply.type == "ack" then
            BASE_ID = reply.stationId or sender
            local file = fs.open(PAIR_FILE, "w")
            if file then file.write(tostring(BASE_ID)); file.close() end
            print("Connected to station " .. BASE_ID)
            send({ type = "status", status = "Connected", fuel = turtle.getFuelLevel(), active = true })
            return true
        end
    end
    print("No station found. Set BASE_ID at the top of this program.")
    return false
end

local pos = { x = 0, y = 0, z = 0 }
local facing = 0 -- 0=forward, 1=right, 2=back, 3=left from the start orientation.

local function fuel()
    return turtle.getFuelLevel()
end

local function reportPosition(status)
    send({
        type = "position", x = pos.x, y = pos.y, z = pos.z,
        status = status, task = status, fuel = fuel(), active = true,
    })
end

local function fail(message)
    printError(message)
    send({ type = "error", error = message, status = "ERROR", active = false, fuel = fuel() })
    error(message, 0)
end

local savedFacing = 0

local function turnLeft()
    turtle.turnLeft()
    facing = (facing + 3) % 4
end

local function turnRight()
    turtle.turnRight()
    facing = (facing + 1) % 4
end

local function face(direction)
    while facing ~= direction do
        local rightTurns = (direction - facing + 4) % 4
        if rightTurns <= 2 then turnRight() else turnLeft() end
    end
end

local function sideDirection(side)
    if side == "front" then return 0 end
    if side == "right" then return 1 end
    if side == "back" then return 2 end
    if side == "left" then return 3 end
    fail("Invalid fuel chest side: " .. tostring(side))
end

local function inspectAndDig(digFunction, inspectFunction)
    local ok, block = inspectFunction()
    if ok and block and block.name then
        local dug = digFunction()
        if dug then
            send({ type = "mined", block = block.name, count = 1, fuel = fuel(), active = true })
            local lower = block.name:lower()
            if lower:find("ore") or lower:find("ancient_debris") or lower:find("netherite") then
                send({ type = "ore", block = block.name, count = 1, fuel = fuel(), active = true })
            end
        end
        return dug
    end
    return false
end

local function digFront()
    return inspectAndDig(turtle.dig, turtle.inspect)
end

local function digDown()
    return inspectAndDig(turtle.digDown, turtle.inspectDown)
end

local function digUp()
    return inspectAndDig(turtle.digUp, turtle.inspectUp)
end

local function moveForwardRaw()
    while not turtle.forward() do
        if not digFront() then
            turtle.attack()
            sleep(0.2)
            if not digFront() then return false end
        end
    end
    if facing == 0 then pos.z = pos.z + 1
    elseif facing == 1 then pos.x = pos.x + 1
    elseif facing == 2 then pos.z = pos.z - 1
    else pos.x = pos.x - 1 end
    return true
end

local function moveUpRaw()
    while not turtle.up() do
        if not digUp() then return false end
    end
    pos.y = pos.y + 1
    return true
end

local function moveDownRaw()
    while not turtle.down() do
        if not digDown() then return false end
    end
    pos.y = pos.y - 1
    return true
end

local function inventoryFull()
    for slot = 1, 16 do
        if turtle.getItemCount(slot) == 0 or turtle.getItemSpace(slot) > 0 then return false end
    end
    return true
end

local function returnDeferred(slots)
    for _, slot in ipairs(slots) do
        turtle.select(slot)
        if not turtle.drop(64) then return false end
    end
    return true
end

local function refuelFromChest()
    if fuel() == "unlimited" or fuel() >= FUEL_TARGET then return true end
    face(sideDirection(FUEL_CHEST_SIDE))
    local deferred = {}
    while fuel() < FUEL_TARGET do
        local slot
        for candidate = 1, 16 do
            if turtle.getItemCount(candidate) == 0 then slot = candidate break end
        end
        if not slot then break end
        turtle.select(slot)
        if not turtle.suck(1) then break end
        local detail = turtle.getItemDetail(slot)
        if detail and detail.name == "minecraft:lava_bucket" then
            if turtle.refuel(1) then
                if not turtle.drop(64) then
                    deferred[#deferred + 1] = slot
                    break
                end
            else
                deferred[#deferred + 1] = slot
                break
            end
        else
            deferred[#deferred + 1] = slot
        end
    end
    if not returnDeferred(deferred) then
        face(0)
        fail("Fuel chest rejected a non-fuel item")
    end
    face(0)
    return fuel() == "unlimited" or fuel() >= FUEL_TARGET
end

local function dumpAtHome()
    face(2) -- unsorted chest is behind the turtle at its start point
    for slot = 1, 16 do
        turtle.select(slot)
        if turtle.getItemCount(slot) > 0 and not turtle.drop() then
            -- A full unsorted chest is a hard stop: do not discard items.
            face(0)
            fail("Unsorted chest is full or missing")
        end
    end
    face(0)
end

local function goTo(targetX, targetY, targetZ)
    while pos.x < targetX do face(1); if not moveForwardRaw() then fail("Cannot move +X") end end
    while pos.x > targetX do face(3); if not moveForwardRaw() then fail("Cannot move -X") end end
    while pos.z < targetZ do face(0); if not moveForwardRaw() then fail("Cannot move +Z") end end
    while pos.z > targetZ do face(2); if not moveForwardRaw() then fail("Cannot move -Z") end end
    while pos.y < targetY do if not moveUpRaw() then fail("Cannot move up") end end
    while pos.y > targetY do if not moveDownRaw() then fail("Cannot move down") end end
end

local function serviceCurrentPosition()
    local target = { x = pos.x, y = pos.y, z = pos.z, facing = facing }
    send({ type = "status", status = "Returning to unload/refuel", task = "Servicing", fuel = fuel(), active = true })
    goTo(0, 0, 0)
    face(0)
    dumpAtHome()
    if not refuelFromChest() then fail("No filled lava buckets available") end
    goTo(target.x, target.y, target.z)
    face(target.facing)
    reportPosition("Resuming excavation")
end

local function ensureFuel()
    if fuel() == "unlimited" then return end
    if fuel() < FUEL_TRIGGER then serviceCurrentPosition() end
end

local function moveForward()
    ensureFuel()
    if not moveForwardRaw() then fail("Blocked while moving forward") end
    reportPosition("Excavating")
    if inventoryFull() then serviceCurrentPosition() end
end

local function moveUp()
    ensureFuel()
    if not moveUpRaw() then fail("Blocked while moving up") end
    reportPosition("Changing layer")
end

local function descendThroughOpenShaft()
    send({ type = "status", status = "Finding current quarry layer", task = "Descending", fuel = fuel(), active = true })
    while true do
        ensureFuel()
        if turtle.down() then
            pos.y = pos.y - 1
            reportPosition("Descending through open shaft")
        else
            break
        end
    end
end

local function mineLayer()
    send({ type = "status", status = "Mining layer Y=" .. pos.y, task = "Mining layer", fuel = fuel(), active = true })
    for row = 0, SIZE - 1 do
        for _ = 1, SIZE - 1 do moveForward() end
        if row < SIZE - 1 then
            if row % 2 == 0 then
                turnRight()
                moveForward()
                turnRight()
            else
                turnLeft()
                moveForward()
                turnLeft()
            end
        end
    end
end

local function runQuarry()
    -- On restart, the starting column is already open through completed
    -- layers. Find the first solid layer without digging through old work.
    descendThroughOpenShaft()
    if not moveUpRaw() then fail("Cannot move up to the quarry layer") end
    pos.y = pos.y + 1
    reportPosition("Starting current quarry layer")

    local layers = 0
    while true do
        mineLayer()
        layers = layers + 1
        goTo(0, pos.y, 0)
        face(0)
        if not tryDown() then break end
        if inventoryFull() then serviceCurrentPosition() end
    end

    while pos.y < 0 do
        if not tryUp() then fail("Cannot return to surface") end
    end
    goTo(0, 0, 0)
    face(0)
    dumpAtHome()
    send({ type = "status", status = "Quarry complete after " .. layers .. " layers", task = "Complete", fuel = fuel(), active = false })
    print("32x32 quarry complete.")
end

if not pair() then return end
if fuel() ~= "unlimited" and fuel() < FUEL_TRIGGER then
    -- At startup the turtle is already at home, so this does not need navigation.
    dumpAtHome()
    if not refuelFromChest() then fail("No filled lava buckets available at startup") end
end
send({ type = "status", status = "Starting 32x32 quarry", task = "Starting", fuel = fuel(), active = true })
runQuarry()
