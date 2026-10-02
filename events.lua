-- StoryTracker event handlers. Each entry in H is registered by core.lua;
-- handlers call ST:RecordEvent(type, data) to append to the character log.
-- Classic-era (1.15.x) API only.

local _, ST = ...
local H = ST.handlers

-- Individual PLAYER_MONEY events are recorded only for changes at least
-- this large (copper); every change still counts toward session totals.
local MONEY_EVENT_THRESHOLD = 10000 -- 1 gold

-- Damage taken older than this is not blamed for a death.
local KILLER_WINDOW_SECONDS = 15

local MIN_LOOT_QUALITY = 3 -- 3 rare, 4 epic, 5 legendary

local QUALITY_BY_COLOR = {
    ["0070dd"] = 3,
    ["a335ee"] = 4,
    ["ff8000"] = 5,
}

-- Class mounts are learned as spells; everything else is a mount item.
local MOUNT_SPELLS = {
    ["Summon Warhorse"] = true,
    ["Summon Charger"] = true,
    ["Summon Felsteed"] = true,
    ["Summon Dreadsteed"] = true,
}

local NOTABLE_CLASSIFICATIONS = {
    worldboss = true,
    rareelite = true,
    rare = true,
    elite = true,
}

local playerGUID
local state = {
    money = nil,
    factions = nil,      -- [name] = { standingID, value }
    skills = nil,        -- [name] = rank
    group = nil,         -- { kind, members = { [name] = true } }
    unitLevels = {},     -- [name] = level, for group members
    questCache = {},     -- [questID] = { title, level }
    completingTitle = nil,
    abandoning = nil,
    instance = nil,      -- { name, type, maxPlayers, enteredAt }
    bgWinnerRecorded = false,
    lastDamage = nil,    -- { source, ability, amount, time }
    notableTargets = {}, -- [guid] = { name, classification, level, engaged }
}

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

-- Convert a Blizzard format string (e.g. ERR_LEARN_RECIPE_S) into an
-- anchored Lua pattern with captures.
local function FormatToPattern(fmt)
    if type(fmt) ~= "string" then return nil end
    local p = fmt:gsub("%%%d?%$?s", "\001"):gsub("%%%d?%$?d", "\002")
    p = p:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%0")
    p = p:gsub("\001", "(.+)"):gsub("\002", "(%%d+)")
    return "^" .. p .. "$"
end

local function ItemNameFromLink(link)
    return link and link:match("|h%[(.-)%]|h")
end

local function ItemIDFromLink(link)
    local id = link and link:match("|Hitem:(%d+)")
    return id and tonumber(id)
end

local function ItemQuality(link)
    local _, _, quality = GetItemInfo(link)
    if quality then return quality end
    -- Item not cached yet: fall back to the link's color code.
    local color = link:match("|cff(%x%x%x%x%x%x)")
    return color and QUALITY_BY_COLOR[color:lower()] or nil
end

local function IsMountItem(link)
    local _, _, _, _, _, itemType, itemSubType, _, _, _, _, classID, subclassID = GetItemInfo(link)
    if classID == 15 and subclassID == 5 then return true end
    return itemSubType == "Mount" or itemType == "Mount"
end

local function SubZone()
    local sub = GetSubZoneText()
    if sub == "" then return nil end
    return sub
end

local function Continent()
    if not (C_Map and C_Map.GetBestMapForUnit) then return nil end
    local mapID = C_Map.GetBestMapForUnit("player")
    local continentType = (Enum and Enum.UIMapType and Enum.UIMapType.Continent) or 2
    local guard = 0
    while mapID and guard < 10 do
        local info = C_Map.GetMapInfo(mapID)
        if not info then return nil end
        if info.mapType == continentType then return info.name end
        mapID = info.parentMapID
        guard = guard + 1
    end
    return nil
end

local function IsGroupUnit(unit)
    return unit and (unit:match("^party%d") or unit:match("^raid%d")) and true or false
end

local function FullUnitName(unit)
    local name, realm = UnitName(unit)
    if not name or name == UNKNOWNOBJECT or name == "Unknown" then return nil end
    if realm and realm ~= "" then
        return name .. "-" .. realm
    end
    return name
end

------------------------------------------------------------------------
-- Quests
------------------------------------------------------------------------

local function QuestLogEntry(index)
    local title, level, _, isHeader, _, _, _, questID = GetQuestLogTitle(index)
    if not title or isHeader then return nil end
    return title, level, questID
end

local function ScanQuestLog()
    local numEntries = GetNumQuestLogEntries()
    for i = 1, numEntries do
        local title, level, questID = QuestLogEntry(i)
        if title and questID then
            state.questCache[questID] = { title = title, level = level }
        end
    end
end

local function FindQuestIndex(questID)
    for i = 1, GetNumQuestLogEntries() do
        local _, _, id = QuestLogEntry(i)
        if id == questID then return i end
    end
    return nil
end

-- Classic passes (questLogIndex, questID); newer builds pass (questID).
function H.QUEST_ACCEPTED(arg1, arg2)
    local index, questID
    if arg2 then
        index, questID = arg1, arg2
    else
        questID = arg1
        index = FindQuestIndex(questID)
    end
    local title, level, logQuestID
    if index then
        title, level, logQuestID = QuestLogEntry(index)
    end
    questID = questID or logQuestID
    if questID and title then
        state.questCache[questID] = { title = title, level = level }
    end
    ST:RecordEvent("QUEST_ACCEPTED", {
        questName = title,
        questLevel = level,
        questID = questID,
    })
end

function H.QUEST_LOG_UPDATE()
    ScanQuestLog()
end

-- Quest completion dialog is open; remember its title in case the quest
-- has already left the log by the time QUEST_TURNED_IN fires.
function H.QUEST_COMPLETE()
    state.completingTitle = GetTitleText and GetTitleText() or nil
end

-- Classic-era clients signal a turn-in with QUEST_TURNED_IN; it is
-- recorded under the QUEST_COMPLETED type.
function H.QUEST_TURNED_IN(questID, xpReward, moneyReward)
    local cached = questID and state.questCache[questID]
    local title = cached and cached.title
    if not title and C_QuestLog and C_QuestLog.GetQuestInfo then
        title = C_QuestLog.GetQuestInfo(questID)
    end
    title = title or state.completingTitle
    ST:RecordEvent("QUEST_COMPLETED", {
        questName = title,
        questLevel = cached and cached.level or nil,
        questID = questID,
        xpReward = xpReward,
        moneyReward = moneyReward,
    })
    state.completingTitle = nil
    if questID then state.questCache[questID] = nil end
end

-- Classic has no abandon event: SetAbandonQuest() selects the quest and
-- AbandonQuest() commits it, so hook both.
local function HookAbandon()
    if not hooksecurefunc then return end
    hooksecurefunc("SetAbandonQuest", function()
        local name = GetAbandonQuestName and GetAbandonQuestName()
        local index = GetQuestLogSelection and GetQuestLogSelection()
        local level, questID
        if index and index > 0 then
            local title
            title, level, questID = QuestLogEntry(index)
            name = name or title
        end
        state.abandoning = { questName = name, questLevel = level, questID = questID }
    end)
    hooksecurefunc("AbandonQuest", function()
        local info = state.abandoning
        if not info or not info.questName then return end
        ST:RecordEvent("QUEST_ABANDONED", info)
        state.abandoning = nil
    end)
end

------------------------------------------------------------------------
-- Zones, instances, battlegrounds
------------------------------------------------------------------------

local function CheckInstance()
    local inInstance, instanceType = IsInInstance()
    local current = state.instance

    if inInstance and (instanceType == "party" or instanceType == "raid" or instanceType == "pvp") then
        local name, _, _, difficultyName, maxPlayers = GetInstanceInfo()
        if current and current.name == name then return end
        if current then
            -- Zoned directly from one instance to another.
            ST:RecordEvent(current.type == "pvp" and "PVP_BATTLEGROUND_LEFT" or "DUNGEON_LEFT", {
                instanceName = current.name,
                minutesInside = math.floor((time() - current.enteredAt) / 60 + 0.5),
            })
        end
        state.instance = {
            name = name,
            type = instanceType,
            maxPlayers = maxPlayers,
            enteredAt = time(),
        }
        state.bgWinnerRecorded = false
        ST:RecordEvent(instanceType == "pvp" and "PVP_BATTLEGROUND_ENTERED" or "DUNGEON_ENTERED", {
            instanceName = name,
            instanceType = instanceType,
            difficulty = difficultyName ~= "" and difficultyName or nil,
            maxPlayers = maxPlayers,
        })
    elseif current then
        ST:RecordEvent(current.type == "pvp" and "PVP_BATTLEGROUND_LEFT" or "DUNGEON_LEFT", {
            instanceName = current.name,
            minutesInside = math.floor((time() - current.enteredAt) / 60 + 0.5),
        })
        state.instance = nil
    end
end

function H.ZONE_CHANGED_NEW_AREA()
    local zone = GetZoneText()
    if not zone or zone == "" then return end
    if zone ~= state.lastZone then
        state.lastZone = zone
        ST:RecordEvent("ZONE_CHANGED_NEW_AREA", {
            zone = zone,
            subzone = SubZone(),
            continent = Continent(),
        })
    end
    CheckInstance()
end

-- Bosses don't announce themselves in Classic system chat; the encounter
-- events are the reliable signal.
function H.ENCOUNTER_END(encounterID, encounterName, difficultyID, groupSize, success)
    if success ~= 1 and success ~= true then return end
    ST:RecordEvent("DUNGEON_BOSS_KILLED", {
        bossName = encounterName,
        encounterID = encounterID,
        groupSize = groupSize,
        instanceName = state.instance and state.instance.name or nil,
    })
end

local function CheckBattlegroundWinner()
    if state.bgWinnerRecorded or not GetBattlefieldWinner then return end
    local winner = GetBattlefieldWinner()
    if winner == nil then return end
    state.bgWinnerRecorded = true
    local winnerName = (winner == 0 and "Horde") or (winner == 1 and "Alliance") or "Draw"
    ST:RecordEvent("PVP_BATTLEGROUND_ENDED", {
        battleground = state.instance and state.instance.name or GetZoneText(),
        winner = winnerName,
        won = winnerName == UnitFactionGroup("player"),
    })
end

H.UPDATE_BATTLEFIELD_STATUS = CheckBattlegroundWinner
H.UPDATE_BATTLEFIELD_SCORE = CheckBattlegroundWinner

local HONOR_PATTERN = FormatToPattern(COMBATLOG_HONORGAIN)

function H.CHAT_MSG_COMBAT_HONOR_GAIN(msg)
    local data = { text = msg }
    if HONOR_PATTERN then
        local victim, rank, honor = msg:match(HONOR_PATTERN)
        if victim then
            data.victim = victim
            data.rank = rank
            data.estimatedHonor = tonumber(honor)
            data.text = nil
        end
    end
    ST:RecordEvent("PVP_HONORABLE_KILL", data)
end

------------------------------------------------------------------------
-- Levels
------------------------------------------------------------------------

function H.PLAYER_LEVEL_UP(level, healthDelta, powerDelta, talentPoints)
    level = tonumber(level)
    ST:RecordEvent("PLAYER_LEVEL_UP", {
        level = level,
        healthGained = healthDelta,
        powerGained = powerDelta,
        talentPoints = talentPoints,
        subzone = SubZone(),
    })
    if ST.char then ST.char.level = level end
end

-- Group members' dings. Classic has no system message for these, so
-- watch UNIT_LEVEL on party/raid units.
function H.UNIT_LEVEL(unit)
    if not IsGroupUnit(unit) then return end
    local name = FullUnitName(unit)
    local level = UnitLevel(unit)
    if not name or not level or level <= 0 then return end
    local previous = state.unitLevels[name]
    state.unitLevels[name] = level
    if previous and level > previous then
        ST:RecordEvent("PARTY_LEVEL_UP", { name = name, level = level })
    end
end

------------------------------------------------------------------------
-- Combat: deaths and notable kills
------------------------------------------------------------------------

local AFFILIATION_FRIENDLY = bit.bor(
    COMBATLOG_OBJECT_AFFILIATION_MINE or 0x1,
    COMBATLOG_OBJECT_AFFILIATION_PARTY or 0x2,
    COMBATLOG_OBJECT_AFFILIATION_RAID or 0x4)

function H.COMBAT_LOG_EVENT_UNFILTERED()
    local _, subevent, _, sourceGUID, sourceName, sourceFlags, _, destGUID, destName,
        _, _, a12, a13, a14, a15 = CombatLogGetCurrentEventInfo()

    if destGUID == playerGUID then
        local ability, amount
        if subevent == "SWING_DAMAGE" then
            ability, amount = "Melee", a12
        elseif subevent == "RANGE_DAMAGE" or subevent == "SPELL_DAMAGE"
            or subevent == "SPELL_PERIODIC_DAMAGE" then
            ability, amount = a13, a15
        elseif subevent == "ENVIRONMENTAL_DAMAGE" then
            ability, amount = a12, a13
            sourceName = "Environment"
        end
        if ability then
            state.lastDamage = {
                source = sourceName,
                ability = ability,
                amount = amount,
                time = time(),
            }
        end
        return
    end

    local notable = state.notableTargets[destGUID]
    if not notable then return end
    if subevent:find("_DAMAGE$") and sourceFlags
        and bit.band(sourceFlags, AFFILIATION_FRIENDLY) ~= 0 then
        notable.engaged = true
    elseif (subevent == "UNIT_DIED" or subevent == "PARTY_KILL") and notable.engaged then
        state.notableTargets[destGUID] = nil
        ST:RecordEvent("NOTABLE_KILL", {
            name = notable.name or destName,
            classification = notable.classification,
            level = notable.level,
        })
    end
end

-- Remember elites/rares/world bosses the player targets so their death
-- can be recorded. Elites inside dungeons are skipped (that's just trash;
-- bosses come through ENCOUNTER_END).
function H.PLAYER_TARGET_CHANGED()
    if not UnitExists("target") or UnitIsPlayer("target") or UnitIsDead("target") then return end
    if not UnitCanAttack("player", "target") then return end
    local classification = UnitClassification("target")
    if not NOTABLE_CLASSIFICATIONS[classification] then return end
    local inInstance = IsInInstance()
    if inInstance and classification == "elite" then return end
    local guid = UnitGUID("target")
    if not guid or state.notableTargets[guid] then return end
    state.notableTargets[guid] = {
        name = UnitName("target"),
        classification = classification,
        level = UnitLevel("target"),
        engaged = false,
    }
end

function H.PLAYER_DEAD()
    local data = { subzone = SubZone(), level = UnitLevel("player") }
    local hit = state.lastDamage
    if hit and (time() - hit.time) <= KILLER_WINDOW_SECONDS then
        data.killer = hit.source
        data.killingBlow = hit.ability
        data.damage = hit.amount
    end
    if state.instance then
        data.instanceName = state.instance.name
    end
    ST:RecordEvent("PLAYER_DEAD", data)
    state.lastDamage = nil
end

------------------------------------------------------------------------
-- Loot and mounts
------------------------------------------------------------------------

local SELF_LOOT_PATTERNS = {}
for _, fmt in ipairs({
    LOOT_ITEM_SELF_MULTIPLE, LOOT_ITEM_SELF,
    LOOT_ITEM_PUSHED_SELF_MULTIPLE, LOOT_ITEM_PUSHED_SELF,
    LOOT_ITEM_CREATED_SELF_MULTIPLE, LOOT_ITEM_CREATED_SELF,
}) do
    local pattern = FormatToPattern(fmt)
    if pattern then table.insert(SELF_LOOT_PATTERNS, pattern) end
end

local function ParseSelfLoot(msg)
    for _, pattern in ipairs(SELF_LOOT_PATTERNS) do
        local link, count = msg:match(pattern)
        if link then return link, tonumber(count) or 1 end
    end
    return nil
end

function H.CHAT_MSG_LOOT(msg)
    local link, count = ParseSelfLoot(msg)
    if not link or not link:find("|Hitem:") then return end

    if IsMountItem(link) then
        ST:RecordEvent("MOUNT_LEARNED", {
            mountName = ItemNameFromLink(link),
            itemID = ItemIDFromLink(link),
            source = "item",
        })
    end

    local quality = ItemQuality(link)
    if not quality or quality < MIN_LOOT_QUALITY then return end
    ST:RecordEvent("CHAT_MSG_LOOT", {
        itemName = ItemNameFromLink(link),
        itemID = ItemIDFromLink(link),
        itemLink = link,
        quality = quality,
        qualityName = _G["ITEM_QUALITY" .. quality .. "_DESC"],
        count = count,
    })
end

------------------------------------------------------------------------
-- Reputation
------------------------------------------------------------------------

local function StandingLabel(standingID)
    return _G["FACTION_STANDING_LABEL" .. tostring(standingID)]
end

-- Only factions under expanded headers are visible to GetFactionInfo;
-- collapsed ones are simply not compared until expanded.
local function SnapshotFactions()
    local snapshot = {}
    for i = 1, GetNumFactions() do
        local name, _, standingID, _, _, barValue, _, _, isHeader, _, hasRep = GetFactionInfo(i)
        if name and (not isHeader or hasRep) then
            snapshot[name] = { standingID = standingID, value = barValue }
        end
    end
    return snapshot
end

function H.UPDATE_FACTION()
    local current = SnapshotFactions()
    local previous = state.factions
    state.factions = current
    if not previous then return end
    for name, now in pairs(current) do
        local before = previous[name]
        if not before then
            ST:RecordEvent("UPDATE_FACTION", {
                faction = name,
                change = "discovered",
                standing = StandingLabel(now.standingID),
                standingID = now.standingID,
            })
        elseif before.standingID ~= now.standingID then
            ST:RecordEvent("UPDATE_FACTION", {
                faction = name,
                change = now.standingID > before.standingID and "increased" or "decreased",
                standing = StandingLabel(now.standingID),
                standingID = now.standingID,
                previousStanding = StandingLabel(before.standingID),
            })
        end
    end
end

------------------------------------------------------------------------
-- Professions
------------------------------------------------------------------------

local PROFESSION_HEADERS = {
    [TRADE_SKILLS or "Professions"] = true,
    [SECONDARY_SKILLS or "Secondary Skills"] = true,
    ["Professions"] = true,
    ["Secondary Skills"] = true,
}

-- Returns [name] = { rank, max, header }. Collapsed headers hide their
-- children, same caveat as factions.
local function SnapshotSkills()
    local snapshot = {}
    local header
    for i = 1, GetNumSkillLines() do
        local name, isHeader, _, rank, _, _, maxRank = GetSkillLineInfo(i)
        if isHeader then
            header = name
        elseif name then
            snapshot[name] = { rank = rank, max = maxRank, header = header }
        end
    end
    return snapshot
end

function H.SKILL_LINES_CHANGED()
    local current = SnapshotSkills()
    local previous = state.skills
    state.skills = current
    if not previous then return end
    for name, now in pairs(current) do
        local before = previous[name]
        local isProfession = PROFESSION_HEADERS[now.header or ""]
        if not before then
            ST:RecordEvent("SKILL_LEARNED", {
                skill = name,
                category = now.header,
                rank = now.rank,
                maxRank = now.max,
            })
        elseif isProfession and now.rank > before.rank then
            ST:RecordEvent("SKILL_LINES_CHANGED", {
                skill = name,
                rank = now.rank,
                previousRank = before.rank,
                maxRank = now.max,
            })
        elseif isProfession and now.max > before.max then
            ST:RecordEvent("SKILL_LINES_CHANGED", {
                skill = name,
                rank = now.rank,
                maxRank = now.max,
                previousMaxRank = before.max,
                change = "rank_up",
            })
        end
    end
end

------------------------------------------------------------------------
-- Gold
------------------------------------------------------------------------

function H.PLAYER_MONEY()
    local money = GetMoney()
    local previous = state.money
    state.money = money
    if not previous then return end
    local delta = money - previous
    if delta == 0 then return end

    local session = ST:CurrentSession()
    if session then
        if delta > 0 then
            session.moneyEarned = (session.moneyEarned or 0) + delta
        else
            session.moneySpent = (session.moneySpent or 0) - delta
        end
    end

    if math.abs(delta) >= MONEY_EVENT_THRESHOLD then
        ST:RecordEvent("PLAYER_MONEY", {
            delta = delta,
            total = money,
            direction = delta > 0 and "earned" or "spent",
        })
    end
end

------------------------------------------------------------------------
-- Social: guild and group
------------------------------------------------------------------------

local function CheckGuild()
    local char = ST.char
    local inGuild = IsInGuild()
    local guildName, rankName = GetGuildInfo("player")
    -- In a guild but roster not loaded yet: nothing reliable to compare.
    if inGuild and not guildName then return end
    local newGuild = inGuild and guildName or nil

    if not state.guildBaselined then
        state.guildBaselined = true
        -- Compare against what we stored last session, if we know it.
        if not char.guildKnown then
            char.guild = newGuild
            char.guildKnown = true
            return
        end
    end

    local oldGuild = char.guild
    if oldGuild == newGuild then return end
    if oldGuild then
        ST:RecordEvent("GUILD_LEFT", { guild = oldGuild })
    end
    if newGuild then
        ST:RecordEvent("GUILD_JOINED", { guild = newGuild, rank = rankName })
    end
    char.guild = newGuild
    char.guildKnown = true
end

H.GUILD_ROSTER_UPDATE = CheckGuild
H.PLAYER_GUILD_UPDATE = CheckGuild

local function GroupSnapshot()
    local kind = (IsInRaid() and "raid") or (IsInGroup() and "party") or nil
    local members = {}
    local count = 0
    if kind then
        local prefix = kind == "raid" and "raid" or "party"
        local total = kind == "raid" and GetNumGroupMembers() or GetNumSubgroupMembers()
        for i = 1, total do
            local unit = prefix .. i
            local name = FullUnitName(unit)
            if name and not UnitIsUnit(unit, "player") then
                members[name] = true
                count = count + 1
                local level = UnitLevel(unit)
                if level and level > 0 and not state.unitLevels[name] then
                    state.unitLevels[name] = level
                end
            end
        end
    end
    return { kind = kind, members = members, count = count }
end

local function SortedKeys(t)
    local list = {}
    for k in pairs(t) do table.insert(list, k) end
    table.sort(list)
    return list
end

function H.GROUP_ROSTER_UPDATE()
    local current = GroupSnapshot()
    local previous = state.group
    state.group = current
    if not previous then return end

    local joined, left = {}, {}
    for name in pairs(current.members) do
        if not previous.members[name] then joined[name] = true end
    end
    for name in pairs(previous.members) do
        if not current.members[name] then
            left[name] = true
            state.unitLevels[name] = nil
        end
    end

    local action
    if not previous.kind and current.kind then
        action = "formed"
    elseif previous.kind and not current.kind then
        action = "disbanded"
    elseif previous.kind ~= current.kind then
        action = "converted"
    elseif next(joined) or next(left) then
        action = "changed"
    end
    if not action then return end

    ST:RecordEvent("GROUP_ROSTER_UPDATE", {
        action = action,
        groupType = current.kind or previous.kind,
        size = current.count + (current.kind and 1 or 0),
        joined = next(joined) and SortedKeys(joined) or nil,
        left = next(left) and SortedKeys(left) or nil,
    })
end

------------------------------------------------------------------------
-- System messages
------------------------------------------------------------------------

local playerName = UnitName("player")

local function OnSpellLearned(spell, kind)
    if MOUNT_SPELLS[spell] then
        ST:RecordEvent("MOUNT_LEARNED", { mountName = spell, source = "spell" })
    else
        ST:RecordEvent("SPELL_LEARNED", { spell = spell, kind = kind })
    end
end

local function OnDuel(winner, loser, how)
    if winner ~= playerName and loser ~= playerName then return end
    ST:RecordEvent("PVP_DUEL", {
        winner = winner,
        loser = loser,
        won = winner == playerName,
        result = how,
    })
end

-- { pattern, handler(captures...) }. Built from Blizzard's localized
-- format strings so they work on non-English clients.
local SYSTEM_PATTERNS = {}
local function AddSystemPattern(fmt, fn)
    local pattern = FormatToPattern(fmt)
    if pattern then table.insert(SYSTEM_PATTERNS, { pattern, fn }) end
end

AddSystemPattern(ERR_LEARN_RECIPE_S, function(recipe)
    ST:RecordEvent("RECIPE_LEARNED", { recipe = recipe })
end)
AddSystemPattern(ERR_LEARN_SPELL_S, function(spell) OnSpellLearned(spell, "spell") end)
AddSystemPattern(ERR_LEARN_ABILITY_S, function(spell) OnSpellLearned(spell, "ability") end)
AddSystemPattern(ERR_ZONE_EXPLORED_XP, function(area, xp)
    ST:RecordEvent("ZONE_EXPLORED", { area = area, xp = tonumber(xp) })
end)
AddSystemPattern(ERR_ZONE_EXPLORED, function(area)
    ST:RecordEvent("ZONE_EXPLORED", { area = area })
end)
AddSystemPattern(INSTANCE_SAVED, function()
    ST:RecordEvent("INSTANCE_SAVED", {
        instanceName = state.instance and state.instance.name or GetZoneText(),
    })
end)
AddSystemPattern(DUEL_WINNER_KNOCKOUT, function(winner, loser) OnDuel(winner, loser, "knockout") end)
AddSystemPattern(DUEL_WINNER_RETREAT, function(loser, winner) OnDuel(winner, loser, "retreat") end)

function H.CHAT_MSG_SYSTEM(msg)
    if type(msg) ~= "string" then return end
    for _, entry in ipairs(SYSTEM_PATTERNS) do
        -- Patterns without captures return the whole match.
        local c1, c2, c3 = msg:match(entry[1])
        if c1 then
            entry[2](c1, c2, c3)
            return
        end
    end
end

------------------------------------------------------------------------
-- Baselines
------------------------------------------------------------------------

-- On login/reload, snapshot everything we diff against so the first real
-- change is recorded but the initial state is not. Loading screens
-- within a session also fire this; there we only re-check the zone.
function H.PLAYER_ENTERING_WORLD()
    playerGUID = UnitGUID("player")
    playerName = UnitName("player")

    if ST.sessionStarting then
        state.money = GetMoney()
        state.factions = SnapshotFactions()
        state.skills = SnapshotSkills()
        state.group = GroupSnapshot()
        state.lastZone = GetZoneText()
        ScanQuestLog()
        CheckGuild()
        -- Record where the session began, plus dungeon state if we logged
        -- in inside one.
        CheckInstance()
    else
        H.ZONE_CHANGED_NEW_AREA()
    end
end

function ST:OnLoad()
    HookAbandon()
end
