-- Wireless lava-bucket refill turtle for CC:Tweaked.
-- Start facing the fluid drawer tower. The bucket chest is below the turtle.
-- turtle.place() is used: this is the safe right-click/use action.

local PROTOCOL = "atm10_quarry_v2"
local BASE_ID = nil
local PAIR_FILE = "quarry_station_id"
local ROLE = "lava"
local LABEL = "Lava Bucket Turtle"
local BUCKET_CHEST_SIDE = "bottom"
local DRAWER_SIDE = "front"
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

local function fail(message)
    printError(message)
    halted = true
    send({ type = "error", error = message, status = "ERROR", task = "Error", fuel = turtle.getFuelLevel(), active = false })
end

local function sideCall(name, ...)
    local method = turtle[name]
    if not method then error("Missing turtle API: " .. name) end
    return method(...)
end

local function chestSuck()
    if BUCKET_CHEST_SIDE == "bottom" then return turtle.suckDown(1) end
    if BUCKET_CHEST_SIDE == "top" then return turtle.suckUp(1) end
    return turtle.suck(1)
end

local function chestDrop(amount)
    if BUCKET_CHEST_SIDE == "bottom" then
        if amount then return turtle.dropDown(amount) end
        return turtle.dropDown()
    end
    if BUCKET_CHEST_SIDE == "top" then
        if amount then return turtle.dropUp(amount) end
        return turtle.dropUp()
    end
    if amount then return turtle.drop(amount) end
    return turtle.drop()
end

local function findItemSlot(itemName)
    for slot = 1, 16 do
        local item = turtle.getItemDetail(slot)
        if item and item.name == itemName then return slot end
    end
    return nil
end

local function countItems(itemName)
    local count, firstSlot = 0, nil
    for slot = 1, 16 do
        local item = turtle.getItemDetail(slot)
        if item and item.name == itemName then
            count = count + item.count
            firstSlot = firstSlot or slot
        end
    end
    return count, firstSlot
end

local function fuelFromChest()
    if turtle.getFuelLevel() == "unlimited" or turtle.getFuelLevel() >= FUEL_TARGET then return true end
    send({ type = "status", status = "Refueling", task = "Refueling", fuel = turtle.getFuelLevel(), active = true })
    local deferred = {}
    while turtle.getFuelLevel() < FUEL_TARGET do
        local slot
        for candidate = 1, 16 do
            if turtle.getItemCount(candidate) == 0 then slot = candidate break end
        end
        if not slot then break end
        turtle.select(slot)
        if not chestSuck() then break end
        local item = turtle.getItemDetail(slot)
        if item and item.name == "minecraft:lava_bucket" then
            if not turtle.refuel(1) then
                fail("Lava bucket was not accepted as fuel")
                break
            end
            if not chestDrop() then fail("Bucket chest rejected an empty bucket") break end
        else
            deferred[#deferred + 1] = slot
        end
    end
    for _, slot in ipairs(deferred) do
        turtle.select(slot)
        if not chestDrop() then fail("Bucket chest rejected a non-fuel item") end
    end
    if turtle.getFuelLevel() == "unlimited" or turtle.getFuelLevel() >= FUEL_TARGET then
        return true
    end
    send({
        type = "status",
        status = "Waiting for filled lava buckets",
        task = "Waiting for fuel",
        fuel = turtle.getFuelLevel(),
        active = true,
    })
    return false
end

local function chestCounts()
    local chest = peripheral.wrap(BUCKET_CHEST_SIDE)
    if not chest or not chest.list then return "?", "?" end
    local filled, empty = 0, 0
    for slot, detail in pairs(chest.list()) do
        local item = chest.getItemDetail(slot)
        if item then
            if item.name == "minecraft:lava_bucket" then filled = filled + item.count end
            if item.name == "minecraft:bucket" then empty = empty + item.count end
        end
    end
    return filled, empty
end

local function reportBuckets()
    local filled, empty = chestCounts()
    send({
        type = "buckets", filled = filled, empty = empty,
        status = "Bucket counts updated", task = "Waiting",
        fuel = turtle.getFuelLevel(), active = true,
    })
end

local function turnBy(turns)
    turns = turns % 4
    if turns == 1 then
        turtle.turnRight()
    elseif turns == 2 then
        turtle.turnRight()
        turtle.turnRight()
    elseif turns == 3 then
        turtle.turnLeft()
    end
end

local function drawerDirection()
    if DRAWER_SIDE == "right" then return 1 end
    if DRAWER_SIDE == "back" then return 2 end
    if DRAWER_SIDE == "left" then return 3 end
    return 0
end

local function fillFromDrawer(slot)
    -- Try the configured side first, then the other horizontal sides. This
    -- makes setup tolerant of the turtle being rotated beside the tower.
    local first = drawerDirection()
    local directions = { first }
    for direction = 0, 3 do
        local alreadyListed = false
        for _, listed in ipairs(directions) do
            if listed == direction then alreadyListed = true break end
        end
        if not alreadyListed then directions[#directions + 1] = direction end
    end

    local filledBefore = countItems("minecraft:lava_bucket")
    local currentDirection = 0
    for _, direction in ipairs(directions) do
        turnBy(direction - currentDirection)
        currentDirection = direction
        turtle.select(slot)
        local ok = turtle.place()
        local filledAfter, filledSlot = countItems("minecraft:lava_bucket")
        if ok and filledAfter > filledBefore then
            turtle.select(filledSlot)
            turnBy(-currentDirection)
            return true, filledSlot
        end
    end
    turnBy(-currentDirection)

    -- A drawer tower may be one block above or below the turtle instead of
    -- being level with it. The chest below normally makes placeDown fail
    -- safely, but trying it keeps this routine compatible with either layout.
    turtle.select(slot)
    local ok = turtle.placeUp()
    local filledAfter, filledSlot = countItems("minecraft:lava_bucket")
    if ok and filledAfter > filledBefore then
        turtle.select(filledSlot)
        return true, filledSlot
    end
    turtle.select(slot)
    ok = turtle.placeDown()
    filledAfter, filledSlot = countItems("minecraft:lava_bucket")
    if ok and filledAfter > filledBefore then
        turtle.select(filledSlot)
        return true, filledSlot
    end
    return false
end

local function refillBuckets()
    send({ type = "status", status = "Refilling buckets", task = "Filling buckets", fuel = turtle.getFuelLevel(), active = true })
    local deferred = {}
    local refilled = 0
    while true do
        local slot = findItemSlot("minecraft:bucket")
        if not slot then
            local emptySlot
            for candidate = 1, 16 do
                if turtle.getItemCount(candidate) == 0 then emptySlot = candidate break end
            end
            if not emptySlot then break end
            turtle.select(emptySlot)
            if not chestSuck() then break end
            slot = findItemSlot("minecraft:bucket")
            if not slot then
                deferred[#deferred + 1] = emptySlot
            end
        end
        if slot then
            local filled, filledSlot = fillFromDrawer(slot)
            if filled then
                refilled = refilled + 1
                turtle.select(filledSlot)
                if not chestDrop(1) then fail("Bucket chest rejected a filled lava bucket") break end
            else
                send({
                    type = "status",
                    status = "Waiting for lava in fluid drawer",
                    task = "Filling buckets",
                    fuel = turtle.getFuelLevel(),
                    active = true,
                })
                turtle.select(slot)
                if not chestDrop(1) then fail("Bucket chest rejected an empty bucket") end
                break
            end
        end
    end
    for _, slot in ipairs(deferred) do
        turtle.select(slot)
        if not chestDrop() then fail("Bucket chest rejected an item") end
    end
    print("Refilled " .. refilled .. " buckets")
    reportBuckets()
end

if not pair() then return end
while not halted do
    -- Filling buckets uses no movement fuel, so do this before the fuel check.
    -- This also lets the turtle create its own fuel supply from empty buckets.
    refillBuckets()
    if turtle.getFuelLevel() ~= "unlimited" and turtle.getFuelLevel() < FUEL_TRIGGER then
        if not fuelFromChest() then sleep(10) end
    else
        sleep(2)
    end
    reportBuckets()
end
