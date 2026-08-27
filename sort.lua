-- ATM10 chest sorter for CC:Tweaked mining turtles.
--
-- HOME: stand next to the unsorted chest, FACING it.
-- Dump chests 1-6 in a line to your left or right (sunken is fine).
-- 1 dirt  2 cobble  3 stone  4 ores/gems  5-6 everything else
-- First run looks left, then right, until it finds a chest below.

local PATH_TURN = nil      -- set after the turtle finds the dump row
local DIST_TO_FIRST = nil  -- steps from home onto dump chest 1
local CHEST_COUNT = 6
local WAIT_EMPTY = 8
local FUEL_MIN = 80
local FIND_MAX = 4         -- how far to walk looking for chest 1

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

-- Gems and fortune drops from ores (diamond, not diamond_ore).
local ORE_DROPS = {
    diamond = true,
    emerald = true,
    coal = true,
    redstone = true,
    lapis_lazuli = true,
    quartz = true,
    nether_quartz = true,
    amethyst_shard = true,
    glowstone_dust = true,
    glowstone = true,
    netherite_scrap = true,
    ancient_debris = true,
    fluorite = true,
    certus_quartz_crystal = true,
    charged_certus_quartz_crystal = true,
}

local function isOre(detail)
    if hasTag(detail, "c:ores") then return true end
    if hasTagPrefix(detail, "c:ores/") then return true end
    if hasTag(detail, "c:raw_materials") then return true end
    if hasTagPrefix(detail, "c:raw_materials") then return true end
    if hasTag(detail, "c:gems") then return true end
    if hasTagPrefix(detail, "c:gems/") then return true end
    local n = itemPart(detail.name)
    if ORE_DROPS[n] then return true end
    if n:find("_ore", 1, true) or n:find("^ore") then return true end
    if n:find("ancient_debris", 1, true) then return true end
    if n:find("uraninite", 1, true) then return true end
    if n:find("netherite_scrap", 1, true) then return true end
    if n:find("^raw_") or n:find("_raw_", 1, true) or n:match("_raw$") then
        return true
    end
    if n:find("_gem", 1, true) then return true end
    if n:find("allthemodium", 1, true) or n:find("vibranium", 1, true) or n:find("unobtainium", 1, true) then
        if n:find("ingot") or n:find("nugget") or n:find("dust") or n:find("gear")
            or n:find("plate") or n:find("rod") then
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
    if not detail or not detail.name then return 5 end
    if isOre(detail) then return 4 end
    if isDirt(detail) then return 1 end
    if isCobble(detail) then return 2 end
    if isOtherStone(detail) then return 3 end
    return 5
end

local CHEST_NAME = {
    "dirt",
    "cobblestone",
    "stone extras",
    "ores",
    "unfiltered",
    "unfiltered",
}

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

local function dropUnfiltered()
    if hasCategory(5) then
        print("Dropping unfiltered")
        dropCategoryDown(5)
    end
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
-- Route: home -> walk on top of dump chests 1-6 -> home
-- ---------------------------------------------------------------------------

local function goHomeFrom(chestIndex)
    local steps = DIST_TO_FIRST + (chestIndex - 1)
    for _ = 1, steps do
        moveBack()
    end
    turnOpposite(PATH_TURN)
end

-- Precondition: already standing above chest 1, facing chest 6.
local function dumpAlongRow()
    for chest = 1, CHEST_COUNT do
        if chest > 1 then
            moveForward()
        end
        local ok, below = isChestBelow()
        if not ok then
            print("Chest " .. chest .. ": no chest below, found " .. tostring(below))
            goHomeFrom(chest)
            return false
        end
        if chest <= 4 then
            if hasCategory(chest) then
                print("Dropping " .. CHEST_NAME[chest] .. " into chest " .. chest)
                dropCategoryDown(chest)
            end
        else
            dropUnfiltered()
        end
    end
    goHomeFrom(CHEST_COUNT)
    return true
end

-- Face dir, walk until a chest is below, or rewind and face the input again.
local function tryFindRow(dir)
    turn(dir)
    if select(1, isChestBelow()) then
        PATH_TURN = dir
        DIST_TO_FIRST = 0
        return true
    end
    for i = 1, FIND_MAX do
        moveForward()
        if select(1, isChestBelow()) then
            PATH_TURN = dir
            DIST_TO_FIRST = i
            return true
        end
    end
    for _ = 1, FIND_MAX do
        moveBack()
    end
    turnOpposite(dir)
    return false
end

local function sortTrip()
    if PATH_TURN then
        turn(PATH_TURN)
        for _ = 1, DIST_TO_FIRST do
            moveForward()
        end
        return dumpAlongRow()
    end

    print("Looking for dump chests...")
    if tryFindRow("left") or tryFindRow("right") then
        print("Row is " .. PATH_TURN .. ", chest 1 is " .. DIST_TO_FIRST .. " step(s)")
        return dumpAlongRow()
    end
    print("Could not find dump chests under me.")
    print("Face the unsorted chest. Put the 6 dump chests")
    print("in a line to your left or right (sunken is OK).")
    return false
end

-- ---------------------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------------------

term.clear()
term.setCursorPos(1, 1)
print("ATM10 sorter")
print("Facing unsorted chest")
print("1 dirt  2 cobble  3 stone")
print("4 ores  5-6 extras")
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
        if emptySlots() < 16 then
            print("Still holding sorted items (a dump chest may be full)")
            sleep(5)
        end
    end
end
