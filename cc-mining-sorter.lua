-- Wireless sorter turtle for CC:Tweaked.
-- Start on top of destination chest 1, facing the unsorted input chest.
-- Destination chests 2-8 extend to the turtle's right.

local PROTOCOL = "atm10_quarry_v2"
local BASE_ID = nil
local PAIR_FILE = "quarry_station_id"
local ROLE = "sorter"
local LABEL = "Sorter Turtle"
local INPUT_SIDE = "front"
local FUEL_TRIGGER = 2000
local FUEL_TARGET = 15000
local halted = false

local modem
for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then modem = side break end
end
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
    while true do
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
            send({ type = "status", status = "Connected", task = "Waiting", fuel = turtle.getFuelLevel(), active = true })
            return true
        end
    end
end

local facing = 0 -- 0=front/input, 1=right/row, 2=back, 3=left.

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

local function fail(message)
    printError(message)
    halted = true
    send({ type = "error", error = message, status = "ERROR", task = "Error", fuel = turtle.getFuelLevel(), active = false })
end

local function deferredDrop(slots)
    for _, slot in ipairs(slots) do
        turtle.select(slot)
        if not turtle.drop() then return false end
    end
    return true
end

local function stepForward()
    if not turtle.forward() then
        fail("Blocked on route to fuel chest")
        return false
    end
    return true
end

local function isChest(name)
    return name and name:lower():find("chest", 1, true) ~= nil
end

local function moveUntilFuelChest()
    for _ = 1, 64 do
        if turtle.forward() then
            -- Keep moving until the next block is the fuel chest.
        else
            local ok, block = turtle.inspect()
            if ok and block and isChest(block.name) then return true end
            fail("Fuel chest was not found on the route")
            return false
        end
    end
    fail("Fuel chest route exceeded 64 blocks")
    return false
end

local function returnFromFuelChest()
    -- Exact reverse: turn around, back 2, turn left, forward 1, turn left.
    turnLeft()
    turnLeft()
    if not stepForward() then return false end
    if not stepForward() then return false end
    turnLeft()
    if not stepForward() then return false end
    turnLeft()
    return true
end

local function refuel()
    if turtle.getFuelLevel() == "unlimited" or turtle.getFuelLevel() >= FUEL_TARGET then return true end
    -- Exact route from the sorting position:
    -- turn left, forward 1, turn right, forward 1, forward 1,
    -- then forward until the chest is directly in front.
    turnLeft()
    if not stepForward() then return false end
    turnRight()
    if not stepForward() then return false end
    if not stepForward() then return false end
    if not moveUntilFuelChest() then return false end

    local deferred = {}
    local empties = {}
    while turtle.getFuelLevel() < FUEL_TARGET do
        local slot
        for candidate = 1, 16 do
            if turtle.getItemCount(candidate) == 0 then slot = candidate break end
        end
        if not slot then break end
        turtle.select(slot)
        if not turtle.suck(1) then break end
        local item = turtle.getItemDetail(slot)
        if item and item.name == "minecraft:lava_bucket" then
            if not turtle.refuel(1) then
                fail("Lava bucket was not accepted as fuel")
                deferred[#deferred + 1] = slot
                break
            end
            empties[#empties + 1] = slot
        else
            deferred[#deferred + 1] = slot
        end
    end

    -- Return every empty bucket only after refueling is finished.
    for _, slot in ipairs(empties) do
        turtle.select(slot)
        if not turtle.drop() then
            deferred[#deferred + 1] = slot
        end
    end
    local ok = deferredDrop(deferred)
    face(0)
    local returned = returnFromFuelChest()
    face(0)
    if not ok then fail("Fuel chest rejected an item") end
    if not returned then return false end
    if turtle.getFuelLevel() == "unlimited" or turtle.getFuelLevel() >= FUEL_TARGET then
        send({ type = "status", status = "Refueled", task = "Sorting", fuel = turtle.getFuelLevel(), active = true })
        return true
    end
    fail("No filled lava buckets available")
    return false
end

local smeltable = {
    ["minecraft:iron_ore"] = true,
    ["minecraft:deepslate_iron_ore"] = true,
    ["minecraft:gold_ore"] = true,
    ["minecraft:deepslate_gold_ore"] = true,
    ["minecraft:copper_ore"] = true,
    ["minecraft:deepslate_copper_ore"] = true,
    ["minecraft:raw_iron"] = true,
    ["minecraft:raw_gold"] = true,
    ["minecraft:raw_copper"] = true,
}

local unsmeltable = {
    ["minecraft:diamond"] = true,
    ["minecraft:diamond_ore"] = true,
    ["minecraft:deepslate_diamond_ore"] = true,
    ["minecraft:emerald"] = true,
    ["minecraft:emerald_ore"] = true,
    ["minecraft:deepslate_emerald_ore"] = true,
    ["minecraft:lapis_lazuli"] = true,
    ["minecraft:lapis_ore"] = true,
    ["minecraft:deepslate_lapis_ore"] = true,
    ["minecraft:redstone"] = true,
    ["minecraft:redstone_ore"] = true,
    ["minecraft:deepslate_redstone_ore"] = true,
    ["minecraft:nether_quartz"] = true,
}

local decisions = {}
local unknownSent = {}

local function isOre(name)
    local lower = name:lower()
    return lower:find("_ore") or lower:find("ore_") or lower:match("ore$")
        or lower:find("raw_") or lower:find("raw") or lower:find("ancient_debris")
end

local function contains(name, value)
    return name:lower():find(value, 1, true) ~= nil
end

local function category(name)
    local lower = name:lower()
    if contains(lower, "grass") or contains(lower, "dirt") then return 1 end
    if contains(lower, "cobblestone") or contains(lower, "cobbled_deepslate") or contains(lower, "kivi") then return 2 end
    if contains(lower, "andesite") or contains(lower, "diorite") or contains(lower, "granite") or contains(lower, "gravel") then return 3 end
    if contains(lower, "netherite") or contains(lower, "ancient_debris") or contains(lower, "soul_sand") or contains(lower, "soulsand") then return 4 end
    if contains(lower, "end_stone") then return 5 end
    if contains(lower, "coal") then return 7 end
    if unsmeltable[name] or decisions[name] == false then return 6 end
    if smeltable[name] or decisions[name] == true then return 8 end
    if isOre(name) then return nil end
    return nil
end

local function pollMessages()
    while true do
        local sender, message, protocol = rednet.receive(PROTOCOL, 0.05)
        if not sender then return end
        if protocol == PROTOCOL and type(message) == "table" and message.type == "ore_decision" and message.ore then
            decisions[message.ore] = message.smeltable == true
            unknownSent[message.ore] = nil
            send({ type = "status", status = "Learned " .. message.ore, task = "Sorting", fuel = turtle.getFuelLevel(), active = true })
        end
    end
end

local function moveToDestination(index)
    if index == 1 then return true end
    turnRight()
    for _ = 2, index do
        if not turtle.forward() then
            fail("Cannot reach destination chest " .. index)
            face(0)
            return false
        end
    end
    turnLeft()
    return true
end

local function returnHome(index)
    if index == 1 then return true end
    turnLeft()
    for _ = 2, index do
        if not turtle.forward() then
            fail("Cannot return from destination chest " .. index)
            return false
        end
    end
    face(0)
    return true
end

local function routeItem(slot, index)
    turtle.select(slot)
    if not moveToDestination(index) then return false end
    if not turtle.dropDown() then
        returnHome(index)
        fail("Destination chest " .. index .. " is full or missing")
        return false
    end
    return returnHome(index)
end

local function putBack(slot)
    turtle.select(slot)
    if not turtle.drop() then fail("Unsorted input chest is full or missing") end
end

local function processOne()
    turtle.select(1)
    if not turtle.suck(64) then return false end
    local item = turtle.getItemDetail(1)
    if not item then return false end
    local index = category(item.name)
    if not index then
        putBack(1)
        if isOre(item.name) and not unknownSent[item.name] then
            unknownSent[item.name] = true
            send({ type = "unknown_ore", ore = item.name, status = "Unknown ore awaiting approval", task = "Waiting for ore decision", fuel = turtle.getFuelLevel(), active = true })
        elseif not isOre(item.name) then
            fail("Unclassified non-ore item: " .. item.name)
        end
        return true
    end
    send({ type = "status", status = "Sorting " .. item.name, task = "Sorting", fuel = turtle.getFuelLevel(), active = true })
    if not routeItem(1, index) then return false end
    return true
end

local function runFuelTest()
    print("Testing sorter fuel route...")
    print("Fuel before: " .. turtle.getFuelLevel())
    local ok = refuel()
    print("Fuel after: " .. turtle.getFuelLevel())
    if ok then
        print("Fuel test complete; returned to sorter position.")
    else
        printError("Fuel test failed.")
    end
end

local function prepareForFuel()
    -- Return an in-hand item to the input chest before using slots for buckets.
    if turtle.getItemCount(1) > 0 then putBack(1) end
    return refuel()
end

local args = { ... }
if args[1] == "testfuel" then
    runFuelTest()
    return
end

if not pair() then return end
while not halted do
    pollMessages()
    if turtle.getFuelLevel() ~= "unlimited" and turtle.getFuelLevel() < FUEL_TRIGGER then
        prepareForFuel()
    else
        if not processOne() then sleep(2) end
    end
    send({ type = "status", status = "Sorting", task = "Sorting", fuel = turtle.getFuelLevel(), active = true })
end
