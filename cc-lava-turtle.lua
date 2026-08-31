-- Wireless lava-bucket refill turtle for CC:Tweaked.
-- Start facing the Mekanism fluid tank. The bucket chest is below the turtle.
-- turtle.place() is used: this is the safe right-click/use action.

local PROTOCOL = "atm10_quarry_v2"
local BASE_ID = nil
local PAIR_FILE = "quarry_station_id"
local ROLE = "lava"
local LABEL = "Lava Bucket Turtle"
local BUCKET_CHEST_SIDE = "bottom"
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

local function inventorySnapshot()
    local snapshot = {}
    for slot = 1, 16 do
        local item = turtle.getItemDetail(slot)
        snapshot[slot] = {
            name = item and item.name or nil,
            count = item and item.count or 0,
        }
    end
    return snapshot
end

local function findReceivedSlot(before)
    for slot = 1, 16 do
        local item = turtle.getItemDetail(slot)
        local previous = before[slot]
        if item and (
            not previous.name
            or previous.name ~= item.name
            or item.count > previous.count
        ) then
            return slot
        end
    end
    return nil
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

local function fillFromTank(slot)
    -- The Mekanism tank must be directly in front of the turtle.
    local filledBefore = countItems("minecraft:lava_bucket")
    turtle.select(slot)
    local ok = turtle.place()
    local filledAfter, filledSlot = countItems("minecraft:lava_bucket")
    if ok and filledAfter > filledBefore then
        turtle.select(filledSlot)
        return true, filledSlot
    end
    return false
end

local function refillBuckets()
    send({ type = "status", status = "Refilling buckets", task = "Filling buckets", fuel = turtle.getFuelLevel(), active = true })
    local refilled = 0
    while true do
        local slot = findItemSlot("minecraft:bucket")
        if not slot then
            local chestSlot
            for candidate = 1, 16 do
                if turtle.getItemCount(candidate) == 0 then chestSlot = candidate break end
            end
            if not chestSlot then break end
            local before = inventorySnapshot()
            turtle.select(chestSlot)
            if not chestSuck() then break end
            slot = findReceivedSlot(before)
            if not slot then
                send({
                    type = "status",
                    status = "Could not identify chest item",
                    task = "Filling buckets",
                    fuel = turtle.getFuelLevel(),
                    active = true,
                })
                break
            end
        end
        if slot then
            local item = turtle.getItemDetail(slot)
            if item and item.name == "minecraft:bucket" then
                local filled, filledSlot = fillFromTank(slot)
                if filled then
                    refilled = refilled + 1
                    turtle.select(filledSlot)
                    if not chestDrop(1) then fail("Bucket chest rejected a filled lava bucket") break end
                else
                    send({
                        type = "status",
                        status = "Waiting for lava in fluid tank",
                        task = "Filling buckets",
                        fuel = turtle.getFuelLevel(),
                        active = true,
                    })
                    turtle.select(slot)
                    if not chestDrop(1) then fail("Bucket chest rejected an empty bucket") end
                    break
                end
            else
                turtle.select(slot)
                if not chestDrop() then fail("Bucket chest rejected an item") break end
                -- Do not keep pulling filled buckets from the shared chest.
                -- Wait for another turtle to return an empty bucket.
                break
            end
        end
    end
    print("Refilled " .. refilled .. " buckets")
    reportBuckets()
end

if not pair() then return end
while not halted do
    -- This turtle never travels, so it must not consume the filled buckets
    -- it produces from the shared chest.
    refillBuckets()
    sleep(2)
    reportBuckets()
end
