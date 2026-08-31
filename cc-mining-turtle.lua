-- CC:Tweaked wireless mining turtle (Advanced Turtle + wireless modem)
-- The implementation lives in cc-mining-turtle-core.lua.
if fs.exists("cc-mining-turtle-core.lua") then
    dofile("cc-mining-turtle-core.lua")
    return
end
error("Missing cc-mining-turtle-core.lua. Download both miner files.")
-- Quarry excavates a 32x32 area downward (same as: excavate 32)
-- Reports mined blocks and ores to cc-mining-station.lua over rednet.

local PROTOCOL = "atm10_mining"
local BASE_ID = nil -- auto-pair on first hello, or set e.g. 0

local EXCAVATE_SIZE = 32

local FUEL_WARN = 200
local FUEL_CRITICAL = 50
local FUEL_CHECK_EVERY = 5
local REPORT_EVERY = 1

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
-- Wireless
-- ---------------------------------------------------------------------------

local function send(msg)
    if not BASE_ID then return end
    rednet.send(BASE_ID, msg, PROTOCOL)
end

local function pairWithBase()
    if BASE_ID then return true end

    print("Searching for base station...")
    for _ = 1, 20 do
        rednet.broadcast({
            type = "hello",
            label = TURTLE_LABEL .. " #" .. os.getComputerID(),
        }, PROTOCOL)
        local sender, reply, protocol = rednet.receive(PROTOCOL, 2)
        if sender and protocol == PROTOCOL and type(reply) == "table" and reply.type == "ack" then
            BASE_ID = reply.stationId or sender
            print("Paired with station ID " .. BASE_ID)
            send({ type = "status", label = TURTLE_LABEL, fuel = turtle.getFuelLevel(), status = "Paired" })
            return true
        end
        sleep(1)
    end

    print("Could not find base. Set BASE_ID manually at top of script.")
    return false
end

-- ---------------------------------------------------------------------------
-- Position tracking (return to start for unload / refuel)
-- ---------------------------------------------------------------------------

local pos = { x = 0, y = 0, z = 0 }
local facing = 0 -- 0=+z, 1=+x, 2=-z, 3=-x

local function turnRight()
    turtle.turnRight()
    facing = (facing + 1) % 4
end

local function turnLeft()
    turtle.turnLeft()
    facing = (facing + 3) % 4
end

local function stepForward()
    if facing == 0 then pos.z = pos.z + 1
    elseif facing == 1 then pos.x = pos.x + 1
    elseif facing == 2 then pos.z = pos.z - 1
    else pos.x = pos.x - 1 end
end

local function stepDown()
    pos.y = pos.y - 1
end

local function stepUp()
    pos.y = pos.y + 1
end

-- ---------------------------------------------------------------------------
-- Mining helpers
-- ---------------------------------------------------------------------------

local blocksSinceFuelCheck = 0
local blocksSinceReport = 0

local ORE_EXTRA = {
    ["minecraft:ancient_debris"] = true,
    ["minecraft:glowstone"] = true,
    ["minecraft:nether_quartz_ore"] = true,
}

local function isOre(name)
    if not name then return false end
    if ORE_EXTRA[name] then return true end
    local lower = name:lower()
    if lower:find("_ore") or lower:find(":ore_") or lower:find("/ore") then return true end
    if lower:find("ore_") or lower:match("ore$") then return true end
    return false
end

local function fuelLevel()
    local f = turtle.getFuelLevel()
    if f == "unlimited" then return "unlimited" end
    return f
end

local function reportFuel(force)
    blocksSinceFuelCheck = 0
    local level = fuelLevel()
    local warn = (level ~= "unlimited") and (level <= FUEL_WARN)
    if force or warn then
        send({
            type = "fuel",
            level = level,
            warning = warn and level <= FUEL_CRITICAL or warn,
        })
    end
end

local function tryRefuel()
    for slot = 1, 16 do
        turtle.select(slot)
        if turtle.refuel(1) then
            print("Refueled from slot " .. slot)
            reportFuel(true)
            return true
        end
    end
    return false
end

local function ensureFuel()
    local level = fuelLevel()
    if level == "unlimited" then return true end
    if level > FUEL_WARN then return true end

    if tryRefuel() then
        level = fuelLevel()
        if level == "unlimited" or level > FUEL_CRITICAL then return true end
    end

    send({ type = "fuel", level = level, warning = true })
    send({ type = "status", fuel = level, status = "NEEDS FUEL" })
    print("Out of fuel! Waiting...")
    while true do
        if tryRefuel() then
            level = fuelLevel()
            if level == "unlimited" or level > FUEL_CRITICAL then
                send({ type = "status", fuel = level, status = "Resumed" })
                return true
            end
        end
        sleep(2)
    end
end

local function recordBlock(name)
    if not name or name == "minecraft:air" or name == "minecraft:cave_air" then return end

    blocksSinceFuelCheck = blocksSinceFuelCheck + 1
    blocksSinceReport = blocksSinceReport + 1

    if blocksSinceReport >= REPORT_EVERY then
        blocksSinceReport = 0
        send({ type = "mined", block = name, count = 1 })
    end

    if isOre(name) then
        send({ type = "ore", block = name })
    end

    if blocksSinceFuelCheck >= FUEL_CHECK_EVERY then
        reportFuel(false)
    end
end

local function digAndRecord(fn)
    local ok, data = fn()
    if ok and data and data.name then
        recordBlock(data.name)
    end
    return ok, data
end

local function tryForward()
    while not turtle.forward() do
        if not digAndRecord(turtle.dig) then return false end
        sleep(0.1)
    end
    stepForward()
    ensureFuel()
    return true
end

local function tryDown()
    while not turtle.down() do
        if not digAndRecord(turtle.digDown) then return false end
        sleep(0.1)
    end
    stepDown()
    ensureFuel()
    return true
end

local function tryUp()
    while not turtle.up() do
        if not digAndRecord(turtle.digUp) then return false end
        sleep(0.1)
    end
    stepUp()
    ensureFuel()
    return true
end

local function inventoryFull()
    for slot = 1, 16 do
        if turtle.getItemCount(slot) == 0 then return false end
        if turtle.getItemSpace(slot) > 0 then return false end
    end
    return true
end

local function unloadAtStart()
    send({ type = "status", status = "Inventory full - unloading", fuel = fuelLevel() })

    -- Navigate back to origin (0, 0, 0)
    while pos.y < 0 do
        if not tryUp() then break end
    end
    while pos.y > 0 do
        if not tryDown() then break end
    end

    while pos.x > 0 do
        if facing ~= 3 then
            if facing == 0 then turnLeft() elseif facing == 1 then turnLeft() turnLeft() else turnRight() end
        end
        if not tryForward() then break end
    end
    while pos.x < 0 do
        if facing ~= 1 then
            if facing == 0 then turnRight() elseif facing == 2 then turnLeft() turnLeft() else turnLeft() end
        end
        if not tryForward() then break end
    end
    while pos.z > 0 do
        if facing ~= 2 then
            if facing == 0 then turnLeft() turnLeft() elseif facing == 1 then turnRight() else turnLeft() end
        end
        if not tryForward() then break end
    end
    while pos.z < 0 do
        if facing ~= 0 then
            if facing == 1 then turnLeft() elseif facing == 2 then turnRight() else turnLeft() turnLeft() end
        end
        if not tryForward() then break end
    end

    -- Drop everything; place a chest behind the start facing for auto-collect
    turnLeft()
    turnLeft()
    for slot = 1, 16 do
        turtle.select(slot)
        turtle.drop()
    end
    turnLeft()
    turnLeft()

    send({ type = "status", status = "Unloaded - resuming", fuel = fuelLevel() })
end

-- CC:Tweaked quarry pattern (same logic as built-in excavate program)
local function excavate(size)
    local depth = 0
    local alternate = 0
    local done = false

    send({
        type = "status",
        status = "Excavating " .. size .. "x" .. size,
        fuel = fuelLevel(),
    })
    print("Excavating " .. size .. "x" .. size .. "...")

    while not done do
        if inventoryFull() then
            unloadAtStart()
        end

        for n = 1, size do
            for _ = 1, size - 1 do
                if not tryForward() then
                    done = true
                    break
                end
            end
            if done then break end

            if n < size then
                if (n + alternate) % 2 == 0 then
                    turnLeft()
                    if not tryForward() then done = true break end
                    turnLeft()
                else
                    turnRight()
                    if not tryForward() then done = true break end
                    turnRight()
                end
            end
        end

        if done then break end

        if size > 1 then
            if size % 2 == 0 then
                turnRight()
            else
                if alternate == 0 then turnLeft() else turnRight() end
                alternate = 1 - alternate
            end
        end

        if not tryDown() then
            done = true
        else
            depth = depth + 1
            if depth % 5 == 0 then
                send({
                    type = "status",
                    status = "Depth " .. depth .. " (" .. size .. "x" .. size .. ")",
                    fuel = fuelLevel(),
                })
            end
        end
    end

    -- Return to surface
    while pos.y < 0 do
        tryUp()
    end

    send({
        type = "status",
        status = "Excavation done (depth " .. depth .. ")",
        fuel = fuelLevel(),
    })
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

ensureFuel()
send({ type = "status", label = TURTLE_LABEL, fuel = fuelLevel(), status = "Starting excavate " .. EXCAVATE_SIZE })

-- Place turtle at the START corner of the quarry (surface).
-- It mines a EXCAVATE_SIZE x EXCAVATE_SIZE area downward until bedrock.
-- Optional: put a chest behind the starting position for item dumps.
excavate(EXCAVATE_SIZE)
