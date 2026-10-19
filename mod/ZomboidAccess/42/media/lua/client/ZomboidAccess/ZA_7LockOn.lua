-- Zomboid Access: lock-on (optional, off at first; the scanner's "You" list, "Lock-on", then Square).
--   While it's on, your character turns to face the zombie it's locked on to: the nearest one within 3.5 metres
--   (one that's chasing you first), kept until it dies or gets more than 5 metres away. "Locked on: zombie, 2 metres
--   right" when it picks one, "Lock-on free" when there's none left.
--   It never turns you while you walk (left stick), and pushing the right stick to aim somewhere else wins over it.
--   While it faces a zombie (standing still) it also keeps you aiming at it, so pulling R2 all the way swings at
--   once, on any controller: the game swings from R2 only while the right stick aims (a light R2 pull is only
--   precision aim), and lock-on leaves the right stick free. L2 shoves.
-- The choice is kept in the save (ModData "ZomboidAccessSettings").

ZA.LK = ZA.LK or {}
local LK = ZA.LK
local S = ZA.S

LK.reach = 3.5
LK.keep = 5

local function settings()
    local ok, t = pcall(function() return ModData.getOrCreate("ZomboidAccessSettings") end)
    return ok and t or {}
end
function LK.isOn() return settings().lockOn == true end

local function dist(p, z) return math.sqrt((z:getX() - p:getX()) ^ 2 + (z:getY() - p:getY()) ^ 2) end

-- A zombie you could hit: not one pretending to be dead (the game never takes it as a target), and not one behind
-- a wall, a closed door or a blocked window (the game won't swing through those: LosUtil, as CombatManager does).
local function inSight(p, z)
    local ok, res = pcall(function()
        return LosUtil.lineClear(getCell(), math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ()),
            math.floor(z:getX()), math.floor(z:getY()), math.floor(z:getZ()), false)
    end)
    if not ok or res == nil then return true end
    local r = tostring(res)
    return r ~= "Blocked" and r ~= "ClearThroughClosedDoor"
end

local function usable(p, z)
    if not (z and not z:isDead() and z:getCurrentSquare() ~= nil and math.floor(z:getZ()) == math.floor(p:getZ())) then
        return false
    end
    local fake = false
    pcall(function() fake = z:isFakeDead() end)
    return not fake and inSight(p, z)
end

-- ---------- a zombie on the ground ----------
-- The game hits a zombie on the ground only within the weapon's reach (its range times the character's range bonus,
-- as CombatManager.calcValidTargets), and the stomp (L2) aims at the ground only from under 0.6 metres
-- (CombatManager.calculateAttackVars). These are measured to the zombie's nearest body part; we only know its
-- middle, so a little is allowed for its body.
LK.proneBody = 0.5      -- metres from its middle to its nearest part, about
LK.stompAt = 0.6 + 0.5  -- stomp distance, from its middle

local function prone(z)
    local down = false
    pcall(function() down = z:isProne() or z:isOnFloor() end)
    return down
end

-- The reach of the weapon in your hands, nil with bare hands or a gun (then only the stomp reaches the ground).
local function weaponReach(p)
    local reach = nil
    pcall(function()
        local w = p:getPrimaryHandItem()
        if w and instanceof(w, "HandWeapon") and not w:isRanged() then reach = w:getMaxRange() * w:getRangeMod(p) end
    end)
    return reach
end

-- Says where a zombie on the ground is and what you can do: "Down, get closer: 2 metres right", then "On the
-- ground, in reach: R2 hits", then "Right on it: L2 stomps". Each said when it changes (the distance again when it
-- changes by a metre). Returns true when a weapon swing would reach it.
local function proneGuide(p, t, fresh)
    -- ZA_7HeadStomp is taking you to its head, or has: it does the talking, and from its head you can strike
    if ZA.HS and ZA.HS.handles and ZA.HS.handles(t) then
        LK.proneState = nil
        return ZA.HS.phase == "placed"
    end
    -- about to be taken over (it waits for the body to lie flat first): work out the reach, but say nothing
    local quiet = ZA.HS and ZA.HS.wants and ZA.HS.wants(p, t)
    local d = dist(p, t)
    local reach = weaponReach(p)
    local state, canSwing
    if d <= LK.stompAt then state, canSwing = "stomp", true   -- with bare hands R2 shoves, which stomps from there
    elseif reach and d <= reach + LK.proneBody then state, canSwing = "reach", true
    else state, canSwing = "far", false end
    local m = math.floor(d + 0.5)
    local now = getTimestampMs()
    if quiet then return canSwing end
    if state ~= LK.proneState or (state == "far" and m ~= LK.proneMetres and now - (LK.proneSaidAt or 0) > 1500) then
        LK.proneState, LK.proneMetres, LK.proneSaidAt = state, m, now
        -- just locked on: after "Locked on: ...", not over it
        local say = fresh and ZA.queue or ZA.urgent
        if state == "stomp" then say(ZA.tr("LockOn_ProneStomp"))
        elseif state == "reach" then say(ZA.tr("LockOn_ProneReach"))
        else say(ZA.tr("LockOn_ProneFar", (S.where(t:getX(), t:getY(), t:getZ())))) end
    end
    return canSwing
end

local function pick(p)
    local zl = getCell():getZombieList()
    local best, bd, bchase
    for i = 0, zl:size() - 1 do
        local z = zl:get(i)
        if usable(p, z) then
            local d = dist(p, z)
            if d <= LK.reach then
                local chase = z:getTarget() == p
                -- a zombie coming for you beats a nearer one that isn't
                if not best or (chase and not bchase) or (chase == bchase and d < bd) then
                    best, bd, bchase = z, d, chase
                end
            end
        end
    end
    return best
end

-- The zombie attacking you now (in its attack on you, IsoZombie:isZombieAttacking, as ZA_7Grabbed), the nearest
-- if several, within reach of lock-on; nil if none.
local function attacker(p)
    local zl = getCell():getZombieList()
    local best, bd
    for i = 0, zl:size() - 1 do
        local z = zl:get(i)
        if usable(p, z) then
            local d = dist(p, z)
            if d <= LK.reach then
                local ok, att = pcall(function() return z:isZombieAttacking(p) end)
                if ok and att and (not best or d < bd) then best, bd = z, d end
            end
        end
    end
    return best
end

-- The player steering the aim with the right stick, away from the target: leave it to them.
local tmp = Vector2.new(0, 0)
local function manualAim(p, z, bind)
    -- With a controller, only while you push the right stick: with lock-on aiming, the aim follows the facing and
    -- lags a moving zombie, which isn't you aiming elsewhere. With a mouse, the aim is always yours.
    if bind then
        local sx, sy = 0, 0
        pcall(function() sx, sy = getJoypadAimingAxisX(bind), getJoypadAimingAxisY(bind) end)
        if (sx or 0) ^ 2 + (sy or 0) ^ 2 < 0.09 then return false end
    end
    local ok, v = pcall(function() return p:getAimVector(tmp) end)
    if not ok or not v then return false end
    local ax, ay = v:getX(), v:getY()
    if ax * ax + ay * ay < 0.25 then return false end
    local dx, dy = z:getX() - p:getX(), z:getY() - p:getY()
    local dl = math.sqrt(dx * dx + dy * dy)
    if dl < 0.01 then return false end
    local al = math.sqrt(ax * ax + ay * ay)
    return (ax * dx + ay * dy) / (al * dl) < 0.77    -- more than about 40 degrees away
end

-- Aiming held for you while lock-on faces a zombie; let go the moment it doesn't (only an aim we took).
local function hold(p, on)
    -- Ask the game, not our memory: it drops the aim itself (a bite or a hit cancels aiming), and it must be
    -- taken again as soon as you can.
    local now = false
    pcall(function() now = p:isForceAim() end)
    if on == now then LK.aiming = on; return end
    if not on and not LK.aiming then return end
    local ok, err = pcall(function() p:setForceAim(on) end)
    if ok then LK.aiming = on
    elseif not LK.aimErrSaid then LK.aimErrSaid = true; ZA.log("[ZA] lock-on aim: " .. tostring(err)) end
end

-- The controller lock-on helps: nil when the player plays with keyboard and mouse (lock-on then only turns you,
-- as it always did, and the mouse aims).
local function pad(p)
    local ok, bind = pcall(function() return p:getJoypadBind() end)
    if not ok or bind == nil or bind < 0 then return nil end
    return bind
end

-- R2 just pressed (not held).
local rtWasDown = false
local function rtPressed(bind)
    local down = false
    pcall(function() down = isJoypadRTPressed(bind) end)
    local pressed = down and not rtWasDown
    rtWasDown = down
    return pressed
end

-- The game swings from R2 only while the right stick is pushed (its Aim binding; a held aim isn't enough, on any
-- controller: the triggers are analog, R2 only past 0.93). So with lock-on holding the aim, an R2 press starts the swing
-- itself (AttemptAttack, the game's own). It needs the weapon raised (isWeaponReady), which can take a moment
-- after the aim is taken: keep trying for 0.6 seconds. If the game started the swing (stick pushed too), leave it.
local function swing(p)
    if not LK.swingUntil then return end
    local started = false
    pcall(function() started = p:isAttackStarted() end)
    if started or getTimestampMs() > LK.swingUntil then LK.swingUntil = nil; return end
    local ready = false
    pcall(function() ready = p:isWeaponReady() end)
    if not ready then return end
    pcall(function() p:AttemptAttack() end)
    LK.swingUntil = nil
end

function LK.tick()
    local p = getPlayer()
    if not LK.isOn() then
        LK.target = nil
        if p then hold(p, false) end
        return
    end
    if not p or p:isDead() or p:getVehicle() then
        LK.target = nil
        if p and not p:isDead() then hold(p, false) end
        return
    end
    local t = LK.target
    if t and (not usable(p, t) or dist(p, t) > LK.keep) then
        t = nil
    end
    -- a zombie attacking you (grabbing, biting) comes first, even over the one already locked on: otherwise you
    -- would keep turning to the first and swinging at the wrong one (Marc, 2026-10-18)
    local att = attacker(p)
    if att then t = att end
    if not t then t = pick(p) end
    local fresh = t ~= LK.target
    if fresh then
        if t then
            -- switched to a zombie grabbing you: after "Grabbed: L2 shoves it off" (ZA_7Grabbed), not over it
            local say = (t == att) and ZA.queue or ZA.urgent
            say(ZA.tr("LockOn_Locked", S.threatText(t)))
        elseif LK.target then
            ZA.say(ZA.tr("LockOn_Free"))
        end
        LK.target = t
    end
    if not t then hold(p, false); LK.proneState = nil; return end
    local bind = pad(p)
    local pressed = bind and rtPressed(bind)
    -- on the ground: guide you to it (also while you walk up to it), and don't swing at the air from too far
    local down = prone(t)
    local canSwing = true
    if down then canSwing = proneGuide(p, t, fresh) else LK.proneState = nil end
    local moving = false
    pcall(function() moving = p:isPlayerMoving() end)
    if moving or p:isPerformingAnAction() or manualAim(p, t, bind) then hold(p, false); return end
    if pressed and not canSwing then
        pressed = false
        local now = getTimestampMs()
        if now - (LK.tooFarAt or 0) > 1500 then LK.tooFarAt = now; ZA.urgent(ZA.tr("LockOn_TooFar")) end
    end
    -- Bitten or hit: the game drops your aim and won't let you swing until it's over. A shove breaks a grab.
    local hit = false
    pcall(function() local h = p:getHitReaction(); hit = h ~= nil and h ~= "" end)
    -- (the grab itself is announced, with its sound, by ZA_7Grabbed.lua, lock-on or not)
    if hit then return end
    p:faceThisObject(t)
    if not bind then hold(p, false); return end
    -- Out of reach on the ground, or being walked to its head: no aim held. With the aim held the game swings by
    -- itself on R2, and those swings at the air cut the walk to the head (in game 2026-10-19: "Too far", then a
    -- miss anyway, over and over, and the walk cut each time).
    if not canSwing or (down and ZA.HS and ZA.HS.handles and ZA.HS.handles(t) and ZA.HS.phase ~= "placed") then
        hold(p, false)
        LK.swingUntil = nil
        return
    end
    hold(p, true)
    if pressed then LK.swingUntil = getTimestampMs() + 600 end
    swing(p)
end
if not LK.ticking then
    LK.ticking = true
    ZA.onTick(function()
        local ok, err = pcall(LK.tick)
        if not ok and not LK.errSaid then LK.errSaid = true; print("[ZA] lock-on error: " .. tostring(err)) end
    end)
end

-- On and off from the "You" list, next to Zombie sounds.
table.insert(S.builders, function(lists)
    local p = getPlayer()
    table.insert(lists.you, {
        cat = "you", key = "you|lockon", noWhere = true, order = 903, baseName = ZA.tr("LockOn_Name"),
        name = function()
            local on = LK.isOn()
            return ZA.tr(on and "LockOn_HelpOn" or "LockOn_HelpOff")
        end,
        x = p:getX(), y = p:getY(), z = p:getZ(),
        action = function()
            local s = settings()
            s.lockOn = not (s.lockOn == true)
            LK.target = nil
            ZA.say(ZA.tr(s.lockOn and "LockOn_SwitchedOn" or "LockOn_SwitchedOff"))
        end,
    })
end)
