-- NoHorseTeleport.lua
-- Compass/Map horse marker (only when UNMOUNTED) + scripted-ride reunite
-- Lua 5.1 compatible (no 'goto', 5.1-safe)

NoHorseTeleport                   = NoHorseTeleport or {
    Client = {},
    Server = {},
    Properties = { bSaved_by_game = 0, Saved_by_game = 0, bSerialize = 0 },
    States = {},
    needscompassreadded = true,
    horsewuid = nil,
    horseid = nil,
    playerhorse = nil
}

-- ========= Config =========
NoHorseTeleport.Config            = NoHorseTeleport.Config or {
    -- UI
    showHorseOnCompass           = true,  -- compass marker (unmounted only)
    showHorseOnMap               = true,  -- map POI (unmounted only)
    debug                        = false, -- set false to quiet logs
    debugVerbose                 = false,

    -- Scripted-ride reunite (hardcore-friendly)
    smartReuniteScriptedOnly     = true, -- only after ApseMap session with big displacement & no FT intent

    -- Thresholds / timing
    TELEPORT_THRESHOLD_METERS    = 250,
    HORSE_TOO_FAR_METERS         = 120,
    STATIONARY_CHECK_DELAY_MS    = 250,
    TELEPORT_COOLDOWN_MS         = 6000,
    POST_CLOSE_DELAY_MS          = 600,
    POST_CLOSE_WATCH_MS          = 10000,
    POST_CLOSE_WATCH_INTERVAL_MS = 500,

    -- Fallback "hard teleport" detector (outside ApseMap)
    detectHardTeleports          = true,  -- set false if user has manual FT mods
    HARD_TP_THRESHOLD_METERS     = 300,   -- jump size to flag as teleport
    HARD_TP_SAMPLING_MS          = 800,   -- how often to sample in OnUpdate
    HARD_TP_STATIONARY_MS        = 250,   -- confirm Henry stops moving
    HARD_TP_COOLDOWN_MS          = 12000, -- separate from reunite cooldown
}

-- ========= Session state =========
NoHorseTeleport._mapSession       = {
    isOpen = false,
    instanceId = nil,
    openedAtMs = 0,
    sawUserFTIntent = false
}

NoHorseTeleport._preMapPos        = nil
NoHorseTeleport._lastTeleportTick = 0
NoHorseTeleport._htLastPos        = nil
NoHorseTeleport._htLastTickMs     = 0
NoHorseTeleport._htCooldownTick   = 0
NoHorseTeleport._lastMapCloseAt   = 0 -- set when map close watch starts

-- ========= Helpers =========
local function _dbg(tag, msg)
    if NoHorseTeleport.Config.debug and System and System.LogAlways then
        System.LogAlways("[NoHorseTeleport][" .. tostring(tag) .. "] " .. tostring(msg))
    end
end

local function _nowMs()
    local t = System.GetCurrTime and System.GetCurrTime() or 0
    return math.floor((t or 0) * 1000)
end

local function _getPos(entity)
    if entity and entity.GetWorldPos then return entity:GetWorldPos() end
    if entity and entity.GetPos then return entity:GetPos() end
    return nil
end

local function _posStr(p)
    if not p then return "nil" end
    return string.format("{x=%.2f,y=%.2f,z=%.2f}", p.x or 0, p.y or 0, p.z or 0)
end

local function _dist2D(a, b)
    if not (a and b) then return 0 end
    local dx, dy = (a.x - b.x), (a.y - b.y)
    return math.sqrt(dx * dx + dy * dy)
end

local function _playerReady() return player ~= nil and player.human ~= nil end
local function _isMounted() return _playerReady() and player.human.IsMounted and player.human:IsMounted() end

-- Lua 5.1-safe atan2
local atan2 = math.atan2 or function(y, x)
    if x > 0 then
        return math.atan(y / x)
    elseif x < 0 then
        return (y >= 0) and (math.atan(y / x) + math.pi) or (math.atan(y / x) - math.pi)
    else
        if y > 0 then
            return math.pi / 2
        elseif y < 0 then
            return -math.pi / 2
        else
            return 0
        end
    end
end

-- ========= Horse refs =========
function NoHorseTeleport:RefreshHorseRefs()
    if not _playerReady() then
        self.horsewuid, self.horseid, self.playerhorse = nil, nil, nil
        return
    end
    if player.player and player.player.GetPlayerHorse then
        self.horsewuid = player.player:GetPlayerHorse()
    else
        self.horsewuid = nil
    end
    if self.horsewuid then
        self.horseid     = XGenAIModule.GetEntityIdByWUID(self.horsewuid)
        self.playerhorse = XGenAIModule.GetEntityByWUID(self.horsewuid)
    else
        self.horseid, self.playerhorse = nil, nil
    end
end

-- ========= Compass math (original parity) =========
local function _bearingDegAndDistance()
    if not (NoHorseTeleport.horseid and NoHorseTeleport.playerhorse) then return nil, nil end
    local pp = player:GetPos()
    local hp = NoHorseTeleport.playerhorse:GetPos()
    if not (pp and hp) then return nil, nil end
    local dir = { x = pp.x - hp.x, y = pp.y - hp.y, z = 0 }
    local ang = atan2(dir.x, dir.y) + (math.pi / 4.0)
    local deg = (math.deg(ang) % 360 + 360) % 360
    local dist = player:GetDistance(NoHorseTeleport.horseid)
    return deg, dist
end

-- ========= Teleport horse safely (behind Henry) =========
function NoHorseTeleport:_teleportHorse(reason)
    local now = _nowMs()
    if (now - (self._lastTeleportTick or 0)) < (self.Config.TELEPORT_COOLDOWN_MS or 6000) then
        _dbg("Reunite", "skip (cooldown)")
        return false
    end
    if not _playerReady() then return false end
    self:RefreshHorseRefs(); if not self.playerhorse or _isMounted() then return false end

    local pp = _getPos(player)
    local hp = _getPos(self.playerhorse)
    if pp and hp then
        local dd = _dist2D(pp, hp)
        if dd < (self.Config.HORSE_TOO_FAR_METERS or 120) then
            _dbg("Reunite", string.format("skip (horse only %.1fm away)", dd))
            return false
        end
    end

    local a           = player:GetAngles() or { x = 0, y = 0, z = 0 }
    local yaw         = a.z or 0
    local back, right = 2.5, 1.0
    local ox          = -back * math.cos(yaw) + right * math.sin(yaw)
    local oy          = -back * math.sin(yaw) - right * math.cos(yaw)
    local target      = { x = pp.x + ox, y = pp.y + oy, z = pp.z }

    self.playerhorse:SetWorldPos(target)
    if self.playerhorse.SetAngles then self.playerhorse:SetAngles(a) end

    self._lastTeleportTick = now
    _dbg("Reunite",
        string.format("Horse teleported (%s) -> x=%.2f y=%.2f", tostring(reason or "scripted-ride"), target.x, target.y))
    return true
end

-- ========= Decision helper =========
local function _shouldReunite(cfg, session, prePos, nowPos)
    local d = _dist2D(nowPos, prePos)
    if d < (cfg.TELEPORT_THRESHOLD_METERS or 250) then return false, "small displacement" end
    if session.sawUserFTIntent then return false, "user FT intent" end
    if _isMounted() then return false, "mounted" end
    return true, "ok"
end

-- Detect sudden displacement outside ApseMap (quests/cutscenes without map)
function NoHorseTeleport:CheckHardTeleport()
    local cfg = self.Config
    if not cfg.detectHardTeleports then return end
    if not _playerReady() then return end
    if self._mapSession and self._mapSession.isOpen then return end -- handled by map path

    -- sampling throttle
    local now = _nowMs()
    if (now - (self._htLastTickMs or 0)) < (cfg.HARD_TP_SAMPLING_MS or 800) then return end
    self._htLastTickMs = now

    local pos = _getPos(player)
    if not pos then return end

    -- first sample
    if not self._htLastPos then
        self._htLastPos = pos
        return
    end

    local d = _dist2D(pos, self._htLastPos)
    self._htLastPos = pos

    -- cooldown
    if (now - (self._htCooldownTick or 0)) < (cfg.HARD_TP_COOLDOWN_MS or 12000) then return end

    -- guard: if a manual FT mod was used right after map interaction, skip for a few seconds
    -- (we can't see intent here, so just grace-period after any map close)
    if (now - (self._lastMapCloseAt or 0)) < 4000 then return end

    if d >= (cfg.HARD_TP_THRESHOLD_METERS or 300) then
        if self.Config.debug then
            _dbg("Map", string.format("HARD-TP candidate: d=%.1fm (no map session)", d))
        end
        -- stationary confirmation
        Script.SetTimer(cfg.HARD_TP_STATIONARY_MS or 250, function()
            if not _playerReady() then return end
            local p1 = _getPos(player)
            Script.SetTimer(120, function()
                if not _playerReady() then return end
                local p2 = _getPos(player)
                if _dist2D(p1, p2) < 2.0 then
                    -- Reuse your existing reunite gates (mounted/horse-distance/cooldown inside)
                    if NoHorseTeleport:_teleportHorse("hard-teleport") then
                        NoHorseTeleport._htCooldownTick = _nowMs()
                        if NoHorseTeleport.Config.debug then
                            _dbg("Reunite", "Hard teleport detected -> horse reunited")
                        end
                    end
                elseif NoHorseTeleport.Config.debug then
                    _dbg("Reunite", "Hard teleport skipped (player moving)")
                end
            end)
        end)
    end
end

-- ========= Lifecycle =========
function NoHorseTeleport:OnReset() self:Activate(1) end

function NoHorseTeleport.Server:OnInit()
    if not self.bInitialized then
        self:OnReset(); self.bInitialized = 1
    end
end

function NoHorseTeleport.Client:OnInit()
    -- ApseMap lifecycle + FT intent
    UIAction.RegisterElementListener(NoHorseTeleport, "ApseMap", -1, "OnShow", "OnMapShow")
    UIAction.RegisterElementListener(NoHorseTeleport, "ApseMap", -1, "OnHide", "OnMapHide")
    UIAction.RegisterElementListener(NoHorseTeleport, "ApseMap", -1, "OnUnload", "OnMapUnload")
    UIAction.RegisterElementListener(NoHorseTeleport, "ApseMap", -1, "OnInstanceDestroyed", "OnMapDestroyed")
    UIAction.RegisterElementListener(NoHorseTeleport, "ApseMap", -1, "OnHighlightFastTravelPoint",
        "OnHighlightFastTravelPoint")
    UIAction.RegisterElementListener(NoHorseTeleport, "ApseMap", -1, "OnDoubleClicked", "OnDoubleClicked")

    NoHorseTeleport.needscompassreadded = true
    self:RefreshHorseRefs()
    if not self.bInitialized then
        self:OnReset(); self.bInitialized = 1
    end
end

function NoHorseTeleport.Client:OnUpdate()
    NoHorseTeleport:UpdateHorseCompass()
    NoHorseTeleport:CheckHardTeleport()
end

-- ========= Map lifecycle handlers =========
function NoHorseTeleport:OnMapShow(elementName, instanceId, eventName, argTable)
    if NoHorseTeleport.Config.showHorseOnMap then
        Script.SetTimer(50, function()
            NoHorseTeleport:AddHorseMapMarker(elementName, instanceId, eventName, argTable)
        end)
    end

    self._mapSession.isOpen = true
    self._mapSession.instanceId = instanceId
    self._mapSession.openedAtMs = _nowMs()
    self._mapSession.sawUserFTIntent = false

    self._preMapPos = _getPos(player)
    _dbg("Map", "OPEN prePos=" .. _posStr(self._preMapPos))
end

local function _startPostCloseWatch()
    local cfg = NoHorseTeleport.Config
    local prePos = NoHorseTeleport._preMapPos
    local started = _nowMs()
    local decided = false

    NoHorseTeleport._lastMapCloseAt = _nowMs()

    -- 🔹 single summary line on map close (immediate snapshot)
    if NoHorseTeleport.Config.debug then
        local nowPos       = _getPos(player)
        local displacement = _dist2D(nowPos, prePos)
        _dbg("Map", string.format(
            "CLOSE displacement=%.1fm (intent=%s)",
            displacement,
            tostring(NoHorseTeleport._mapSession.sawUserFTIntent)
        ))
    end

    local function decide(tag)
        if decided then return true end -- already handled
        local nowPos = _getPos(player)
        local ok, why = _shouldReunite(cfg, NoHorseTeleport._mapSession, prePos, nowPos)
        if NoHorseTeleport.Config.debugVerbose then
            _dbg("Map", string.format("%s displacement=%.1fm (intent=%s) pre=%s now=%s decision=%s (%s)",
                tag, _dist2D(nowPos, prePos), tostring(NoHorseTeleport._mapSession.sawUserFTIntent),
                _posStr(prePos), _posStr(nowPos), tostring(ok), tostring(why)))
        end

        if ok and cfg.smartReuniteScriptedOnly then
            decided = true
            Script.SetTimer(cfg.STATIONARY_CHECK_DELAY_MS or 250, function()
                if not _playerReady() then return end
                local p1 = _getPos(player)
                Script.SetTimer(120, function()
                    if not _playerReady() then return end
                    local p2 = _getPos(player)
                    if _dist2D(p1, p2) < 2.0 then
                        NoHorseTeleport:_teleportHorse("scripted-ride")
                    else
                        _dbg("Reunite", "skip (player moving)")
                    end
                end)
            end)
            return true
        end
        return false
    end

    -- immediate check
    if not decide("CLOSE (t0)") then
        -- watch window
        local function poll()
            if decided then return end
            if (_nowMs() - started) > (cfg.POST_CLOSE_WATCH_MS or 10000) then
                -- timeout -> reset session
                NoHorseTeleport._mapSession.isOpen = false
                NoHorseTeleport._mapSession.sawUserFTIntent = false
                NoHorseTeleport._preMapPos = nil
                return
            end
            if not decide("CLOSE (watch)") then
                Script.SetTimer(cfg.POST_CLOSE_WATCH_INTERVAL_MS or 500, poll)
            end
        end
        Script.SetTimer(NoHorseTeleport.Config.POST_CLOSE_DELAY_MS or 600, poll)
        return
    end

    -- decided immediately -> reset session now
    NoHorseTeleport._mapSession.isOpen = false
    NoHorseTeleport._mapSession.sawUserFTIntent = false
    NoHorseTeleport._preMapPos = nil
end

function NoHorseTeleport:OnMapHide(elementName, instanceId) _startPostCloseWatch() end

function NoHorseTeleport:OnMapUnload(elementName, instanceId) _startPostCloseWatch() end

function NoHorseTeleport:OnMapDestroyed(elementName, instanceId) _startPostCloseWatch() end

-- FT UI intent (filter out manual FT if enabled by other mods)
function NoHorseTeleport:OnHighlightFastTravelPoint(_, _, _, args)
    self._mapSession.sawUserFTIntent = true
end

function NoHorseTeleport:OnDoubleClicked(_, _, _, args)
    self._mapSession.sawUserFTIntent = true
end

-- ========= Map POI (delayed injection) =========
function NoHorseTeleport:AddHorseMapMarker(elementName, instanceId, eventName, argTable)
    if not NoHorseTeleport.Config.showHorseOnMap then return end
    if not _playerReady() then return end
    self:RefreshHorseRefs()
    if _isMounted() then return end
    if not self.playerhorse then return end

    local hpos = _getPos(self.playerhorse)
    local values = { 1, "PLAYERHORSE", "soul_ui_name_horse", "horseTrader", 1, false, 0, hpos.x, hpos.y }
    UIAction.SetArray(elementName, instanceId, "PoiMarkers", values)
    UIAction.CallFunction(elementName, instanceId, "AddPoiMarkers")
    _dbg("Map", string.format("POI added at x=%.1f y=%.1f", hpos.x, hpos.y))
end

-- ========= Compass marker =========
function NoHorseTeleport:AddHorseCompassMarker()
    if not NoHorseTeleport.Config.showHorseOnCompass then
        UIAction.CallFunction("hud", -1, "RemoveCompassMarker", "PLAYERHORSE")
        NoHorseTeleport.needscompassreadded = true
        return
    end
    if not _playerReady() then return end
    self:RefreshHorseRefs()
    if _isMounted() then
        UIAction.CallFunction("hud", -1, "RemoveCompassMarker", "PLAYERHORSE")
        NoHorseTeleport.needscompassreadded = true
        return
    end
    if not self.playerhorse then return end

    local deg, dist = _bearingDegAndDistance()
    if not deg then return end
    UIAction.CallFunction("hud", -1, "AddCompassMarker",
        "PLAYERHORSE", "horseTrader", 1, -1, -1, dist, deg, false, false, 3, 50, 300)
    NoHorseTeleport.needscompassreadded = false
end

function NoHorseTeleport:UpdateHorseCompass()
    if not NoHorseTeleport.Config.showHorseOnCompass then
        UIAction.CallFunction("hud", -1, "RemoveCompassMarker", "PLAYERHORSE")
        NoHorseTeleport.needscompassreadded = true
        return
    end
    if not _playerReady() then return end

    if not self.playerhorse then
        self:RefreshHorseRefs()
        if not self.playerhorse then return end
    end

    if _isMounted() then
        if not NoHorseTeleport.needscompassreadded then
            UIAction.CallFunction("hud", -1, "RemoveCompassMarker", "PLAYERHORSE")
            NoHorseTeleport.needscompassreadded = true
        end
        return
    end

    local deg, dist = _bearingDegAndDistance()
    if not deg then return end

    if NoHorseTeleport.needscompassreadded then
        UIAction.CallFunction("hud", -1, "AddCompassMarker",
            "PLAYERHORSE", "horseTrader", 1, -1, -1, dist, deg, false, false, 3, 50, 300)
        NoHorseTeleport.needscompassreadded = false
    end

    UIAction.SetArray("hud", -1, "CompassMarkers", { 1, "PLAYERHORSE", -1, dist, deg, 0, false, false })
    UIAction.CallFunction("hud", -1, "UpdateCompass", 0)
end

-- ========= Mount hook =========
local _Horse_OnMount_Original = Horse and Horse.OnMount or nil
function Horse:OnMount(user, slot)
    if _Horse_OnMount_Original then
        _Horse_OnMount_Original(self, user, slot)
    else
        if user and user.human and user.human.Mount then user.human:Mount(self.id) end
    end

    if user == player then
        NoHorseTeleport:RefreshHorseRefs()
        if NoHorseTeleport.Config.showHorseOnCompass then
            UIAction.CallFunction("hud", -1, "RemoveCompassMarker", "PLAYERHORSE")
        end
        NoHorseTeleport.needscompassreadded = true
    end
end
