-- HoT Predict
-- Extends Blizzard health bars (compact party/raid frames, player, target, focus, party) with the healing your own
-- HoTs still have to do, drawn right after the filled part of the bar like the incoming-heal bar of a cast.
--
-- WoW Forever does not let addons read the combat log or (in combat) auras, so this tracks YOUR OWN HoT casts:
-- it sees you cast Rejuvenation/Renew/... on someone, reads the HoT amount and duration from the spell's
-- description, and counts down the healing left. Other players' HoTs cannot be tracked by any addon.

local ADDON = ...

local DEFAULTS = { enabled = true, scale = 1.0, alpha = 0.55, r = 0.25, g = 1.0, b = 0.55, inset = 3, clip = false }
local db

local GetTime, UnitExists, UnitGUID = GetTime, UnitExists, UnitGUID
local InCombatLockdown = InCombatLockdown

-- A value the client marked secret may be passed to widgets but not inspected; treat it as unknown here.
local function plain(v)
    if v == nil then return nil end
    if issecretvalue and issecretvalue(v) then return nil end
    return v
end

local function Print(msg) DEFAULT_CHAT_FRAME:AddMessage("|cff40ff90HoT Predict|r: " .. msg) end

local function SpellName(id)
    if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(id) end
    if GetSpellInfo then return (GetSpellInfo(id)) end
end

local function SpellDescription(id)
    if C_Spell and C_Spell.GetSpellDescription then return C_Spell.GetSpellDescription(id) end
    if GetSpellDescription then return GetSpellDescription(id) end
end

--------------------------------------------------------------------------------------------------------------------
-- HoT data from the spell description: "Heals the target for 32 over 12 sec.", "... and another 98 over 21 sec.",
-- "Heals the target of 45 damage over 15 sec."
--------------------------------------------------------------------------------------------------------------------
local hotInfo = {} -- spellID -> {total, duration} or false (not a HoT)

local PATTERNS = {
    "(%d[%d,]*) over (%d+%.?%d*) sec",
    "(%d[%d,]*) %a+ over (%d+%.?%d*) sec",
    "(%d[%d,]*) %a+ %a+ over (%d+%.?%d*) sec",
}

local function ParseHot(desc)
    desc = plain(desc)
    if type(desc) ~= "string" or desc == "" then return nil end
    local lower = desc:lower()
    if not lower:find("heal") then return false end
    for _, pat in ipairs(PATTERNS) do
        local amount, dur = lower:match(pat)
        if amount then
            amount = tonumber((amount:gsub(",", "")))
            dur = tonumber(dur)
            if amount and dur and amount > 0 and dur > 0 then return { total = amount, duration = dur } end
        end
    end
    return false
end

local function GetHotInfo(spellID)
    local cached = hotInfo[spellID]
    if cached ~= nil then return cached or nil end
    local desc = SpellDescription(spellID)
    local info = ParseHot(desc)
    if info == nil then
        -- Description not loaded yet: ask for it and try again on the next cast
        if Spell and Spell.CreateFromSpellID then
            local s = Spell:CreateFromSpellID(spellID)
            if s and s.ContinueOnSpellLoad then s:ContinueOnSpellLoad(function() hotInfo[spellID] = ParseHot(SpellDescription(spellID)) end) end
        end
        return nil
    end
    hotInfo[spellID] = info
    return info or nil
end

--------------------------------------------------------------------------------------------------------------------
-- Tracking your own HoTs: hots[key][spellName] = {total, duration, start}
--------------------------------------------------------------------------------------------------------------------
local hots = {}
local pendingTarget = {} -- castGUID -> target name from UNIT_SPELLCAST_SENT

local UNITS = { "player", "target", "focus", "mouseover" }
for i = 1, 4 do UNITS[#UNITS + 1] = "party" .. i end
for i = 1, 40 do UNITS[#UNITS + 1] = "raid" .. i end

local function UnitKey(unit)
    if not unit or not UnitExists(unit) then return nil end
    local guid = plain(UnitGUID(unit))
    if guid then return guid end
    local name = plain(GetUnitName and GetUnitName(unit, true) or UnitName(unit))
    return name and ("name:" .. name) or nil
end

local function UnitFromName(name)
    for _, u in ipairs(UNITS) do
        if UnitExists(u) then
            local short = plain(UnitName(u))
            local full = GetUnitName and plain(GetUnitName(u, true))
            if (short and short == name) or (full and full == name) then return u end
        end
    end
end

local function TargetUnitFor(targetName)
    targetName = plain(targetName)
    if targetName and targetName ~= "" then
        local u = UnitFromName(targetName)
        if u then return u end
        local short = targetName:match("^([^%-]+)%-")
        if short then return UnitFromName(short) end
        return nil
    end
    if UnitExists("target") and UnitCanAssist and plain(UnitCanAssist("player", "target")) then return "target" end
    return "player"
end

local function AddHot(unit, spellID, info, isTest)
    local key = UnitKey(unit)
    local name = SpellName(spellID)
    if not key or not name then return end
    if isTest then name = "HoT Predict test" end
    hots[key] = hots[key] or {}
    hots[key][name] = { total = info.total * (db.scale or 1), duration = info.duration, start = GetTime(), test = isTest }
end

local function Remaining(key)
    local list = key and hots[key]
    if not list then return 0 end
    local now, sum = GetTime(), 0
    for name, h in pairs(list) do
        local left = h.duration - (now - h.start)
        if left <= 0 then
            list[name] = nil
        else
            sum = sum + h.total * left / h.duration
        end
    end
    if not next(list) then hots[key] = nil end
    return sum
end

--------------------------------------------------------------------------------------------------------------------
-- Overlays on Blizzard health bars
--------------------------------------------------------------------------------------------------------------------
local bars = {}     -- healthBar -> function returning the unit shown
local overlays = {} -- healthBar -> {geo, seg, fill}; kept here so nothing is written onto Blizzard's frames

-- How it is drawn:
--  * geo: an invisible StatusBar of our own, as wide/tall as the health bar, starting where the fill ends. It does
--    the math (max health can be a secret value, which a StatusBar accepts but Lua may not divide by).
--  * seg: the visible segment, a texture created on the health bar itself at the top of the ARTWORK layer. That puts
--    it above the green fill but below the bar's OVERLAY layer, where the "242 / 328" text is drawn. Its right edge
--    follows geo's (invisible) fill.
--  * masks: the bar's own shape mask(s), plus a rectangle mask over the bar so overheal never spills past its end.
local function MakeOverlay(hb)
    if overlays[hb] then return overlays[hb] end
    local fill = hb.GetStatusBarTexture and hb:GetStatusBarTexture()
    if not fill then return nil end

    -- Child of the health bar so it shares its scale (Edit Mode frame size); it is invisible, so its level is moot
    local geo = CreateFrame("StatusBar", nil, hb)
    geo:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    geo:GetStatusBarTexture():SetAlpha(0)
    geo:SetMinMaxValues(0, 1)
    geo:SetValue(0)
    geo:Hide()

    local seg = hb:CreateTexture(nil, "ARTWORK", nil, 7)
    seg:SetTexture("Interface\\Buttons\\WHITE8X8")
    seg:SetPoint("TOPLEFT", geo, "TOPLEFT", 0, 0)
    seg:SetPoint("BOTTOMRIGHT", geo:GetStatusBarTexture(), "BOTTOMRIGHT", 0, 0)
    seg:Hide()

    -- No copy of the bar's own shape mask: that mask stops at the end of the bar and would hide overheal.
    -- The height comes from the health bar instead (see Anchor), so the segment still matches the bar.
    if seg.AddMaskTexture then
        -- Optional (/hotp clip on): a rectangle over the bar that cuts off overheal past the end of the bar.
        -- Off by default, so overheal shows spilling past the bar.
        if db and db.clip and hb.CreateMaskTexture then
            local box = hb:CreateMaskTexture()
            box:SetAllPoints(hb)
            box:SetTexture("Interface\\Buttons\\WHITE8X8", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
            pcall(seg.AddMaskTexture, seg, box)
        end
    end

    overlays[hb] = { geo = geo, seg = seg, fill = fill }
    return overlays[hb]
end

-- geo starts where the fill ends and is as wide and as tall as the health bar itself (the fill texture can be drawn
-- taller than the bar). /hotp inset trims that many pixels off the top and bottom.
local function Anchor(o, hb)
    -- Only the player/target/focus/party frames have border art over the bar; raid/party grid frames keep full height
    local inset = o.decorated and (db and db.inset) or 0
    -- A size the client hides from addons can't be used in math: keep the last size then
    local w, h = plain(hb:GetWidth()), plain(hb:GetHeight())
    if not (w and h) then return end
    o.geo:ClearAllPoints()
    o.geo:SetPoint("LEFT", o.fill, "RIGHT", 0, 0)
    o.geo:SetWidth(math.max(w, 1))
    o.geo:SetHeight(math.max(h - 2 * inset, 1))
end

local function Register(hb, unitFunc, decorated)
    if not hb or bars[hb] or not hb.GetObjectType or hb:GetObjectType() ~= "StatusBar" then return end
    local o = MakeOverlay(hb)
    if not o then return end
    o.decorated = decorated
    Anchor(o, hb)
    hb:HookScript("OnSizeChanged", function(self) Anchor(o, self) end)
    bars[hb] = unitFunc
end

-- Find a health StatusBar under a frame (modern Blizzard frames keep it a few levels down, by parentKey)
local function FindHealthBar(root, depth)
    if not root or (depth or 0) > 6 then return nil end
    for _, key in ipairs({ "healthBar", "HealthBar", "healthbar" }) do
        local v = root[key]
        if type(v) == "table" and v.GetObjectType and v:GetObjectType() == "StatusBar" then return v end
    end
    if not root.GetChildren then return nil end
    for _, child in ipairs({ root:GetChildren() }) do
        local key = (child.GetParentKey and child:GetParentKey() or child:GetName() or ""):lower()
        -- Skip the target-of-target and pet frames nested inside target/party frames
        if not (key:find("tot") or key:find("pet")) then
            if child:GetObjectType() == "StatusBar" and key:find("health") then return child end
            local found = FindHealthBar(child, (depth or 0) + 1)
            if found then return found end
        end
    end
end

-- Known locations of the main health bar on modern Blizzard frames, tried before searching
local function KnownHealthBar(frame)
    local paths = {
        { "PlayerFrameContent", "PlayerFrameContentMain", "HealthBarsContainer", "HealthBar" },
        { "TargetFrameContent", "TargetFrameContentMain", "HealthBarsContainer", "HealthBar" },
        { "TargetFrameContent", "TargetFrameContentMain", "HealthBar" },
        { "HealthBarContainer", "HealthBar" },
        { "HealthBarsContainer", "HealthBar" },
    }
    for _, path in ipairs(paths) do
        local node = frame
        for _, key in ipairs(path) do
            node = node and node[key]
            if type(node) ~= "table" then node = nil break end
        end
        if node and node.GetObjectType and node:GetObjectType() == "StatusBar" then return node end
    end
end

-- CompactUnitFrame_SetUnit also runs for Blizzard's nameplates (incl. the personal one, whose unit is "player").
-- Those can be protected/forbidden for addons, and touching them throws errors that stopped every bar from updating.
local function IsNameplate(frame)
    if frame.IsForbidden and frame:IsForbidden() then return true end
    local unit = frame.displayedUnit or frame.unit
    if type(unit) == "string" and unit:find("^nameplate") then return true end
    local f = frame
    for _ = 1, 3 do
        if not f then break end
        local name = f.GetName and f:GetName()
        -- Nameplates (incl. the personal one) have names hidden from addons; Blizzard's unit frames don't
        if issecretvalue and issecretvalue(name) then return true end
        if type(name) == "string" and name:find("NamePlate") then return true end
        f = f.GetParent and f:GetParent()
    end
    return false
end

local function RegisterCompact(frame)
    if frame and frame.healthBar and not IsNameplate(frame) then
        Register(frame.healthBar, function() return frame.displayedUnit or frame.unit end)
    end
end

local lastError -- last error caught while scanning or updating, shown by /hotp debug

local function Scan()
    local ok, err = pcall(function()
    for i = 1, 5 do RegisterCompact(_G["CompactPartyFrameMember" .. i]) end
    for i = 1, 40 do RegisterCompact(_G["CompactRaidFrame" .. i]) end
    for g = 1, 8 do for m = 1, 5 do RegisterCompact(_G["CompactRaidGroup" .. g .. "Member" .. m]) end end

    local fixed = { player = PlayerFrame, target = TargetFrame, focus = FocusFrame }
    for unit, frame in pairs(fixed) do
        local hb = frame and (KnownHealthBar(frame) or _G[(frame:GetName() or "") .. "HealthBar"] or FindHealthBar(frame))
        if hb then Register(hb, function() return unit end, true) end
    end

    for i = 1, 4 do
        local f = (PartyFrame and PartyFrame["MemberFrame" .. i]) or _G["PartyMemberFrame" .. i]
        if f then
            local hb = KnownHealthBar(f) or _G["PartyMemberFrame" .. i .. "HealthBar"] or FindHealthBar(f)
            local unit = "party" .. i
            if hb then Register(hb, function() return f.unit or unit end, true) end
        end
    end
    end)
    if not ok then lastError = "scan: " .. tostring(err) end
end

local function UpdateBar(hb, unitFunc)
    local o = overlays[hb]
    local unit = db.enabled and unitFunc()
    local key = unit and UnitExists(unit) and UnitKey(unit)
    local amount = key and Remaining(key) or 0
    if amount <= 0 or not hb:IsVisible() then
        if o.seg:IsShown() then o.seg:Hide(); o.geo:Hide() end
        return
    end
    -- When the bar starts showing someone else (new target, roster change), the client may still report the old or a
    -- placeholder max health for a moment, and the health bar's own fill catches up a frame later. Showing the segment
    -- then gives a too-long bar for an instant, so wait a short moment until the numbers have settled.
    local now = GetTime()
    if key ~= o.lastKey then
        o.lastKey = key
        o.settleUntil = now + 0.3
        if o.seg:IsShown() then o.seg:Hide() end
    end
    -- Max health may be secret; widgets accept secret values, so hand it over without looking at it
    if not pcall(o.geo.SetMinMaxValues, o.geo, 0, UnitHealthMax(unit)) then return end
    o.geo:SetValue(amount)
    if not o.geo:IsShown() then o.geo:Show() end
    if now < (o.settleUntil or 0) then return end
    o.seg:SetVertexColor(db.r, db.g, db.b, db.alpha)
    if not o.seg:IsShown() then o.seg:Show() end
end

--------------------------------------------------------------------------------------------------------------------
-- Out of combat, auras can be read: drop HoTs that were dispelled or overwritten, resync timers
--------------------------------------------------------------------------------------------------------------------
local function SyncAuras()
    if InCombatLockdown() or not (C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName) then return end
    for _, u in ipairs(UNITS) do
        local key = UnitKey(u)
        local list = key and hots[key]
        if list then
            if plain(UnitIsDeadOrGhost(u)) then
                hots[key] = nil
            else
                local now = GetTime()
                for name, h in pairs(list) do
                    -- Skip the /hotp test bar (no real aura) and HoTs cast this second (aura may not be applied yet)
                    if not h.test and now - h.start > 1.5 then
                        local ok, aura = pcall(C_UnitAuras.GetAuraDataBySpellName, u, name, "HELPFUL|PLAYER")
                        if ok and issecretvalue and issecretvalue(aura) then
                            ok = false -- hidden from addons here: keep the timer as it is
                        end
                        if ok and aura == nil then
                            list[name] = nil
                        elseif ok and aura then
                            local exp, dur = plain(aura.expirationTime), plain(aura.duration)
                            if exp and dur and dur > 0 then h.start, h.duration = exp - dur, dur end
                        end
                    end
                end
            end
        end
    end
end

--------------------------------------------------------------------------------------------------------------------
-- Events and update loop
--------------------------------------------------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("GROUP_ROSTER_UPDATE")
ev:RegisterUnitEvent("UNIT_SPELLCAST_SENT", "player")
ev:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
ev:RegisterUnitEvent("UNIT_SPELLCAST_FAILED", "player")
ev:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", "player")

ev:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        if ... ~= ADDON then return end
        HotPredictDB = HotPredictDB or {}
        for k, v in pairs(DEFAULTS) do if HotPredictDB[k] == nil then HotPredictDB[k] = v end end
        db = HotPredictDB
        if CompactUnitFrame_SetUnit then hooksecurefunc("CompactUnitFrame_SetUnit", function(frame)
            local ok, err = pcall(RegisterCompact, frame)
            if not ok then lastError = "register: " .. tostring(err) end
        end) end
    elseif event == "PLAYER_ENTERING_WORLD" or event == "GROUP_ROSTER_UPDATE" then
        C_Timer.After(1, Scan)
    elseif event == "UNIT_SPELLCAST_SENT" then
        local _, target, castGUID = ...
        castGUID = plain(castGUID)
        if castGUID then pendingTarget[castGUID] = plain(target) or "" end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local _, castGUID, spellID = ...
        castGUID, spellID = plain(castGUID), plain(spellID)
        local target = castGUID and pendingTarget[castGUID]
        if castGUID then pendingTarget[castGUID] = nil end
        if not spellID then return end
        local info = GetHotInfo(spellID)
        if not info then return end
        local unit = TargetUnitFor(target)
        -- Only friendly targets: keeps out drain-style spells whose text mentions healing over time
        if unit and (not UnitCanAssist or plain(UnitCanAssist("player", unit)) ~= false) then AddHot(unit, spellID, info) end
    else -- failed / interrupted
        local _, castGUID = ...
        castGUID = plain(castGUID)
        if castGUID then pendingTarget[castGUID] = nil end
    end
end)

local elapsedUpdate, elapsedSync = 0, 0
ev:SetScript("OnUpdate", function(_, elapsed)
    if not db then return end
    elapsedUpdate = elapsedUpdate + elapsed
    elapsedSync = elapsedSync + elapsed
    if elapsedUpdate >= 0.1 then
        elapsedUpdate = 0
        -- One bad bar must not stop the others: drop a bar that errors and remember why
        for hb, unitFunc in pairs(bars) do
            local ok, err = pcall(UpdateBar, hb, unitFunc)
            if not ok then
                bars[hb] = nil
                lastError = "update: " .. tostring(err)
            end
        end
    end
    if elapsedSync >= 1 then
        elapsedSync = 0
        local ok, err = pcall(SyncAuras)
        if not ok then lastError = "aura sync: " .. tostring(err) end
    end
end)

--------------------------------------------------------------------------------------------------------------------
-- /hotp
--------------------------------------------------------------------------------------------------------------------
local DebugReport -- defined below
SLASH_HOTPREDICT1, SLASH_HOTPREDICT2 = "/hotp", "/hotpredict"
SlashCmdList.HOTPREDICT = function(msg)
    local cmd, arg = (msg or ""):lower():match("^(%S*)%s*(.-)$")
    if cmd == "on" or cmd == "off" then
        db.enabled = (cmd == "on")
        Print(db.enabled and "on" or "off")
    elseif cmd == "scale" and tonumber(arg) then
        db.scale = tonumber(arg)
        Print(("HoT amounts x%.2f (for new casts)"):format(db.scale))
    elseif cmd == "alpha" and tonumber(arg) then
        db.alpha = math.min(math.max(tonumber(arg), 0.1), 1)
        Print(("opacity %.2f"):format(db.alpha))
    elseif cmd == "inset" and tonumber(arg) then
        db.inset = math.max(tonumber(arg), 0)
        for hb in pairs(bars) do Anchor(overlays[hb], hb) end
        Print(("segment trimmed %d px top and bottom"):format(db.inset))
    elseif cmd == "clip" and (arg == "on" or arg == "off") then
        db.clip = (arg == "on")
        Print("overheal past the end of the bar is " .. (db.clip and "cut off" or "shown") .. " (/reload to apply)")
    elseif cmd == "test" then
        local unit = UnitExists("target") and "target" or "player"
        local max = plain(UnitHealthMax(unit)) or 1000
        AddHot(unit, 774, { total = max * 0.3 / (db.scale or 1), duration = 12 }, true)
        Print("test: 30% of max health for 12 sec on " .. unit)
    elseif cmd == "debug" then
        -- Never let an error here leave the chat box stuck open: report it instead
        local ok, err = pcall(DebugReport)
        if not ok then Print("debug error: " .. tostring(err)) end
        Print("last error: " .. (lastError or "none"))
    else
        Print("/hotp on | off | test | scale <x> (e.g. 1.2 to add 20%) | alpha <0.1-1> | inset <px> | clip on/off | debug")
    end
end

-- The /hotp debug report (run protected from /hotp debug)
DebugReport = function()
    Scan()
    local n, t = 0, 0
    for _ in pairs(bars) do n = n + 1 end
    for _, list in pairs(hots) do for _ in pairs(list) do t = t + 1 end end
    Print(("%d health bars hooked, %d HoTs tracked"):format(n, t))
    for id, info in pairs(hotInfo) do
        if info then Print(("  %s: %s over %ss"):format(tostring(SpellName(id) or id), tostring(info.total), tostring(info.duration))) end
    end
    -- Details for the player's own bar(s), to see why a segment would not show
    local function s(v) if v == nil then return "nil" end if issecretvalue and issecretvalue(v) then return "secret" end return tostring(v) end
    local found = false
    for hb, unitFunc in pairs(bars) do
        if unitFunc() == "player" then
            found = true
            local o = overlays[hb]
            local fl, fsub = o.fill:GetDrawLayer()
            Print(("  player bar (%s) %s: level %s, fill layer %s %s, size %sx%s"):format(
                o.decorated and "unit frame" or "party/raid frame",
                s(hb.GetDebugName and hb:GetDebugName() or hb:GetName()), s(hb:GetFrameLevel()), s(fl), s(fsub), s(hb:GetWidth()), s(hb:GetHeight())))
            Print(("    segment: shown %s, width %s, helper shown %s width %s, remaining %s"):format(
                s(o.seg:IsShown()), s(o.seg:GetWidth()), s(o.geo:IsShown()), s(o.geo:GetWidth()), s(Remaining(UnitKey("player")))))
        end
    end
    if not found then Print("  no health bar found for your player frame") end
end
