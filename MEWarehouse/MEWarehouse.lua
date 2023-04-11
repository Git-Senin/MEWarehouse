-- MEWarehouse.lua
--
-- Adapted code from https://gist.github.com/adkinss/592d282d82a8cce95a55db6a33aa6736 
--      by Scott Adkins <adkinss@gmail.com> (Zucanthor)
--
-- This program monitors work requests for the Minecolonies Warehouse and
-- tries to fulfill requests from the Applied Energistics 2 Storage network. If the
-- ME network doesn't have enough items and a crafting pattern exists, a
-- crafting job is scheduled to restock the items in order to fulfill the
-- work request.  The script will continuously loop, monitoring for new
-- requests and checking on crafting jobs to fulfill previous requests.

-- The following is required for setup:
--   * 1 ComputerCraft Computer
--   * 1 or more ComputerCraft Monitors (recommend 3x3 monitors)
--   * 1 Advanced Peripheral Colony Integrator
--   * 1 Advanced Peripheral ME Bridge
--   * 1 Chest or other storage container

--------------------------
-- Init
--------------------------

-- Init Monitor
local monitor = peripheral.find("monitor")
if not monitor then error("Monitor not found.") end
monitor.setTextScale(0.5)
monitor.clear()
monitor.setCursorPos(1, 1)
monitor.setCursorBlink(true)
print("Monitor           initialized.")

-- Init ME Bridge
local bridge = peripheral.find("meBridge")
if not bridge then error("ME Bridge not found.") end
print("ME Bridge         initialized.")

-- Initialize Colony Integrator
local colony = peripheral.find("colonyIntegrator")
if not colony then error("Colony Integrator not found.") end
if not colony.isInColony then error("Colony Integrator is not in a colony.") end
print("Colony Integrator initialized.")

-- Point to Chest
local storage = "left"
print(storage.." Storage initialized.")

-- Init Crafting CPUs
local cpus, err = bridge.getCraftingCPUs()
if err then
    print("Error: " .. err)
else
    local cpuCount = 1
    print("----------- CPUs -------------")
    for _, cpu in ipairs(cpus) do
        print("CPU: "..cpuCount.." ----------------------- ")
        print("  Storage: " .. cpu.storage)
        print("  Co-Processors: " .. cpu.coProcessors)
        print("  Is Busy: " .. tostring(cpu.isBusy))
        cpuCount = cpuCount + 1
    end
end

-- Init logfile
local logFile = "MEWarehouse.log"


-- Prints to the screen one row after another, scrolling the screen when
-- reaching the bottom. Acts as a normal display where text is printed in
-- a standard way. Long lines are not wrapped and newlines are printed as
-- spaces, both to be addressed in a future update.
-- NOTE: No longer used in this program.
function mPrintScrollable(mon, ...)
    w, h = mon.getSize()
    x, y = mon.getCursorPos()

    -- Blink the cursor like a normal display.
    mon.setCursorBlink(true)

    -- For multiple strings, append them with a space between each.
    for i = 2, #arg do t = t.." "..arg[i] end
    mon.write(arg[1])
    if y >= h then
        mon.scroll(1)
        mon.setCursorPos(1, y)
    else
        mon.setCursorPos(1, y+1)
    end
end

-- Prints strings left, centered, or right justified at a specific row and
-- specific foreground/background color.
function mPrintRowJustified(mon, y, pos, text, ...)
    w, h = mon.getSize()
    fg = mon.getTextColor()
    bg = mon.getBackgroundColor()

    if pos == "left" then x = 1 end
    if pos == "center" then x = math.floor((w - #text) / 2) end
    if pos == "right" then x = w - #text end

    if #arg > 0 then mon.setTextColor(arg[1]) end
    if #arg > 1 then mon.setBackgroundColor(arg[2]) end
    mon.setCursorPos(x, y)
    mon.write(text)
    mon.setTextColor(fg)
    mon.setBackgroundColor(bg)
end

-- Utility function that returns true if the provided character is a digit.
-- Yes, this is a hack and there are better ways to do this.  Clearly.
function isdigit(c)
    if c == "0" then return true end
    if c == "1" then return true end
    if c == "2" then return true end
    if c == "3" then return true end
    if c == "4" then return true end
    if c == "5" then return true end
    if c == "6" then return true end
    if c == "7" then return true end
    if c == "8" then return true end
    if c == "9" then return true end
    return false
end

-- Utility function that displays current time and remaining time on timer.
-- For time of day, yellow is day, orange is sunset/sunrise, and red is night.
-- The countdown timer is orange over 15s, yellow under 15s, and red under 5s.
-- At night, the countdown timer is red and shows PAUSED insted of a time.
function displayTimer(mon, t)
    now = os.time()

    cycle = "day"
    cycle_color = colors.orange
    if now >= 4 and now < 6 then
        cycle = "sunrise"
        cycle_color = colors.orange
    elseif now >= 6 and now < 18 then
        cycle = "day"
        cycle_color = colors.yellow
    elseif now >= 18 and now < 19.5 then
        cycle = "sunset"
        cycle_color = colors.orange
    elseif now >= 19.5 or now < 5 then
        cycle = "night"
        cycle_color = colors.red
    end

    timer_color = colors.orange
    if t < 15 then timer_color = colors.yellow end
    if t < 5 then timer_color = colors.red end

    mPrintRowJustified(mon, 1, "left", string.format("Time: %s [%s]    ", textutils.formatTime(now, false), cycle), cycle_color)
    if cycle ~= "night" then mPrintRowJustified(mon, 1, "right", string.format("    Remaining: %ss", t), timer_color)
    else mPrintRowJustified(mon, 1, "right", "    Remaining: PAUSED", colors.red) end
end
--------------------------------------------------------------------------------------------------------------

-- Scan all open work requests from the Warehouse and attempt to satisfy those
-- requests.  Display all activity on the monitor, including time of day and the
-- countdown timer before next scan.  This function is not called at night to
-- save on some ticks, as the colonists are in bed anyways.  Items in red mean
-- work order can't be satisfied by Refined Storage (lack of pattern or lack of
-- required crafting ingredients).  Yellow means order partially filled and a
-- crafting job was scheduled for the rest.  Green means order fully filled.
-- Blue means the Player needs to manually fill the work order.  This includes
-- equipment (Tools of Class), NBT items like armor, weapons and tools, as well
-- as generic requests ike Compostables, Fuel, Food, Flowers, etc.
function scanWorkRequests(mon, rs, chest)
    -- Before we do anything, prep the log file for this scan.
    -- The log file is truncated each time this function is called.
    file = fs.open(logFile, "w")
    print("\nScan starting at", textutils.formatTime(os.time(), false) .. " (" .. os.time() ..").")

    -- We want to keep three different lists so that they can be
    -- displayed on the monitor in a more intelligent way.  The first
    -- list is for the Builder requests.  The second list is for the
    -- non-Builder requests.  The third list is for any armor, tools
    -- and weapons requested by the colonists.
    builder_list = {}
    nonbuilder_list = {}
    equipment_list = {}

    -- Scan RS for all items in its network. Ignore items with NBT data.
    -- If a Builder needs any items with NBT data, this function will need
    -- to be updated to not ignore those items.
    items = rs.listItems()
    item_array = {}
    for index, item in ipairs(items) do
        -- if not item.nbt then
        item_array[item.name] = item.amount
        -- end
    end
    
    -- Scan the Warehouse for all open work requests. For each item, try to
    -- provide as much as possible from RS, then craft whatever is needed
    -- after that. Green means item was provided entirely. Yellow means item
    -- is being crafted. Red means item is missing crafting recipe.
    workRequests = colony.getRequests()
    file.write(textutils.serialize(workRequests, { allow_repetitions = true }))
    for w in pairs(workRequests) do
        name = workRequests[w].name
        item = workRequests[w].items[1].name
        target = workRequests[w].target
        desc = workRequests[w].desc
        needed = workRequests[w].count
        provided = 0

        target_words = {}
        target_length = 0
        for word in target:gmatch("%S+") do
            table.insert(target_words, word)
            target_length = target_length + 1
        end

        if target_length >= 3 then target_name = target_words[target_length-2] .. " " .. target_words[target_length]
        else target_name = target end

        target_type = ""
        target_count = 1
        repeat
            if target_type ~= "" then target_type = target_type .. " " end
            target_type = target_type .. target_words[target_count]
            target_count = target_count + 1
        until target_count > target_length - 3

        useRS = 1
        if string.find(desc, "Tool of class") then useRS = 0 end
        if string.find(name, "Hoe") then useRS = 0 end
        if string.find(name, "Shovel") then useRS = 0 end
        if string.find(name, "Axe") then useRS = 0 end
        if string.find(name, "Pickaxe") then useRS = 0 end
        if string.find(name, "Bow") then useRS = 0 end
        if string.find(name, "Sword") then useRS = 0 end
        if string.find(name, "Shield") then useRS = 0 end
        if string.find(name, "Helmet") then useRS = 0 end
        if string.find(name, "Leather Cap") then useRS = 0 end
        if string.find(name, "Chestplate") then useRS = 0 end
        if string.find(name, "Tunic") then useRS = 0 end
        if string.find(name, "Pants") then useRS = 0 end
        if string.find(name, "Leggings") then useRS = 0 end
        if string.find(name, "Boots") then useRS = 0 end
        if name == "Rallying Banner" then useRS = 0 end --bugged in alpha versions
        if name == "Crafter" then useRS = 0 end
        if name == "Compostable" then useRS = 0 end
        if name == "Fertilizer" then useRS = 0 end
        if name == "Flowers" then useRS = 0 end
        if name == "Food" then useRS = 0 end
        if name == "Fuel" then useRS = 0 end
        if name == "Smeltable Ore" then useRS = 0 end
        if name == "Stack List" then useRS = 0 end
 
        color = colors.blue
        if useRS == 1 then

            if item_array[item] then
                provided = rs.exportItemToPeripheral({name=item, count=needed}, chest)       
            end

            color = colors.green
            if provided < needed then
                if rs.isItemCrafting({item, cpus[1]}) then
                    color = colors.yellow
                    print("[Crafting]", item)
                else
                    if rs.craftItem({name=item, count=needed} ) then
                        color = colors.yellow
                        print("[Scheduled]", needed, "x", item)
                    else
                        color = colors.red
                        print("[Failed]", item)
                    end
                end
            end
        else
            nameString = name .. " [" .. target .. "]"
            print("[Skipped]", nameString)
        end

        if string.find(desc, "of class") then
            level = "Any Level"
            if string.find(desc, "with maximal level:Leather") then level = "Leather" end
            if string.find(desc, "with maximal level:Gold") then level = "Gold" end
            if string.find(desc, "with maximal level:Chain") then level = "Chain" end
            if string.find(desc, "with maximal level:Wood or Gold") then level = "Wood or Gold" end
            if string.find(desc, "with maximal level:Stone") then level = "Stone" end
            if string.find(desc, "with maximal level:Iron") then level = "Iron" end
            if string.find(desc, "with maximal level:Diamond") then level = "Diamond" end
            new_name = level .. " " .. name
            if level == "Any Level" then new_name = name .. " of any level" end
            new_target = target_type .. " " .. target_name
            equipment = { name=new_name, target=new_target, needed=needed, provided=provided, color=color}
            table.insert(equipment_list, equipment)
        elseif string.find(target, "Builder") then
            builder = { name=name, item=item, target=target_name, needed=needed, provided=provided, color=color }
            table.insert(builder_list, builder)
        else
            new_target = target_type .. " " .. target_name
            if target_length < 3 then
                new_target = target
            end
            nonbuilder = { name=name, target=new_target, needed=needed, provided=provided, color=color }
            table.insert(nonbuilder_list, nonbuilder)
        end
    end
    -- Show the various lists on the attached monitor.
    row = 3
    mon.clear()

    header_shown = 0
    for e in pairs(equipment_list) do
        equipment = equipment_list[e]
        if header_shown == 0 then
            mPrintRowJustified(mon, row, "center", "Equipment")
            header_shown = 1
            row = row + 1
        end
        text = string.format("%d %s", equipment.needed, equipment.name)
        mPrintRowJustified(mon, row, "left", text, equipment.color)
        mPrintRowJustified(mon, row, "right", " " .. equipment.target, equipment.color)
        row = row + 1
    end

    header_shown = 0
    for b in pairs(builder_list) do
        builder = builder_list[b]
        if header_shown == 0 then
            if row > 1 then row = row + 1 end
            mPrintRowJustified(mon, row, "center", "Builder Requests")
            header_shown = 1
            row = row + 1
        end
        text = string.format("%d/%s", builder.provided, builder.name)
        mPrintRowJustified(mon, row, "left", text, builder.color)
        mPrintRowJustified(mon, row, "right", " " .. builder.target, builder.color)
        row = row + 1
    end

    header_shown = 0
    for n in pairs(nonbuilder_list) do
        nonbuilder = nonbuilder_list[n]
        if header_shown == 0 then
            if row > 1 then row = row + 1 end
            mPrintRowJustified(mon, row, "center", "Nonbuilder Requests")
            header_shown = 1
            row = row + 1
        end
        text = string.format("%d %s", nonbuilder.needed, nonbuilder.name)
        if isdigit(nonbuilder.name:sub(1,1)) then
            text = string.format("%d/%s", nonbuilder.provided, nonbuilder.name)
        end
        mPrintRowJustified(mon, row, "left", text, nonbuilder.color)
        mPrintRowJustified(mon, row, "right", " " .. nonbuilder.target, nonbuilder.color)
        row = row + 1
    end

    if row == 3 then mPrintRowJustified(mon, row, "center", "No Open Requests") end
    print("Scan completed at", textutils.formatTime(os.time(), false) .. " (" .. os.time() ..").")
    file.close()
end

--------------------------------------------------------------------------------------------------------------

--------------------------
-- Main
--------------------------
-- Scan for requests periodically. This will catch any updates that were
-- triggered from the previous scan. Right-clicking on the monitor will
-- trigger an immediate scan and reset the timer. Unfortunately, there is
-- no way to capture left-clicks on the monitor.

local time_between_runs = 30
local current_run = time_between_runs
scanWorkRequests(monitor, bridge, storage)
displayTimer(monitor, current_run)
local TIMER = os.startTimer(1)

while true do
    local e = {os.pullEvent()}
    if e[1] == "timer" and e[2] == TIMER then
        now = os.time()
        if now >= 5 and now < 19.5 then
            current_run = current_run - 1
            if current_run <= 0 then
                scanWorkRequests(monitor, bridge, storage)
                current_run = time_between_runs
            end
        end
        displayTimer(monitor, current_run)
        TIMER = os.startTimer(1)
    elseif e[1] == "monitor_touch" then
        os.cancelTimer(TIMER)
        scanWorkRequests(monitor, bridge, storage)
        current_run = time_between_runs
        displayTimer(monitor, current_run)
        TIMER = os.startTimer(1)
    end
end
