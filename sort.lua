-- ATM10 chest sorter for CC:Tweaked mining turtles.
--
-- HOME: stand next to the unsorted chest, FACING it (turtle.suck() from the front).
-- The four dump chests are a 1-deep trench along a path to your LEFT.
-- While walking that path, those chests are on your RIGHT.
-- Turtles do not fall, so the turtle steps into the air above each chest and dropDown().
--
-- If it walks the wrong way, set PATH_TURN to "right".
-- If it hovers over grass instead of a chest, set DIST_TO_FIRST to 0.
-- If the chests are on the other side of the path, set HOP_TURN to "left".

local PATH_TURN      = "left"   -- "left" or "right" - turn this way from the input chest
local HOP_TURN       = "right"  -- side the dump chests are on while walking the path
local DIST_TO_FIRST  = 1        -- steps along the path to sit beside chest 1
local CHEST_COUNT    = 4
local WAIT_EMPTY     = 8        -- seconds to wait when the input chest is empty
local FUEL_MIN       = 80

-- ---------------------------------------------------------------------------
-- Movement helpers
-- ---------------------------------------------------------------------------

local function turn(dir)
    if dir == "left" then turtle.turnLeft() else turtle.turnRight() end
end

local function turnOpposite(dir)
    if dir == "left" then turtle.turnRight() else turtle.turnLeft() end
end

local function refuelIfNeeded()
    local level = turtle.getFuelLevel()
    if level == "unlimited" then return true end
    if level >= FUEL_MIN then return true end
    for slot = 1, 16 do
        if turtle.getItemCount(slot) > 0 then
            turtle.select(slot)
            -- Non-fuel items return false and are not consumed.
            if turtle.refuel(64) then
                if turtle.getFuelLevel() >= FUEL_MIN then return true end
            end
        end
    end
    return turtle.getFuelLevel() ~= "unlimited" and turtle.getFuelLevel() > 0
end

local function moveForward()
    if not refuelIfNeeded() then
        print("Out of fuel. Put coal in me or the input chest.")
        while turtle.getFuelLevel() == 0 or (turtle.getFuelLevel() ~= "unlimited" and turtle.getFuelLevel() < 1) do
            sleep(2)
            refuelIfNeeded()
        end
    end
    while not turtle.forward() do
        print("Path blocked - retrying")
        sleep(1)
    end
end

local function moveBack()
    if not refuelIfNeeded() then
        print("Out of fuel.")
        sleep(2)
        refuelIfNeeded()
    end
    while not turtle.back() do
        print("Can't go back - retrying")
        sleep(1)
    end
end

-- ---------------------------------------------------------------------------
-- Item classification (ATM10 / NeoForge tags + name fallbacks)
-- ---------------------------------------------------------------------------

local function itemPart(name)
    return (name:match(":(.+)$") or name):lower()
end

local function hasTag(detail, tag)
    return detail.tags and detail.tags[tag] == true
end

local function hasTagPrefix(detail, prefix)
    if not detail.tags then return false end
    for tag, on in pairs(detail.tags) do
        if on and tag:sub(1, #prefix) == prefix then return true end
    end
    return false
end

local function isOre(detail)
    if hasTag(detail, "c:ores") then return true end
    if hasTagPrefix(detail, "c:ores/") then return true end
    if hasTagPrefix(detail, "c:raw_materials") then return true end
    if hasTag(detail, "c:raw_materials") then return true end
    local n = itemPart(detail.name)
    if n:find("_ore", 1, true) or n:find("^ore") then return true end
    if n:find("ancient_debris", 1, true) then return true end
    if n:find("uraninite", 1, true) then return true end
    if n:find("^raw_") or n:find("_raw_", 1, true) or n:match("_raw$") then
        return true
    end
    if n:find("allthemodium", 1, true) or n:find("vibranium", 1, true) or n:find("unobtainium", 1, true) then
        if n:find("ingot") or n:find("nugget") or n:find("dust") or n:find("gear")
            or n:find("plate") or n:find("rod") or n:find("block") then
            return false
        end
        return true
    end
    return false
end

local function isDirt(detail)
    if hasTag(detail, "minecraft:dirt") then return true end
    if hasTag(detail, "c:dirts") then return true end
    local n = itemPart(detail.name)
    if n:find("dirt", 1, true) then return true end
    if n == "grass_block" or n == "podzol" or n == "mycelium" then return true end
    if n == "mud" or n == "muddy_mangrove_roots" or n == "farmland" then return true end
    if n == "moss_block" or n == "pale_moss_block" or n == "rooted_dirt" then return true end
    return false
end

local function isCobble(detail)
    if hasTag(detail, "c:cobblestones") then return true end
    if hasTagPrefix(detail, "c:cobblestones/") then return true end
    local n = itemPart(detail.name)
    if n == "cobblestone" or n == "mossy_cobblestone" then return true end
    if n == "cobbled_deepslate" or n == "mossy_cobbled_deepslate" then return true end
    if n:find("cobblestone", 1, true) then return true end
    if n:find("cobbled_", 1, true) then return true end
    return false
end

local STONE_EXACT = {
    stone = true, andesite = true, diorite = true, granite = true,
    tuff = true, calcite = true, dripstone_block = true,
    deepslate = true, netherrack = true, basalt = true, smooth_basalt = true,
    blackstone = true, end_stone = true, gravel = true, sandstone = true,
    red_sandstone = true, magma_block = true, soul_sand = true, soul_soil = true,
    clay = true, terracotta = true, packed_mud = true,
    limestone = true, marble = true, scoria = true, scorchia = true,
    asurine = true, crimsite = true, ochrum = true, veridium = true,
    dripstone = true, mossy_stone = true, smooth_stone = true,
}
local STONE_FRAGMENTS = {
    "andesite", "diorite", "granite", "tuff", "calcite", "netherrack",
    "basalt", "blackstone", "end_stone", "sandstone", "limestone",
    "marble", "scoria", "asurine", "crimsite", "ochrum", "veridium",
    "scorchia", "infested", "dripstone",
}

local function isOtherStone(detail)
    if hasTag(detail, "c:stones") then return true end
    if hasTagPrefix(detail, "c:stones/") then return true end
    if hasTag(detail, "c:gravels") then return true end
    local n = itemPart(detail.name)
    if STONE_EXACT[n] then return true end
    for _, frag in ipairs(STONE_FRAGMENTS) do
        if n:find(frag, 1, true) then return true end
    end
    if n == "deepslate" or n:find("deepslate", 1, true) then
        if n:find("ore", 1, true) then return false end
        if n:find("cobbled", 1, true) then return false end
        return true
    end
    return false
end

local function classify(detail)
    if not detail or not detail.name then return nil end
    if isOre(detail) then return 4 end
    if isDirt(detail) then return 1 end
    if isCobble(detail) then return 2 end
    if isOtherStone(detail) then return 3 end
    return nil
end

local CHEST_NAME = { "dirt", "cobblestone", "stone extras", "ores" }

-- ---------------------------------------------------------------------------
-- Inventory
-- ---------------------------------------------------------------------------

local function getDetail(slot)
    return turtle.getItemDetail(slot, true)
end

local function emptySlots()
    local n = 0
    for slot = 1, 16 do
        if turtle.getItemCount(slot) == 0 then n = n + 1 end
    end
    return n
end

local function suckInput()
    local moved = false
    while emptySlots() > 0 do
        if turtle.suck() then
            moved = true
        else
            break
        end
    end
    refuelIfNeeded()
    return moved
end

local function hasCategory(cat)
    for slot = 1, 16 do
        if turtle.getItemCount(slot) > 0 then
            if classify(getDetail(slot)) == cat then return true end
        end
    end
    return false
end

local function dropCategoryDown(cat)
    local dropped = 0
    for slot = 1, 16 do
        if turtle.getItemCount(slot) > 0 then
            local detail = getDetail(slot)
            if classify(detail) == cat then
                turtle.select(slot)
                local before = turtle.getItemCount(slot)
                if not turtle.dropDown() then
                    print("Chest " .. cat .. " (" .. CHEST_NAME[cat] .. ") is full")
                    return dropped, false
                end
                dropped = dropped + (before - turtle.getItemCount(slot))
            end
        end
    end
    return dropped, true
end

local function returnUnknowns()
    local any = false
    for slot = 1, 16 do
        if turtle.getItemCount(slot) > 0 then
            local detail = getDetail(slot)
            if classify(detail) == nil then
                turtle.select(slot)
                print("Unknown, back to input: " .. (detail and detail.name or "?"))
                if not turtle.drop() then
                    print("Input chest can't take leftovers")
                    return
                end
                any = true
            end
        end
    end
    return any
end

local function isChestBelow()
    local ok, data = turtle.inspectDown()
    if not ok or not data or not data.name then return false, "?" end
    local n = data.name:lower()
    if n:find("chest", 1, true) or n:find("barrel", 1, true) or n:find("crate", 1, true) then
        return true, data.name
    end
    return false, data.name
end

-- ---------------------------------------------------------------------------
-- Route: home -> each dump chest -> home
-- ---------------------------------------------------------------------------

local function hopOntoChest()
    if HOP_TURN == "none" then return end
    turn(HOP_TURN)
    moveForward()
end

local function hopBackToPath()
    if HOP_TURN == "none" then return end
    moveBack()
    turnOpposite(HOP_TURN)
end

local function stepsAlongPath(chestIndex)
    return DIST_TO_FIRST + (chestIndex - 1)
end

local function rewindHome(chestIndex)
    for _ = 1, stepsAlongPath(chestIndex) do
        moveBack()
    end
    turnOpposite(PATH_TURN)
end

local function sortTrip()
    turn(PATH_TURN)

    for chest = 1, CHEST_COUNT do
        local steps = (chest == 1) and DIST_TO_FIRST or 1
        for _ = 1, steps do
            moveForward()
        end

        hopOntoChest()

        local ok, below = isChestBelow()
        if not ok then
            print("Chest " .. chest .. ": no chest below, found " .. tostring(below))
            print("Fix PATH_TURN / HOP_TURN / DIST_TO_FIRST at the top of sort.lua")
            hopBackToPath()
            rewindHome(chest)
            return false
        end

        if hasCategory(chest) then
            print("Dropping " .. CHEST_NAME[chest] .. " into chest " .. chest)
            dropCategoryDown(chest)
        end

        hopBackToPath()
    end

    rewindHome(CHEST_COUNT)
    return true
end

-- ---------------------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------------------

term.clear()
term.setCursorPos(1, 1)
print("ATM10 sorter")
print("Facing unsorted chest")
print("1 dirt  2 cobble")
print("3 stone 4 ores")
print("")

refuelIfNeeded()
local fuel = turtle.getFuelLevel()
if fuel == "unlimited" then
    print("Fuel: unlimited")
else
    print("Fuel: " .. tostring(fuel))
    if fuel == 0 then
        print("I need fuel. Put coal or a lava bucket")
        print("in my inventory, then rerun.")
        return
    end
end

while true do
    print("Sucking input...")
    local got = suckInput()
    if not got and emptySlots() == 16 then
        print("Input empty. Waiting " .. WAIT_EMPTY .. "s")
        sleep(WAIT_EMPTY)
    else
        if not sortTrip() then
            print("Paused. Fix layout, then rerun.")
            return
        end
        returnUnknowns()
        if emptySlots() < 16 then
            print("Still holding sorted items (a dump chest may be full)")
            sleep(5)
        end
    end
end
