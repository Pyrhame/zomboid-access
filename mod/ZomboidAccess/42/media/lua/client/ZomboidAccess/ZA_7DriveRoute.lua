-- Zomboid Access: driving to a place (her ask 2026-10-02: "it auto drives if you want it to, and uses the pings if
-- you don't"). In the driver's seat, pick anything in the scanner (Places, Houses, a town, a marker, a door...):
--   Square / End: route guidance. The steering tone follows the route instead of just the road; "Turn left in 40
--     metres" before turns; "Arrived" at the end. You drive.
--   Hold Square / Delete: autodrive along the same route. Cruise control drives the speed (slow before a bend, by
--     how sharp it is; slower near zombies); the mod steers by turning the car's body along the route (see pushYaw;
--     the older turning push, BaseVehicle:addImpulse, if that fails). Brake (Circle) or reverse and the game turns
--     cruise control off: autodrive stops and the car is yours. Something in the road ahead stops it too, and so does
--     being stuck (barely moving for 3 seconds).
--   Square / End again: stop the route.
-- The route: roads first (A* on every other square, road cheap, grass 25 times dearer, buildings, trees, solid things
-- and fences shut),
-- planned within what the game has loaded round you (about 70 squares; RT.reach caps it at 140) and planned again
-- as you go, so far places are reached in stretches: the stretch ends at the loaded point nearest the place.
-- Steering push facts (2026-10-02, tests in a copy of her world): see RT.push.

ZA.RT = ZA.RT or {}
local RT = ZA.RT
local S, DR = ZA.S, ZA.DR

RT.reach = 140        -- plan this far (squares) round you at once
RT.step = 2           -- plan on every other square
RT.arrive = 12

local function isRoad(x, y, z) return (DR.isRoad(x, y, z)) end

-- ---------- planning ----------

local function hpush(h, f, n)
    table.insert(h, { f, n }); local i = #h
    while i > 1 do
        local pi = math.floor(i / 2)
        if h[pi][1] <= h[i][1] then break end
        h[pi], h[i] = h[i], h[pi]; i = pi
    end
end
local function hpop(h)
    local top = h[1]; local last = table.remove(h)
    if #h > 0 then
        h[1] = last; local i = 1
        while true do
            local l, r, m = i * 2, i * 2 + 1, i
            if l <= #h and h[l][1] < h[m][1] then m = l end
            if r <= #h and h[r][1] < h[m][1] then m = r end
            if m == i then break end
            h[m], h[i] = h[i], h[m]; i = m
        end
    end
    return top
end

-- What it costs to drive over a square: road 1, open ground 25, nil where a car can't go. Off the road only within
-- 15 squares of where you start and of where you're going (to reach the road, and to reach the place): the rest of
-- the way is roads only, so routes never wander into fields with fences and ditches.
local costCache, roadCache, ends
local function nearEnds(x, y)
    for _, e in ipairs(ends) do
        if math.abs(x - e[1]) <= 15 and math.abs(y - e[2]) <= 15 then return true end
    end
    return false
end
local function roadAt(x, y, z)
    local k = x * 100000 + y
    local c = roadCache[k]
    if c == nil then c = isRoad(x, y, z) == true; roadCache[k] = c end
    return c
end
-- How close a road square is to the road's edge: 0 in the middle, up to 8 right by the verge. Added to its cost,
-- it keeps routes in the middle of the road, away from the kerbs, fences and walls along it (2026-10-20: the car
-- clipped them at turns, the route hugging the inside of every bend).
local function edgeCost(x, y, z)
    local e = 0
    for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
        if not roadAt(x + d[1], y + d[2], z) then e = e + 2
        elseif not roadAt(x + 2 * d[1], y + 2 * d[2], z) then e = e + 1 end
    end
    return e
end
-- Something a car can't drive through on a square: a wall, a solid object, or another car (a wreck across the road;
-- 2026-10-20 the autodrive stopped at those instead of going round them).
local function blockedSq(sq)
    if sq:isSolid() or sq:isSolidTrans() then return true end
    local ok, ov = pcall(function() return sq:getVehicleContainer() end)
    return ok and ov ~= nil and ov ~= RT.ownV
end
RT.blockedSq = blockedSq

local function cost(x, y, z)
    local k = x * 100000 + y
    local c = costCache[k]
    if c ~= nil then return c or nil end
    local sq = getCell():getGridSquare(x, y, z)
    if not sq then costCache[k] = false; return nil end
    if roadAt(x, y, z) then
        -- (not "blocked and false or cost": false there falls through to the cost, so walls and solid things
        -- on the road were never avoided until 2026-10-20)
        if blockedSq(sq) then c = false else c = 1 + edgeCost(x, y, z) end
    elseif not nearEnds(x, y) or sq:getRoom() or blockedSq(sq) or not sq:getFloor() then
        c = false
    else
        c = 25
        local objs = sq:getObjects()
        for i = 0, objs:size() - 1 do
            local o = objs:get(i)
            if instanceof(o, "IsoTree") then c = false; break end
        end
    end
    costCache[k] = c
    return c or nil
end

-- A route of points from (sx, sy) toward (tx, ty). The area looked at is RT.reach squares round you (about what
-- the game has loaded); if the target is outside it, the route goes to the reachable point nearest the target
-- (NOT towards a point on the straight line: that can be a fenced field, a dead end). Returns the points and
-- whether they reach the target.
function RT.plan(sx, sy, tx, ty, z)
    costCache, roadCache = {}, {}
    RT.ownV = nil
    pcall(function() RT.ownV = getPlayer():getVehicle() end)   -- (its own squares are not "another car")
    ends = { { sx, sy }, { tx, ty } }
    local st = RT.step
    local dx, dy = tx - sx, ty - sy
    local d = math.sqrt(dx * dx + dy * dy)
    local gx, gy = tx, ty
    local x0, y0 = math.floor(sx - RT.reach), math.floor(sy - RT.reach)
    local x1, y1 = math.floor(sx + RT.reach), math.floor(sy + RT.reach)
    if d <= RT.reach - 10 then
        -- near: a smaller box round you and the target is enough
        x0 = math.floor(math.min(sx, tx) - 30); y0 = math.floor(math.min(sy, ty) - 30)
        x1 = math.floor(math.max(sx, tx) + 30); y1 = math.floor(math.max(sy, ty) + 30)
    end
    local nx = math.floor((x1 - x0) / st) + 1
    local function id(i, j) return j * nx + i end
    local function sqx(i) return x0 + i * st end
    local function sqy(j) return y0 + j * st end
    local si, sj = math.floor((sx - x0) / st + 0.5), math.floor((sy - y0) / st + 0.5)
    local gi, gj = math.floor((gx - x0) / st + 0.5), math.floor((gy - y0) / st + 0.5)
    local ni, nj = math.floor((x1 - x0) / st), math.floor((y1 - y0) / st)
    local g, came, closed, h = {}, {}, {}, {}
    local s = id(si, sj)
    g[s] = 0
    hpush(h, 0, s)
    local best, bestH = s, 1e9
    local dirs = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }
    local steps = 0
    local reached
    while #h > 0 do
        steps = steps + 1
        if steps > 30000 then break end
        local cur = hpop(h)[2]
        if not closed[cur] then
            closed[cur] = true
            local ci, cj = cur % nx, math.floor(cur / nx)
            local hx, hy = math.abs(ci - gi), math.abs(cj - gj)
            local hd = math.max(hx, hy)
            if hd <= 1 then reached = cur; break end
            -- the best place to head for when the target is out of reach: nearest it in a straight line, and better
            -- still at the edge of what the game has loaded (it goes on from there; a road end by a fence doesn't)
            local score = math.sqrt(hx * hx + hy * hy)
            local cx2, cy2 = sqx(ci), sqy(cj)
            if not getCell():getGridSquare(cx2 + 6, cy2, z) or not getCell():getGridSquare(cx2 - 6, cy2, z)
                or not getCell():getGridSquare(cx2, cy2 + 6, z) or not getCell():getGridSquare(cx2, cy2 - 6, z) then
                score = score - 10
            end
            if score < bestH then best, bestH = cur, score end
            for _, dd in ipairs(dirs) do
                local i2, j2 = ci + dd[1], cj + dd[2]
                if i2 >= 0 and i2 <= ni and j2 >= 0 and j2 <= nj then
                    local n2 = id(i2, j2)
                    if not closed[n2] then
                        local x2, y2 = sqx(i2), sqy(j2)
                        local c = cost(x2, y2, z)
                        -- the square between (we move two at a time) must be passable too, and no wall or fence
                        -- on the way across (isBlockedTo: also the fences along a road's edge)
                        local xm, ym = x2 - dd[1], y2 - dd[2]
                        local cm = c and cost(xm, ym, z)
                        if cm then
                            local cell = getCell()
                            local a = cell:getGridSquare(sqx(ci), sqy(cj), z)
                            local m = cell:getGridSquare(xm, ym, z)
                            local b = cell:getGridSquare(x2, y2, z)
                            if a:isBlockedTo(m) or m:isBlockedTo(b) then cm = nil end
                            -- a diagonal step: both squares beside it must be open to it too (no slipping between
                            -- the ends of two fences)
                            if cm and dd[1] ~= 0 and dd[2] ~= 0 then
                                local s1 = cell:getGridSquare(sqx(ci) + dd[1], sqy(cj), z)
                                local s2 = cell:getGridSquare(sqx(ci), sqy(cj) + dd[2], z)
                                if not s1 or not s2 or a:isBlockedTo(s1) or a:isBlockedTo(s2) or s1:isBlockedTo(m) or s2:isBlockedTo(m) then
                                    cm = nil
                                end
                            end
                        end
                        if c and cm then
                            local len = (dd[1] ~= 0 and dd[2] ~= 0) and 1.41 or 1
                            local ng = g[cur] + len * (c + cm) / 2
                            if not g[n2] or ng < g[n2] then
                                g[n2] = ng; came[n2] = cur
                                local ex, ey = math.abs(i2 - gi), math.abs(j2 - gj)
                                hpush(h, ng + math.max(ex, ey) + 0.41 * math.min(ex, ey), n2)
                            end
                        end
                    end
                end
            end
        end
    end
    local endNode = reached or best
    local pts = {}
    local n = endNode
    while n do
        table.insert(pts, 1, { x = sqx(n % nx) + 0.5, y = sqy(math.floor(n / nx)) + 0.5 })
        n = came[n]
    end
    return pts, reached ~= nil
end

-- ---------- following ----------

local fwd = Vector3f.new()
local function heading(v)
    v:getForwardVector(fwd)
    local hx, hy = fwd:x(), fwd:z()
    local l = math.sqrt(hx * hx + hy * hy)
    if l < 0.01 then return 0, 1 end
    return hx / l, hy / l
end

-- The angle (degrees, + = right) from the car's heading to the point
local function bearing(v, x, y)
    local hx, hy = heading(v)
    local dx, dy = x - v:getX(), y - v:getY()
    local rx, ry = -hy, hx
    local fwdc, right = dx * hx + dy * hy, dx * rx + dy * ry
    return math.deg(math.atan2(right, fwdc))
end
RT.bearing = bearing

-- Index of the route point nearest the car, searching forward from the last one.
local function nearestIndex(r, v)
    local best, bd = r.i or 1, 1e9
    for k = (r.i or 1), math.min(#r.pts, (r.i or 1) + 30) do
        local p = r.pts[k]
        local d = (p.x - v:getX()) ^ 2 + (p.y - v:getY()) ^ 2
        if d < bd then best, bd = k, d end
    end
    return best, math.sqrt(bd)
end

-- The point `dist` squares further along the route from index i.
local function along(r, i, dist)
    local acc = 0
    for k = i, #r.pts - 1 do
        local a, b = r.pts[k], r.pts[k + 1]
        local seg = math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
        if acc + seg >= dist then
            local t = (dist - acc) / math.max(seg, 0.01)
            return a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t
        end
        acc = acc + seg
    end
    local l = r.pts[#r.pts]
    return l.x, l.y
end

-- The next real turn on the route ahead: how far, and which way (only turns of 35 degrees or more count).
local function nextTurn(r, i)
    local acc = 0
    for k = i + 1, #r.pts - 4 do
        local a, b, c = r.pts[k - 1], r.pts[k], r.pts[k + 4]
        acc = acc + math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
        if acc > 80 then return nil end
        local h1 = math.atan2(b.y - a.y, b.x - a.x)
        local h2 = math.atan2(c.y - b.y, c.x - b.x)
        local turn = math.deg(h2 - h1)
        while turn > 180 do turn = turn - 360 end
        while turn < -180 do turn = turn + 360 end
        -- map y points south: a positive angle turns clockwise on the map, which is to the right
        if math.abs(turn) >= 35 then return acc, turn > 0 and "right" or "left", k end
    end
    return nil
end

function RT.replan(v)
    local r = RT.route
    local tx, ty = S.entryPos(r.entry)
    local pts, full = RT.plan(v:getX(), v:getY(), tx, ty, math.floor(v:getZ()))
    if #pts < 2 then return false end
    r.pts, r.full, r.i = pts, full, 1
    r.plannedAt = getTimestampMs()
    r.endX, r.endY = pts[#pts].x, pts[#pts].y
    return true
end

function RT.start(e, mode)
    local p = getPlayer()
    local v = p:getVehicle()
    if not v or not v:isDriver(p) then return false end
    if RT.route then RT.stop(true) end
    RT.route = { entry = e, mode = mode, saidTurn = {}, lastBand = nil }
    -- a failed check of the body turning is tried again on the next drive
    if RT.cal.failed then RT.cal, RT.steerMode = {}, "yaw" end
    local ok, res = pcall(RT.replan, v)
    if not ok or not res then
        RT.route = nil
        if not ok then print("[ZA] route error: " .. tostring(res)) end
        ZA.say(ZA.tr("Route_NoRoad", S.entryName(e)))
        return true
    end
    local x, y, z = S.entryPos(e)
    local where = S.where(x, y, z)
    if mode == "auto" then
        if not v:isEngineRunning() then
            RT.route = nil
            ZA.say(ZA.tr("Route_StartEngine"))
            return true
        end
        RT.route.speed = 0
        ZA.say(ZA.tr("Route_AutoStart", S.entryName(e), where))
    else
        ZA.say(ZA.tr("Route_Start", S.entryName(e), where))
    end
    ZA.log("[ZA] route " .. mode .. " to " .. e.key .. " (" .. #RT.route.pts .. " points)")
    return true
end

function RT.stop(quiet, why)
    local r = RT.route
    RT.route = nil
    if r and r.mode == "auto" then
        local v = getPlayer() and getPlayer():getVehicle()
        if v then v:setRegulator(false) end
    end
    if not quiet then ZA.say(why or ZA.tr("Route_Stopped")) end
end

local function setSpeed(v, kmh)
    kmh = math.floor(kmh / 5 + 0.5) * 5
    if kmh <= 0 then v:setRegulator(false); return end
    v:setRegulatorSpeed(kmh)
    v:setRegulator(true)
end

-- slow down hard: a push against the way the car is going (one impulse per update, so not while steering)
local vel = Vector3f.new()
local function brake(v)
    -- the game's own brake, held for a second (BaseVehicle:setForceBrake: the same as pressing brake, what the
    -- game does when a car hits a zombie); the push against the motion only if that isn't there
    if pcall(function() v:setForceBrake() end) then return end
    v:getLinearVelocity(vel)
    local vx, vz = vel:x(), vel:z()
    local l = math.sqrt(vx * vx + vz * vz)
    if l < 0.2 then return end
    v:addImpulse(Vector3f.new(-vx / l * 900, 0, -vz / l * 900), Vector3f.new(0, 0, 0))
end

-- How sharp the route turns in the next `within` squares: the largest change of direction, in degrees, measured over
-- 6 squares at a time (so a bend made of many small steps counts whole), and how far away it starts.
local function sharpAhead(r, i, within)
    local acc, worst, at = 0, 0, nil
    for k = i + 1, #r.pts - 3 do
        local a, b = r.pts[k - 1], r.pts[k]
        acc = acc + math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
        if acc > within then break end
        local c = r.pts[k + 3]
        local h1 = math.atan2(b.y - a.y, b.x - a.x)
        local h2 = math.atan2(c.y - b.y, c.x - b.x)
        local d = math.abs(math.deg(h2 - h1))
        while d > 180 do d = math.abs(d - 360) end
        if d > worst then worst, at = d, acc end
    end
    return worst, at
end

function RT.tick()
    local r = RT.route
    if not r then return end
    local p = getPlayer()
    local v = p and p:getVehicle()
    if not v or not v:isDriver(p) then RT.stop(true); return end
    local t = getTimestampMs()
    local tx, ty = S.entryPos(r.entry)
    local dEnd = math.sqrt((tx - v:getX()) ^ 2 + (ty - v:getY()) ^ 2)
    local speed = v:getCurrentSpeedKmHour()

    -- arrived
    if dEnd <= RT.arrive then
        if r.mode == "auto" then
            r.stopping = true
            v:setRegulator(false)
            if speed > 2 then brake(v); return end
        end
        RT.route = nil
        ZA.say(ZA.tr("Route_Arrived", S.entryName(r.entry)))
        return
    end

    -- plan again: near the end of what's planned, every 8 seconds, or off the route
    local i, off = nearestIndex(r, v)
    r.i = i
    local dPlanEnd = math.sqrt((r.endX - v:getX()) ^ 2 + (r.endY - v:getY()) ^ 2)
    if off > 8 or (not r.full and dPlanEnd < 40) or t - r.plannedAt > 8000 then
        if not RT.replan(v) then
            RT.stop(false, ZA.tr("Route_Lost"))
            return
        end
        i = 1
    end

    -- where to aim: further ahead the faster you go
    local look = math.max(6, math.min(22, 5 + math.abs(speed) / 3.6 * 0.8))
    local ax, ay = along(r, i, look)
    r.steer = bearing(v, ax, ay)
    -- the route is behind you: say so, once each time
    if math.abs(r.steer) > 110 then
        if not r.saidBehind then ZA.say(ZA.tr("Route_Behind")); r.saidBehind = true end
    elseif math.abs(r.steer) < 60 then
        r.saidBehind = nil
    end

    -- turns ahead, said once each: "Turn left in 40 metres", and "Turn left now"
    local dist, way, k = nextTurn(r, i)
    if dist then
        local tp = r.pts[k]
        local key, said
        for kk, sv in pairs(r.saidTurn) do
            if (kk.x - tp.x) ^ 2 + (kk.y - tp.y) ^ 2 < 625 then key, said = kk, sv; break end
        end
        key = key or { x = tp.x, y = tp.y }
        if not said and dist > 15 then
            ZA.say(ZA.tr(way == "right" and "Route_TurnRightIn" or "Route_TurnLeftIn", math.floor(dist / 10 + 0.5) * 10))
            r.saidTurn[key] = 1
        elseif (said or 0) < 2 and dist <= 15 then
            ZA.say(ZA.tr(way == "right" and "Route_TurnRightNow" or "Route_TurnLeftNow"))
            r.saidTurn[key] = 2
        end
    end
    -- how far to go, every 200 metres
    local band = math.floor(dEnd / 200)
    if r.lastBand and band < r.lastBand then ZA.queue(ZA.tr("Route_ToGo", S.where(tx, ty, 0))) end
    r.lastBand = band

    if r.mode ~= "auto" then return end

    -- ---- autodrive ----
    -- the player braked or reversed: the game switched cruise control off; the car is theirs
    if r.speed and r.speed > 0 and not r.stopping and not v:isRegulator() and t - (r.setAt or 0) > 500 then
        RT.stop(false, ZA.tr("Route_AutoOff"))
        return
    end
    -- speed: by how sharp the road ahead turns, so the car is slow BEFORE the bend (2026-10-20: it hit walls at
    -- junctions, still at 20 km/h in the turn); slower near zombies and near the end
    local want = RT.cruise or (RT.steerMode == "yaw" and 30 or 20)
    local sharp, sharpAt = sharpAhead(r, i, 35)
    if sharp >= 70 then want = math.min(want, (sharpAt or 0) < 15 and 8 or 12)
    elseif sharp >= 40 then want = math.min(want, (sharpAt or 0) < 15 and 12 or 15)
    elseif sharp >= 20 then want = math.min(want, 20) end
    if math.abs(r.steer) > 25 then want = math.min(want, 12) end
    if math.abs(r.steer) > 45 then want = math.min(want, 8) end
    if dEnd < 40 then want = math.min(want, 15) end
    -- stuck: cruise control on, barely moving for 3 seconds (against a wall, in a ditch): stop and say so
    if math.abs(speed) < 2 and r.speed and r.speed > 0 then
        r.slowSince = r.slowSince or t
        if t - r.slowSince > 3000 then RT.stop(false, ZA.tr("Route_Stuck")); return end
    else
        r.slowSince = nil
    end
    -- developer log: how the car follows the route, twice a second
    if ZA.dev and t >= (r.logAt or 0) then
        r.logAt = t + 500
        ZA.log(string.format("[ZA] autodrive: %s %.0f km/h (want %d), steer %.0f, off route %.1f, sharp %.0f at %s",
            RT.steerMode, speed, want, r.steer, off, sharp, tostring(sharpAt and math.floor(sharpAt))))
    end
    if DR.lastAhead and DR.lastAhead.what == "Zombie" and t - DR.lastAhead.t < 1500 then want = math.min(want, 15) end
    -- Something ON THE ROUTE close ahead (a wreck, a solid thing): plan again round it, and only if there is no
    -- way round, stop. Looked for on the route itself (its middle: a route that squeezes past a wreck runs a square
    -- from it, so its sides would stop it there), not straight ahead
    -- of the car: that line runs off the road at every bend (2026-10-20: "Obstacle on the road" and the autodrive
    -- given up, with the route going round it).
    local blockedAhead = nil
    do
        local reach = math.max(8, speed / 3.6 * 2)
        local cell = getCell()
        local z = math.floor(v:getZ())
        for dd = 3, reach, 1 do
            local x, y = along(r, i, dd)
            local x2, y2 = along(r, i, dd + 0.5)
            local hx, hy = x2 - x, y2 - y
            local l = math.sqrt(hx * hx + hy * hy)
            if l > 0.01 then hx, hy = hx / l, hy / l end
            for _, side in ipairs({ 0 }) do
                local sq = cell:getGridSquare(math.floor(x - hy * side), math.floor(y + hx * side), z)
                RT.ownV = v
                if sq and blockedSq(sq) then blockedAhead = dd; break end
            end
            if blockedAhead then break end
        end
    end
    if blockedAhead then
        if not r.roundAt or t - r.roundAt > 1500 then
            r.roundAt = t
            local before = r.pts
            if RT.replan(v) then
                ZA.log("[ZA] autodrive: something on the route at " .. blockedAhead .. " m, planned round it")
                if not r.saidRound then ZA.say(ZA.tr("Route_GoingRound")); r.saidRound = true end
                return
            end
            r.pts = before
        end
        -- no way round, or the new route still meets it: stop
        if blockedAhead <= math.max(5, speed / 3.6 * 1.2) then
            v:setRegulator(false)
            r.stopping = true
            if speed > 2 then brake(v); return end
            RT.stop(false, ZA.tr("Route_InWayRoad"))
            return
        end
        want = math.min(want, 5)
    else
        r.saidRound = nil
    end
    if want ~= r.speed then setSpeed(v, want); r.speed = want; r.setAt = t end

    -- steering: RT.push, on every frame drawn. The game keeps one push per physics step and a second, BIGGER push
    -- before the step CANCELS the first (BaseVehicle.addImpulse, decompiled): so the push is always the same size and
    -- only where it's applied changes. Pushing once per game update was far too weak: the physics runs several
    -- steps per update and each push lasts one (proven 2026-10-02 with a raw test).
    r.wantPush = true
    RT.push()
end

-- ---------- steering by turning the car itself ----------
-- The push below makes the car turn only past a threshold, and by an amount that depends on its grip: it under- and
-- over-steered at junctions (2026-10-20). A car's body can be turned instead (BaseVehicle:setAngles, which moves it
-- in the physics: Bullet.teleportVehicle with its own position and a new heading), a little each frame, by exactly
-- what a car on that path turns: pure pursuit, the curve through a point a few metres along the route, followed at
-- the car's speed, no tighter than a real car can turn (RT.rMin). Its tyres then carry it the new way.
-- Checked the first time on each drive: which way the angle turns the car, and that the car keeps its speed; if
-- either fails, back to the push (RT.steerMode = "push").
RT.steerMode = RT.steerMode or "yaw"
RT.rMin = 5.0         -- metres: the tightest circle a car drives
RT.cal = RT.cal or {}

-- Turn the car `deg` degrees about the vertical. Two catches in the game's angles:
--   they are Euler X, Y, Z, where Y (the heading) only goes from -90 to 90: a car facing the other half of the
--   compass reads X and Z near 180, and there a bigger Y turns it the other way (Rx(180) Ry(y) Rz(180) = Ry(180 - y));
--   setAngles does nothing unless a whole degree changes (it compares the integer parts), so small turns are saved up
--   until they make one (RT.cal.acc).
local function trunc(x) return x >= 0 and math.floor(x) or math.ceil(x) end
local function turnBody(v, deg)
    local ax, ay, az = v:getAngleX(), v:getAngleY(), v:getAngleZ()
    local s = math.abs(ax) > 90 and -1 or 1
    local acc = (RT.cal.acc or 0) + deg
    local ny = ay + s * acc
    if trunc(ny) ~= trunc(ay) or trunc(az) ~= az then
        v:setAngles(ax, ny, az)
        RT.cal.acc = 0
    else
        RT.cal.acc = acc
    end
end

local function pushYaw(r, v, speed)
    local t = getTimestampMs()
    local dt = (t - (r.yawT or t)) / 1000
    r.yawT = t
    if dt <= 0 then return end
    if dt > 0.1 then dt = 0.1 end
    local ms = speed / 3.6
    if ms < 0.8 then return end   -- (also not backwards)
    local C = RT.cal
    -- the check needs the car really moving forward: at walking pace, or backing out, the tyres hold it
    -- (2026-10-20: checked at 0.8 m/s with the route behind, failed, and the drive went on with the push)
    if not C.sign and ms < 2 then return end
    if not C.sign then
        -- which way, and does it keep the speed: turn 3 degrees, look again 0.2 s later
        if not C.at then
            C.hx, C.hy = heading(v)
            C.ms, C.at = ms, t
            turnBody(v, 3)
            return
        end
        if t - C.at < 200 then return end
        local hx, hy = heading(v)
        local cross = C.hx * hy - C.hy * hx   -- + = the car turned right (clockwise on the map)
        local ms2 = v:getCurrentSpeedKmHour() / 3.6
        C.at = nil
        if math.abs(cross) < 0.02 or ms2 < C.ms * 0.6 then
            RT.steerMode = "push"
            C.failed = true
            ZA.log(string.format("[ZA] autodrive: turning the body doesn't work (turned %.3f, speed %.1f -> %.1f m/s), back to the push",
                cross, C.ms, ms2))
            return
        end
        C.sign = cross > 0 and 1 or -1
        ZA.log(string.format("[ZA] autodrive: turning the body works (sign %d, speed %.1f -> %.1f m/s)", C.sign, C.ms, ms2))
    end
    -- pure pursuit: aim at a point a little ahead, nearer when slow (tight turns), further when fast (smooth)
    local look = math.max(4, math.min(12, 3 + ms * 0.7))   -- (shorter overshoots a square corner: a car turns no tighter than 5 m)
    local px, py = along(r, r.i or 1, look)
    local a = math.rad(bearing(v, px, py))          -- + = to the right
    local w
    if math.abs(a) >= math.pi / 2 then
        w = (a > 0 and 1 or -1) * ms / RT.rMin       -- behind you: as tight as a car can
    else
        w = ms * 2 * math.sin(a) / look              -- radians a second, + = right
        local wMax = ms / RT.rMin
        if w > wMax then w = wMax elseif w < -wMax then w = -wMax end
    end
    if w > 1.6 then w = 1.6 elseif w < -1.6 then w = -1.6 end
    turnBody(v, math.deg(w * dt) * C.sign)
end

function RT.push()
    local r = RT.route
    if not r or r.mode ~= "auto" or not r.wantPush or r.stopping then return end
    local p = getPlayer()
    local v = p and p:getVehicle()
    if not v or not r.steer then return end
    local t = getTimestampMs()
    local speed = v:getCurrentSpeedKmHour()
    if RT.steerMode == "yaw" then return pushYaw(r, v, speed) end
    local hx, hy = heading(v)
    local hNow = math.deg(math.atan2(hy, hx))
    -- how fast the car is turning, measured over at least 80 ms (this runs many times between physics steps)
    if not r.lastT or t - r.lastT >= 80 then
        if r.lastH and r.lastT then
            local dh = hNow - r.lastH
            while dh > 180 do dh = dh - 360 end
            while dh < -180 do dh = dh + 360 end
            r.rate = dh / ((t - r.lastT) / 1000)   -- degrees a second; + = turning right (clockwise on the map)
        end
        r.lastH, r.lastT = hNow, t
    end
    local rate = r.rate or 0
    if math.abs(speed) < 3 then return end
    -- (measured 2026-10-02: on the move the tyres hold the car straight until the push passes about 400; above it
    -- the car turns, about 35 degrees a second at 560. So any correction starts at that threshold.)
    local e = r.steer - 0.35 * rate              -- the error, less how fast it's already turning towards it
    local f = 0
    if e > 2 then f = 380 + 22 * e elseif e < -2 then f = -380 + 22 * e end
    if f > 1500 then f = 1500 elseif f < -1500 then f = -1500 end
    r.lastF, r.lastRate = f, rate
    -- the push itself is always the same small size (5), so a second call before the update never counts as
    -- "bigger"; the turn comes from where it's applied: f / 5 squares in front of the car (behind it for the other
    -- way). The turning force is the same as a push of f at 100 squares.
    local arm = f * 20
    v:addImpulse(Vector3f.new(-hy * 5, 0, hx * 5), Vector3f.new(hx * arm, 0, hy * arm))
end
if not RT.ticking then
    RT.ticking = true
    ZA.onTick(function()
        local ok, err = pcall(RT.tick)
        if not ok then print("[ZA] route error: " .. tostring(err)); RT.route = nil end
    end)
end
