-- Wireless Quarry command station for CC:Tweaked + Advanced Peripherals.
-- Loaded by cc-mining-station.lua.

local PROTOCOL = "atm10_quarry_v2"
local DATA_FILE = "quarry_station.dat"
local PLAYER_NAME = nil -- Set this to your Minecraft name to restrict Y/N replies.
local STARTUP_AUDIO = "startup.dfpwm"

local FUEL_WARN = {
    miner = 2000,
    sorter = 2000,
    lava = 2000,
}

local function findPeripheral(...)
    local names = { ... }
    for _, name in ipairs(names) do
        local value = peripheral.find(name)
        if value then return value end
    end
    return nil
end

local function findModem()
    for _, side in ipairs(peripheral.getNames()) do
        if peripheral.getType(side) == "modem" then
            return side
        end
    end
    for _, side in ipairs(redstone.getSides()) do
        if peripheral.getType(side) == "modem" then
            return side
        end
    end
end

local modemSide = findModem()
if not modemSide then
    error("No wireless modem found")
end
rednet.open(modemSide)

local monitor = findPeripheral("monitor")
if not monitor then error("No monitor found") end
monitor.setTextScale(0.5)

local speaker = findPeripheral("speaker")
local chatbox = findPeripheral("chatBox", "chat_box")

local function loadData()
    if not fs.exists(DATA_FILE) then
        return { smeltable = {}, unsmeltable = {}, paired = {} }
    end
    local file = fs.open(DATA_FILE, "r")
    local raw = file and file.readAll() or ""
    if file then file.close() end
    local data = textutils.unserialize(raw)
    if type(data) ~= "table" then data = {} end
    data.smeltable = data.smeltable or {}
    data.unsmeltable = data.unsmeltable or {}
    data.paired = data.paired or {}
    return data
end

local saved = loadData()

local function saveData()
    local file = fs.open(DATA_FILE, "w")
    if not file then return end
    file.write(textutils.serialize(saved))
    file.close()
end

local function chatSend(message)
    if not chatbox then
        print("[CHAT] " .. message)
        return
    end
    local ok, sent = pcall(function()
        return chatbox.sendMessage(message, "Quarry", "[]", "&b")
    end)
    if not ok or sent ~= true then
        pcall(function()
            return chatbox.sendMessage(message, {
                prefix = "Quarry",
                brackets = "[]",
                bracketsColor = "&b",
            })
        end)
    end
    sleep(1)
end

local function playFallback()
    if not speaker then return end
    -- Use built-in Minecraft sounds as well as notes. This works on older
    -- CraftOS versions which do not ship cc.audio.dfpwm or require().
    pcall(function() speaker.playSound("block.note_block.pling", 2, 1.2) end)
    pcall(function() speaker.playNote("pling", 2, 1.0) end)
    sleep(0.15)
    pcall(function() speaker.playSound("block.note_block.chime", 2, 1.6) end)
    pcall(function() speaker.playNote("pling", 2, 1.5) end)
end

local function playDfpwm(path)
    if not speaker or not speaker.playAudio or not fs.exists(path) then
        playFallback()
        return
    end
    if type(require) ~= "function" then
        print("DFPWM library unavailable; using startup tone")
        playFallback()
        return
    end
    local loaded, dfpwm = pcall(require, "cc.audio.dfpwm")
    if not loaded or not dfpwm then
        print("DFPWM library unavailable; using startup tone")
        playFallback()
        return
    end
    local decoder = dfpwm.make_decoder()
    local file = fs.open(path, "rb")
    if not file then
        playFallback()
        return
    end
    while true do
        local chunk = file.read(16 * 1024)
        if not chunk then break end
        local audio = decoder(chunk)
        while not speaker.playAudio(audio) do
            os.pullEvent("speaker_audio_empty")
        end
    end
    file.close()
end

local turtles = {
    miner = {
        name = "Mining Turtle", id = nil, active = false, fuel = "?",
        task = "Waiting", error = "-", mined = 0, ores = 0,
        lastBlock = "-", lastOre = "-", x = 0, y = 0, z = 0,
        top = {}, lastSeen = 0, progress = nil, progressMax = 100,
    },
    sorter = {
        name = "Sorter Turtle", id = nil, active = false, fuel = "?",
        task = "Waiting", error = "-", lastSeen = 0, progress = nil, progressMax = 100,
    },
    lava = {
        name = "Lava Turtle", id = nil, active = false, fuel = "?",
        task = "Waiting", error = "-", filled = "?", empty = "?",
        progress = nil, progressMax = 100,
        lastSeen = 0,
    },
}

local pendingQuestions = {}
local questionOrder = {}
local animation = 1
local lastDraw = 0

local function now()
    return os.epoch("utc") / 1000
end

local function cleanName(name, limit)
    if not name then return "-" end
    local result = tostring(name):gsub("minecraft:", "")
    if #result > limit then result = result:sub(1, limit - 3) .. "..." end
    return result
end

local function colorFor(role)
    if role == "miner" then return colors.lime end
    if role == "sorter" then return colors.yellow end
    return colors.orange
end

local function displayLength(text)
    local count = 0
    for _ in tostring(text):gmatch("[^\128-\191][\128-\191]*") do
        count = count + 1
    end
    return count
end

local function clipText(text, limit)
    local output = {}
    local count = 0
    for character in tostring(text):gmatch("[^\128-\191][\128-\191]*") do
        if count >= limit then break end
        output[#output + 1] = character
        count = count + 1
    end
    return table.concat(output)
end

local function writeAt(x, y, text, color)
    local width, height = monitor.getSize()
    if y < 1 or y > height then return end
    if x < 1 then x = 1 end
    text = clipText(text, math.max(0, width - x + 1))
    monitor.setCursorPos(x, y)
    monitor.setTextColor(color or colors.white)
    monitor.write(text)
end

local function bar(value, maximum, width)
    if type(value) ~= "number" or value < 0 then
        return string.rep("-", width)
    end
    local filled = math.floor(math.min(1, value / maximum) * width)
    return string.rep("#", filled) .. string.rep("-", width - filled)
end

local function activityBar(active, width)
    if not active then return string.rep("-", width) end
    local marker = ((animation - 1) % width) + 1
    return string.rep("-", marker - 1) .. "#" .. string.rep("-", width - marker)
end

local function cardLine(x, y, width, text, color)
    local inner = width - 2
    text = clipText(text, math.max(0, inner - 2))
    writeAt(x, y, "║ " .. text .. string.rep(" ", math.max(0, inner - displayLength(text) - 1)) .. "║", color)
end

local function drawCard(x, y, width, height, title, accent, lines)
    local inner = width - 2
    writeAt(x, y, "╔" .. string.rep("═", inner) .. "╗", accent)
    cardLine(x, y + 1, width, title, accent)
    for index, line in ipairs(lines) do
        if index + 1 < height then
            cardLine(x, y + index + 1, width, line.text, line.color)
        end
    end
    writeAt(x, y + height - 1, "╚" .. string.rep("═", inner) .. "╝", accent)
end

local function draw()
    local width, height = monitor.getSize()
    monitor.setBackgroundColor(colors.black)
    monitor.clear()

    local miner = turtles.miner
    local sorter = turtles.sorter
    local lava = turtles.lava
    local left = 2
    local panelWidth = math.max(24, math.floor((width - 5) / 2))
    local right = width - panelWidth - 1
    local panelTop = 4
    local panelHeight = math.min(15, math.max(12, height - 14))

    local title = "ATM10 // DEEP QUARRY"
    writeAt(math.max(2, math.floor((width - #title) / 2)), 1, title, colors.cyan)
    writeAt(2, 2, "STATION " .. os.getComputerID(), colors.lightGray)
    writeAt(math.max(2, width - 24), 2, "WIRELESS  /  READY", colors.lime)
    local divider = "┌── ⋆⋅☆⋅⋆ ──┐"
    writeAt(math.max(2, math.floor((width - displayLength(divider)) / 2)), 3, divider, colors.blue)

    local minerFuel = type(miner.fuel) == "number" and miner.fuel or nil
    local minerFuelMax = 50000
    local minerTaskWidth = panelWidth - 6
    local minerTask = miner.progress and bar(miner.progress, miner.progressMax or 100, minerTaskWidth)
        or activityBar(miner.active, minerTaskWidth)
    drawCard(left, panelTop, panelWidth, panelHeight, "MINER  /  QUARRY", colors.lime, {
        { text = (miner.active and "ONLINE" or "OFFLINE") .. "    ID " .. (miner.id or "-"), color = miner.active and colors.lime or colors.gray },
        { text = "FUEL  " .. tostring(miner.fuel), color = colors.lightBlue },
        { text = "[" .. bar(minerFuel, minerFuelMax, minerTaskWidth) .. "]", color = minerFuel and (minerFuel < FUEL_WARN.miner and colors.red or colors.green) or colors.gray },
        { text = "TASK  " .. cleanName(miner.task, panelWidth - 8), color = colors.white },
        { text = "[" .. minerTask .. "]", color = miner.active and colors.lime or colors.gray },
        { text = "ERROR " .. cleanName(miner.error, panelWidth - 8), color = miner.error ~= "-" and colors.red or colors.gray },
        { text = "------------------------------", color = colors.gray },
        { text = "BLOCKS  " .. miner.mined .. "     ORES  " .. miner.ores, color = colors.white },
        { text = "POS     " .. miner.x .. "," .. miner.y .. "," .. miner.z, color = colors.lightBlue },
        { text = "LAST    " .. cleanName(miner.lastBlock, panelWidth - 10), color = colors.lime },
        { text = "ORE     " .. cleanName(miner.lastOre, panelWidth - 10), color = colors.orange },
    })

    local function compactLines(t, role, maximum)
        local value = type(t.fuel) == "number" and t.fuel or nil
        local taskWidth = panelWidth - 6
        local task = t.progress and bar(t.progress, t.progressMax or 100, taskWidth)
            or activityBar(t.active, taskWidth)
        local lines = {
            { text = (t.active and "ONLINE" or "OFFLINE") .. "    ID " .. (t.id or "-"), color = t.active and colors.lime or colors.gray },
            { text = "FUEL  " .. tostring(t.fuel), color = colors.lightBlue },
            { text = "[" .. bar(value, maximum, taskWidth) .. "]", color = value and (value < FUEL_WARN[role] and colors.red or colors.green) or colors.gray },
            { text = "TASK  " .. cleanName(t.task, panelWidth - 8), color = colors.white },
            { text = "[" .. task .. "]", color = t.active and colorFor(role) or colors.gray },
            { text = "ERROR " .. cleanName(t.error, panelWidth - 8), color = t.error ~= "-" and colors.red or colors.gray },
        }
        if role == "lava" then
            lines[6] = { text = "BUCKETS  F:" .. tostring(t.filled) .. "  E:" .. tostring(t.empty), color = colors.yellow }
            lines[7] = { text = "ERROR " .. cleanName(t.error, panelWidth - 8), color = t.error ~= "-" and colors.red or colors.gray }
        end
        return lines
    end

    drawCard(right, panelTop, panelWidth, 9, "SORTER  /  STORAGE", colors.yellow, compactLines(sorter, "sorter", 15000))
    drawCard(right, panelTop + 10, panelWidth, 9, "LAVA  /  BUCKET SUPPLY", colors.orange, compactLines(lava, "lava", 15000))

    local top = {}
    for name, count in pairs(miner.top) do
        top[#top + 1] = { name = name, count = count }
    end
    table.sort(top, function(a, b) return a.count > b.count end)
    local summaryY = math.max(panelTop + panelHeight + 2, panelTop + 21)
    local summaryHeight = math.max(5, height - summaryY - 2)
    local summaryWidth = math.floor(width * 0.55)
    writeAt(2, summaryY, "QUARRY SUMMARY", colors.cyan)
    writeAt(2, summaryY + 1, "LAST BLOCK  " .. cleanName(miner.lastBlock, 22), colors.lightGray)
    writeAt(2, summaryY + 2, "LAST ORE    " .. cleanName(miner.lastOre, 22), colors.orange)
    writeAt(2, summaryY + 3, "ORE QUEUE   " .. #questionOrder .. " pending player decisions", colors.yellow)
    writeAt(summaryWidth, summaryY, "TOP BLOCKS", colors.cyan)
    for i = 1, math.min(5, #top, summaryHeight - 1) do
        writeAt(summaryWidth, summaryY + i, string.format("%d  %-18s  %d", i, cleanName(top[i].name, 18), top[i].count), colors.lightGray)
    end

    local bullFrames = {
        {
            "(__)",
            "(@@)_____",
            "(OO)    /|\\",
            "  | |--/ | *",
            "  w w w  w",
        },
        {
            "(__)",
            "(??)_____",
            "(oo)    /|\\",
            "  | |--/ | *",
            "  w w w  w",
        },
        {
            "(__)",
            "(^^)_____",
            "(OO)    /|\\",
            "  | |--/ | *",
            "  w w w  w",
        },
        {
            "(__)",
            "(--)_____",
            "(oo)    /|\\",
            "  | |--/ | *",
            "  w w w  w",
        },
        {
            "(__)",
            "(** )_____",
            "(OO)    /|\\",
            "  | |--/ | *",
            "  w w w  w",
        },
        {
            "(__)",
            "(^^)_____",
            "(oo)    /|\\",
            "  | |--/ | *",
            "  w w w  w",
        },
    }
    local frame = bullFrames[((animation - 1) % #bullFrames) + 1]
    local px = math.max(1, width - 19)
    local py = math.max(1, height - 7)
    for index, line in ipairs(frame) do
        writeAt(px, py + index - 1, line, colors.yellow)
    end
    local systemState = (miner.active or sorter.active or lava.active) and "ACTIVE" or "IDLE"
    writeAt(2, height, "SYSTEM " .. systemState, colors.gray)
    writeAt(math.max(2, width - 25), height, "BULL LINK ACTIVE", colors.lime)
end

local function roleFor(sender, msg)
    local claimed = msg.role
    if claimed == "miner" or claimed == "sorter" or claimed == "lava" then
        if msg.type == "hello" then
            if saved.paired[claimed] and saved.paired[claimed] ~= sender then return nil end
            return claimed
        end
        if turtles[claimed].id == sender or saved.paired[claimed] == sender then
            return claimed
        end
    end
    for role, t in pairs(turtles) do
        if t.id == sender or saved.paired[role] == sender then return role end
    end
    return nil
end

local function updateCommon(t, msg)
    t.lastSeen = now()
    if msg.label then t.name = msg.label end
    if msg.fuel ~= nil then t.fuel = msg.fuel end
    if msg.task then t.task = msg.task end
    if msg.status then t.task = msg.status end
    if msg.progress ~= nil then t.progress = msg.progress end
    if msg.progressMax ~= nil then t.progressMax = msg.progressMax end
    t.active = msg.active ~= false
    if msg.type ~= "error" then t.error = "-" end
    if msg.error then t.error = msg.error end
end

local function askUnknown(sender, ore)
    local key = tostring(ore)
    if saved.smeltable[key] then
        rednet.send(sender, { type = "ore_decision", ore = key, smeltable = true }, PROTOCOL)
        return
    end
    if saved.unsmeltable[key] then
        rednet.send(sender, { type = "ore_decision", ore = key, smeltable = false }, PROTOCOL)
        return
    end
    if pendingQuestions[key] then return end
    pendingQuestions[key] = { sender = sender, ore = key, expires = now() + 300 }
    questionOrder[#questionOrder + 1] = key
    chatSend("Can I smelt " .. key .. "? Y/N")
    draw()
end

local function handleMessage(sender, msg)
    if type(msg) ~= "table" or not msg.type then return end
    if msg.type == "hello" then
        local role = roleFor(sender, msg)
        if not role then return end
        local t = turtles[role]
        if saved.paired[role] and saved.paired[role] ~= sender then
            rednet.send(sender, { type = "reject", reason = "Role already paired" }, PROTOCOL)
            return
        end
        if t.id and t.id ~= sender then
            rednet.send(sender, { type = "reject", reason = "Role already connected" }, PROTOCOL)
            return
        end
        t.id = sender
        saved.paired[role] = sender
        saveData()
        t.active = true
        t.error = "-"
        t.lastSeen = now()
        if msg.label then t.name = msg.label end
        chatSend(t.name .. " #" .. sender .. " has been connected!")
        rednet.send(sender, {
            type = "ack", stationId = os.getComputerID(), role = role,
        }, PROTOCOL)
        draw()
        return
    end

    local role = roleFor(sender, msg)
    if not role then return end
    local t = turtles[role]
    if not t.id then t.id = sender end
    updateCommon(t, msg)

    if msg.type == "mined" and role == "miner" and msg.block then
        local count = msg.count or 1
        t.mined = t.mined + count
        t.lastBlock = msg.block
        t.top[msg.block] = (t.top[msg.block] or 0) + count
    elseif msg.type == "ore" and role == "miner" and msg.block then
        t.ores = t.ores + (msg.count or 1)
        t.lastOre = msg.block
        if speaker then
            speaker.playSound("entity.experience_orb.pickup", 1, 1.5)
            speaker.playSound("block.note_block.pling", 0.8, 1.8)
        end
    elseif msg.type == "position" and role == "miner" then
        t.x, t.y, t.z = msg.x or t.x, msg.y or t.y, msg.z or t.z
    elseif msg.type == "error" then
        t.error = msg.error or "Unknown error"
        t.active = false
        chatSend(t.name .. " error: " .. t.error)
    elseif msg.type == "unknown_ore" and role == "sorter" and msg.ore then
        askUnknown(sender, msg.ore)
    elseif msg.type == "buckets" and role == "lava" then
        t.filled, t.empty = msg.filled or "?", msg.empty or "?"
    end
    draw()
end

local function findQuestion()
    for i = 1, #questionOrder do
        local ore = questionOrder[i]
        local question = pendingQuestions[ore]
        if question then return ore, question end
    end
end

local function removeQuestion(ore)
    pendingQuestions[ore] = nil
    for i = #questionOrder, 1, -1 do
        if questionOrder[i] == ore then table.remove(questionOrder, i) end
    end
end

local function chatLoop()
    while true do
        local _, a, b, c, d, e = os.pullEvent("chat")
        local answer
        local username
        local authorized = not PLAYER_NAME
        local function parseAnswer(value)
            if type(value) ~= "string" then return nil end
            local lower = value:lower():gsub("^%s+", ""):gsub("%s+$", "")
            if lower == "y" or lower == "yes" or lower == "n" or lower == "no" then
                return lower
            end
        end
        -- Older Advanced Peripherals emits username,message; newer versions
        -- may emit uuid,username,message. Prefer those message positions.
        answer = parseAnswer(b) or parseAnswer(c) or parseAnswer(a)
        for _, value in ipairs({ a, b, c, d, e }) do
            if type(value) == "string" and value == PLAYER_NAME then
                authorized = true
                username = value
            end
        end
        if not username then username = b or a end
        if answer and authorized then
            local ore, question = findQuestion()
            if ore and question then
                local yes = answer == "y" or answer == "yes"
                if yes then saved.smeltable[ore] = true else saved.unsmeltable[ore] = true end
                saveData()
                rednet.send(question.sender, {
                    type = "ore_decision", ore = ore, smeltable = yes,
                }, PROTOCOL)
                chatSend(ore .. (yes and " added to smeltable ores." or " will remain unsmeltable."))
                removeQuestion(ore)
                draw()
            end
        end
    end
end

local function timeoutLoop()
    while true do
        local current = now()
        for ore, question in pairs(pendingQuestions) do
            if current >= question.expires then
                saved.unsmeltable[ore] = true
                rednet.send(question.sender, {
                    type = "ore_decision", ore = ore, smeltable = false,
                }, PROTOCOL)
                chatSend("No response for " .. ore .. " in 5 minutes; treating it as unsmeltable.")
                removeQuestion(ore)
            end
        end
        for _, t in pairs(turtles) do
            if t.id and current - t.lastSeen > 15 then t.active = false end
        end
        draw()
        sleep(1)
    end
end

local function rednetLoop()
    while true do
        local sender, message, protocol = rednet.receive(PROTOCOL, 2)
        if sender and protocol == PROTOCOL then handleMessage(sender, message) end
    end
end

local function animationLoop()
    while true do
        animation = animation + 1
        draw()
        sleep(0.35)
    end
end

print("Mining station ID: " .. os.getComputerID())
print("Modem: " .. modemSide .. "  Monitor: " .. monitor.getSize())
chatSend("The Bluetooth device is ready to pair.")
parallel.waitForAll(
    function() playDfpwm(STARTUP_AUDIO) end,
    function()
        parallel.waitForAny(rednetLoop, chatLoop, timeoutLoop, animationLoop)
    end
)
