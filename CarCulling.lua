--[[
  Car Culling - a small CSP Lua app for online races.

  1. Stops drawing cars that nobody is driving (the cars of free slots, parked in their pit boxes).
  2. Optionally stops drawing all but the nearest cars, to help in races with many cars.

  It only hides the 3D models of the cars on your screen (it never touches physics, collisions or the network),
  and it never hides your own car or the car you are watching. Cars come back by themselves as soon as they
  should be drawn again (a driver joins the slot, the car moves, it gets near, the app is switched off).

  How a car is hidden (setting "How cars are hidden"):
  - the car as a whole is switched off at several moments of every frame (the game switches it on again by itself);
  - by default every mesh of the car is switched off as well (online, switching off only the car as a whole was not enough);
  - or, for cars nobody drives, the car can be switched off with ac.setCarActive.

  How a car comes back: the meshes of a car are looked up ONCE, before the car is hidden for the first time, together with
  the visibility flag of each of them. Those same references are used to put the flags back (a new search while the car
  is hidden might not find the hidden meshes again), and the result is checked afterwards. The car as a whole is switched
  on again from the UI callback (the moment the "Car Culling Lab" buttons ran in) and kept on for a while.

  Which cars are drawn (option "Only draw the nearest cars"): the nearest N cars, plus every car within a distance.
  Optionally with different numbers and distances for the cars in front of and behind the car you are watching
  (only when there are more than a chosen number of cars), and with the distance measured along the track instead
  of in a straight line (switching to a straight line by itself when you leave the track).

  Install: put this folder in  assettocorsa/apps/lua/  (the file name has to match the folder name).
  Settings are in the "Car Culling" window (open it from the apps bar in the game).
  To draw all the cars again untick "Active": closing the window does not stop the app.
]]

local sim = ac.getSim()

-- settings (kept between sessions) -------------------------------------------------------------------------
local stored = {
  enabled   = ac.storage('CarCulling.enabled', true),
  hideEmpty = ac.storage('CarCulling.hideEmpty', true),
  pitsOnly  = ac.storage('CarCulling.emptyOnlyInPits', true),
  limit     = ac.storage('CarCulling.limitCars', false),
  maxCars   = ac.storage('CarCulling.maxCars', 15),
  within    = ac.storage('CarCulling.alwaysWithin', 100),
  method    = ac.storage('CarCulling.hideMethod', 'meshes'),
  distMode  = ac.storage('CarCulling.distanceMode', 'raw'),
  autoRaw   = ac.storage('CarCulling.rawWhenOffTrack', true),
  split     = ac.storage('CarCulling.frontBack', false),
  splitFrom = ac.storage('CarCulling.frontBackFrom', 20),
  maxFront  = ac.storage('CarCulling.maxFront', 15),
  withinFront = ac.storage('CarCulling.withinFront', 150),
  maxBack   = ac.storage('CarCulling.maxBack', 5),
  withinBack = ac.storage('CarCulling.withinBack', 30),
}
local cfg = {}
for key, entry in pairs(stored) do cfg[key] = entry:get() end

-- the ways of measuring the distance to a car
local DISTANCES = {
  { id = 'raw',   label = 'Straight line' },
  { id = 'track', label = 'Along the track' },
}

-- the ways of hiding a car (the first one is the default)
local METHODS = {
  { id = 'meshes', label = 'The car and every part of it',
    note = 'Switches off the car and every mesh of it. This is what worked online.' },
  { id = 'node',   label = 'The car as a whole only',
    note = 'Lightest, but online the game may switch the car on again before it is drawn.' },
  { id = 'active', label = 'Switch unoccupied cars off',
    note = 'Unoccupied cars are switched off with ac.setCarActive; cars hidden for being far away use the first way.' },
}
local function knownMethod(id)
  for _, m in ipairs(METHODS) do if m.id == id then return true end end
  return false
end
if not knownMethod(cfg.method) then cfg.method = METHODS[1].id end
if cfg.distMode ~= 'raw' and cfg.distMode ~= 'track' then cfg.distMode = 'raw' end
local function save(key, value)
  cfg[key] = value
  stored[key]:set(value)
end

-- state ----------------------------------------------------------------------------------------------------
local DECIDE_EVERY = 0.25      -- seconds between two looks at who is driving / who is near
local REFRESH_NODES_EVERY = 5  -- seconds between two refreshes of the cached scene references
local KEEP_BONUS = 0.9         -- a car that is already drawn counts as 10% closer, so two cars at about the same distance don't keep swapping
local PARKED_SPEED = 3         -- km/h: an unoccupied car that moves faster than this is left alone
local KEEP_SHOWN_FRAMES = 30   -- frames a car that was switched on again is kept switched on
local SAFE_RAW_DISTANCE = 20   -- m: measuring along the track, a car this close in a straight line is never hidden
local OFF_TRACK_WHEELS = 3     -- this many wheels off the track means "off the track"
local BACK_ON_TRACK_DELAY = 2  -- seconds on the track before distances are measured along the track again
local CAMERA_NEAR_CAR = 40     -- m: farther than this from the car being watched (replay, free camera) a straight line is used
local SIDE_MARGIN = 5          -- m: a car has to be this far into the other half (front / behind) to change sides
local VERIFY_TRIES = 3         -- how often the meshes of a car are put back before the app gives up on that car
local PROBE_AFTER_FRAMES = 3   -- frames after a car's meshes were hidden, a few numbers are written down for the report

local nodes = {}               -- car index -> scene reference of the car
local hidden = {}              -- car index -> true while the app keeps that car hidden
local reason = {}              -- car index -> 'empty' or 'far'
local restoring = {}           -- car index -> frames left to keep it switched on
local held = {}                -- car index -> the meshes of the car, found before it was hidden, and what each of them looked like
local off = {}                 -- car index -> true while the car is switched off with ac.setCarActive
local reactivate = {}          -- car index -> frames left to keep calling ac.setCarActive(i, true)
local scratchRef = ac.emptySceneReference()
local side = {}                -- car index -> 'front' or 'back' (only while the front/back limits are in use)
local clock, lastOffTrack = 0, -1e9
local stats = { total = 0, driven = 0, hiddenEmpty = 0, hiddenFar = 0, emptyShown = 0, restoreOk = 0,
                hiddenFront = 0, hiddenBack = 0, candidates = 0, measuring = 'straight line', splitState = 'off' }
local report = { hide = nil, restore = nil }   -- the last numbers written down for the "Copy report" button
local timer, nodesAge = 1e9, 0
local reportedError = false

local function carNode(i)
  local node = nodes[i]
  if node == nil then
    node = ac.findNodes('carRoot:' .. i)
    nodes[i] = node
  end
  return node
end

-- how a hidden car is hidden --------------------------------------------------------------------------------
local function hasActive() return type(ac.setCarActive) == 'function' end

-- does this car have its meshes switched off right now (or should it)?
local function usesMeshes(i)
  if not hidden[i] then return false end
  if cfg.method == 'meshes' then return true end
  return cfg.method == 'active' and (reason[i] ~= 'empty' or not hasActive())
end

-- is this car switched off with ac.setCarActive (or should it be)?
local function usesActive(i)
  return hidden[i] and cfg.method == 'active' and reason[i] == 'empty' and hasActive()
end

local function countVisible(ref, n)
  local c = 0
  for k = 1, n do if ref:isVisible(k) then c = c + 1 end end
  return c
end

-- finds the meshes of a car ONCE, before it is hidden for the first time, and writes down which of them are visible.
-- The same references are used to put them back: a new search while they are hidden might not return them.
local function snapshot(i)
  local h = held[i]
  if h ~= nil then return h end
  local root = carNode(i)
  local meshes, skinned = root:findMeshes('?'), root:findSkinnedMeshes('?')
  h = { meshes = meshes, skinned = skinned, flags = {}, skinFlags = {}, tries = 0, probe = PROBE_AFTER_FRAMES }
  for k = 1, #meshes do h.flags[k] = meshes:isVisible(k) and true or false end
  for k = 1, #skinned do h.skinFlags[k] = skinned:isVisible(k) and true or false end
  h.before = countVisible(meshes, #h.flags) + countVisible(skinned, #h.skinFlags)
  held[i] = h
  return h
end

local function hideMeshes(h)
  h.meshes:setVisible(false)
  h.skinned:setVisible(false)
end

-- puts the visibility of every mesh back to what it was. `everything` switches all of them on first
-- (a second way of doing it, used when the first one did not work), then each one is set to its own flag.
local function putBack(h, everything)
  if everything then
    h.meshes:setVisible(true)
    h.skinned:setVisible(true)
  end
  for k = 1, #h.flags do h.meshes:at(k, scratchRef):setVisible(h.flags[k]) end
  for k = 1, #h.skinFlags do h.skinned:at(k, scratchRef):setVisible(h.skinFlags[k]) end
end

local function matching(h)
  local ok, total = 0, #h.flags + #h.skinFlags
  for k = 1, #h.flags do if (h.meshes:isVisible(k) and true or false) == h.flags[k] then ok = ok + 1 end end
  for k = 1, #h.skinFlags do if (h.skinned:isVisible(k) and true or false) == h.skinFlags[k] then ok = ok + 1 end end
  return ok, total
end

-- switches a car on again; it is then kept on for a while (see keepShown)
local function showCar(i)
  hidden[i], reason[i] = nil, nil
  restoring[i] = KEEP_SHOWN_FRAMES
  carNode(i):setVisible(true)
end

local function restoreAll()
  for i in pairs(hidden) do showCar(i) end
  stats.hiddenEmpty, stats.hiddenFar = 0, 0
end

-- keeps the cars we hide switched off. Called at several moments of a frame, because the game
-- (or CSP) switches them on again by itself at some point, and the last call wins.
local function enforce()
  for i in pairs(hidden) do
    local h = usesMeshes(i) and snapshot(i) or nil   -- (before anything is switched off)
    carNode(i):setVisible(false)
    if h ~= nil then
      h.left, h.failed = nil, nil                    -- hidden again: whatever was being put back is cancelled
      hideMeshes(h)
    end
  end
end

-- keeps the cars that were switched on again switched on. In the UI callback a car is switched off and on again first:
-- that is what the "Car Culling Lab" did when its Show button was pressed, and it worked every time.
local function keepShown(toggle)
  for i in pairs(restoring) do
    local node = carNode(i)
    if toggle then node:setVisible(false) end
    node:setVisible(true)
  end
end

-- puts the meshes of cars back that should be drawn again, then checks that it worked
local function stepMeshes(countdown)
  for i, h in pairs(held) do
    if h.left ~= nil then
      putBack(h, h.tries >= 1)
      if countdown then
        h.left = h.left - 1
        if h.left <= 0 then
          local ok, total = matching(h)
          if ok == total then
            held[i] = nil
            stats.restoreOk = stats.restoreOk + 1
            report.restore = { car = i, ok = true, matching = ok, total = total, tries = h.tries + 1 }
          else
            h.tries = h.tries + 1
            report.restore = { car = i, ok = false, matching = ok, total = total, tries = h.tries }
            if h.tries >= VERIFY_TRIES then h.left, h.failed = nil, true else h.left = KEEP_SHOWN_FRAMES end
          end
        end
      end
    end
  end
end

-- writes down, a few frames after the meshes of a car were hidden, how many of them are off and what a new search finds
local function probes()
  for i, h in pairs(held) do
    if h.probe ~= nil then
      if not usesMeshes(i) then
        h.probe = nil
      else
        h.probe = h.probe - 1
        if h.probe <= 0 then
          h.probe = nil
          local root = carNode(i)
          report.hide = {
            car = i, total = #h.flags + #h.skinFlags, before = h.before,
            after = countVisible(h.meshes, #h.flags) + countVisible(h.skinned, #h.skinFlags),
            found = #root:findMeshes('?') + #root:findSkinnedMeshes('?'),
          }
        end
      end
    end
  end
end

local function stepReactivate(countdown)
  for i, left in pairs(reactivate) do
    if hasActive() then ac.setCarActive(i, true) end
    if countdown then
      if left <= 1 then reactivate[i] = nil else reactivate[i] = left - 1 end
    end
  end
end

-- brings the car back that the last method changed, when the method (or the reason for hiding) is not that any more
local function reconcile()
  for i, h in pairs(held) do
    if h.left == nil and not h.failed and not usesMeshes(i) then h.left, h.tries = KEEP_SHOWN_FRAMES, 0 end
  end
  for i in pairs(off) do
    if not usesActive(i) then
      off[i] = nil
      reactivate[i] = KEEP_SHOWN_FRAMES
    end
  end
  for i in pairs(hidden) do
    if usesActive(i) and not off[i] then
      ac.setCarActive(i, false)
      off[i], reactivate[i] = true, nil
    end
  end
end

-- switches the app off and draws every other car again, also cars this run of the app knows nothing about
-- (for example after the app was reloaded while cars were hidden). The cars this run does know about
-- are switched on by update(), which restores everything as soon as the app is off.
local function drawEveryCar()
  save('enabled', false)
  nodes, nodesAge = {}, 0
  for i = 1, sim.carsCount - 1 do restoring[i] = KEEP_SHOWN_FRAMES * 2 end
  for _, h in pairs(held) do h.left, h.tries, h.failed = KEEP_SHOWN_FRAMES, 0, nil end
  timer = 1e9
end

local function countDownRestoring()
  for i, left in pairs(restoring) do
    if left <= 1 then restoring[i] = nil else restoring[i] = left - 1 end
  end
end

-- decide who gets hidden ----------------------------------------------------------------------------------

-- how distances are measured right now: 'raw' (straight line) or 'track' (along the track), the spline position
-- of the car being watched, and a few words for the window
local function chooseMeasuring(ref, camera)
  if cfg.distMode ~= 'track' then return 'raw', nil, 'straight line' end
  local length = sim.trackLengthM
  if ref == nil or type(ref.splinePosition) ~= 'number' or type(length) ~= 'number' or length < 10 then
    return 'raw', nil, 'straight line (no track information)'
  end
  if cfg.autoRaw then
    if (ref.wheelsOutside or 0) >= OFF_TRACK_WHEELS then lastOffTrack = clock end
    if clock - lastOffTrack < BACK_ON_TRACK_DELAY then return 'raw', nil, 'straight line (off the track)' end
    if ref.isInPitlane then return 'raw', nil, 'straight line (in the pits)' end
  end
  local p = ref.position
  if camera ~= nil and p ~= nil then
    local dx, dy, dz = camera.x - p.x, camera.y - p.y, camera.z - p.z
    if dx * dx + dy * dy + dz * dz > CAMERA_NEAR_CAR * CAMERA_NEAR_CAR then
      return 'raw', nil, 'straight line (camera away from the car)'
    end
  end
  return 'track', ref.splinePosition, 'along the track'
end

local function decide()
  local count = sim.carsCount
  local focused = sim.focusedCar
  local camera = sim.cameraPosition
  local ref = ac.getCar(focused)           -- the car being watched: its direction says what is in front
  local look = ref ~= nil and ref.look or nil
  local measuring, refSpline, measuringText = 'raw', nil, 'straight line'
  measuring, refSpline, measuringText = chooseMeasuring(ref, camera)
  local wanted = {}          -- car index -> 'empty' / 'far'
  local candidates = {}      -- cars that can still be hidden because of distance
  local total, driven, emptyShown = 0, 0, 0

  for i = 0, count - 1 do
    local car = ac.getCar(i)
    if car ~= nil then
      total = total + 1
      local connected = (car.isConnected or car.isAIControlled) and true or false   -- (bots count as driven)
      if connected then driven = driven + 1 end
      local mine = (i == 0 or i == focused)
      if not mine then
        local hideAsEmpty = false
        if cfg.hideEmpty and not connected then
          hideAsEmpty = (not cfg.pitsOnly or car.isInPitlane) and car.speedKmh < PARKED_SPEED
          if not hideAsEmpty then emptyShown = emptyShown + 1 end
        end
        if hideAsEmpty then
          wanted[i] = 'empty'
        elseif cfg.limit and camera ~= nil then
          local p = car.position
          local dx, dy, dz = p.x - camera.x, p.y - camera.y, p.z - camera.z
          local raw = math.sqrt(dx * dx + dy * dy + dz * dz)
          local dist, near = raw, false
          if measuring == 'track' and type(car.splinePosition) == 'number' then
            local d = math.abs(car.splinePosition - refSpline)
            if d > 0.5 then d = 1 - d end
            dist = d * sim.trackLengthM
            near = raw <= SAFE_RAW_DISTANCE
          end
          local along = 1                -- how far in front of the car being watched (negative: behind), in metres
          if look ~= nil then along = dx * look.x + dz * look.z end
          candidates[#candidates + 1] = { index = i, dist = dist, near = near, along = along }
        end
      end
    end
  end

  -- the nearest `limit` cars of a list are kept, and every car within `within`; the rest is hidden
  local function pick(list, limit, within)
    for _, c in ipairs(list) do
      c.key = hidden[c.index] and c.dist or c.dist * KEEP_BONUS
    end
    table.sort(list, function(a, b) return a.key < b.key end)
    local hiding = 0
    for rank, c in ipairs(list) do
      if rank > limit and c.dist > within and not c.near then
        wanted[c.index] = 'far'
        hiding = hiding + 1
      end
    end
    return hiding
  end

  local hiddenFront, hiddenBack = 0, 0
  local splitState = 'off'
  if cfg.limit and #candidates > 0 then
    if cfg.split and #candidates > cfg.splitFrom then
      splitState = 'on'
      local front, back, seen = {}, {}, {}
      for _, c in ipairs(candidates) do
        local was = side[c.index]
        if was == 'front' then
          if c.along < -SIDE_MARGIN then was = 'back' end
        elseif was == 'back' then
          if c.along > SIDE_MARGIN then was = 'front' end
        else
          was = c.along >= 0 and 'front' or 'back'
        end
        side[c.index], seen[c.index] = was, true
        local list = was == 'front' and front or back
        list[#list + 1] = c
      end
      for i in pairs(side) do if not seen[i] then side[i] = nil end end
      hiddenFront = pick(front, cfg.maxFront, cfg.withinFront)
      hiddenBack = pick(back, cfg.maxBack, cfg.withinBack)
    else
      if cfg.split then splitState = 'waiting' end
      side = {}
      pick(candidates, cfg.maxCars, cfg.within)
    end
  end

  -- apply
  local hiddenEmpty, hiddenFar = 0, 0
  for i = 0, count - 1 do
    local why = wanted[i]
    if why then
      if why == 'empty' then hiddenEmpty = hiddenEmpty + 1 else hiddenFar = hiddenFar + 1 end
      hidden[i], reason[i], restoring[i] = true, why, nil
    elseif hidden[i] then
      showCar(i)
    end
  end
  -- cars that vanished from the list (can't happen online, but costs nothing to be safe)
  for i in pairs(hidden) do
    if i >= count then hidden[i], reason[i] = nil, nil end
  end
  for i in pairs(restoring) do
    if i >= count then restoring[i] = nil end
  end

  stats.total, stats.driven, stats.hiddenEmpty, stats.hiddenFar, stats.emptyShown = total, driven, hiddenEmpty, hiddenFar, emptyShown
  stats.hiddenFront, stats.hiddenBack, stats.candidates = hiddenFront, hiddenBack, #candidates
  stats.measuring, stats.splitState = measuringText, splitState
end

local function update(dt)
  if not cfg.enabled then
    if next(hidden) ~= nil then restoreAll() end
    timer = 1e9 -- look again right away when switched on
    reconcile()
    keepShown(false)
    stepMeshes(true)
    stepReactivate(true)
    countDownRestoring()
    return
  end

  clock = clock + dt
  nodesAge = nodesAge + dt
  if nodesAge > REFRESH_NODES_EVERY then nodes, nodesAge = {}, 0 end

  timer = timer + dt
  if timer >= DECIDE_EVERY then
    timer = 0
    decide()
  end

  reconcile()
  enforce()
  keepShown(false)
  stepMeshes(true)
  stepReactivate(true)
  probes()
  countDownRestoring()
end

local function guarded(fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok and not reportedError then
    reportedError = true
    ac.log('Car Culling error: ' .. tostring(err))
  end
end

local function atStage()
  if cfg.enabled then enforce() end
  keepShown(false)
end

local function atUi()
  keepShown(true)
  stepMeshes(false)
  stepReactivate(false)
end

function script.update(dt) guarded(update, dt) end

-- the callbacks below are connected to the game in manifest.ini ([SIM_CALLBACKS], [RENDER_CALLBACKS], [UI_CALLBACKS])
function script.simUpdate() guarded(atStage) end
function script.frameBegin() guarded(atStage) end
function script.afterOpaque() guarded(atStage) end
function script.uiFrame() guarded(atUi) end
simUpdate, frameBegin, afterOpaque, uiFrame = script.simUpdate, script.frameBegin, script.afterOpaque, script.uiFrame

-- text for the "Copy report" button ------------------------------------------------------------------------------
local function buildReport()
  local lines = {}
  local function add(...) lines[#lines + 1] = string.format(...) end
  add('Car Culling 1.5.1 | method %s | cars %d, driven %d, hidden: empty %d, far %d | restored fine: %d',
    cfg.method, stats.total, stats.driven, stats.hiddenEmpty, stats.hiddenFar, stats.restoreOk)
  add('distance: %s | front/back limits: %s, %d other cars | hidden in front %d, behind %d',
    stats.measuring, stats.splitState, stats.candidates, stats.hiddenFront, stats.hiddenBack)
  local failed, pending = 0, 0
  for _, h in pairs(held) do
    if h.failed then failed = failed + 1 elseif h.left ~= nil then pending = pending + 1 end
  end
  add('cars not restored completely: %d | being restored now: %d | ac.setCarActive: %s', failed, pending, hasActive() and 'yes' or 'no')
  local a = report.hide
  if a then
    add('hide check: car %d | meshes %d | visible before hiding %d | visible a few frames later %d | found by a new search %d',
      a.car, a.total, a.before, a.after, a.found)
  else
    add('hide check: nothing written down yet')
  end
  local b = report.restore
  if b then
    add('restore check: car %d | %s | %d of %d meshes as before | tries %d', b.car, b.ok and 'ok' or 'NOT ok', b.matching, b.total, b.tries)
  else
    add('restore check: nothing written down yet')
  end
  return table.concat(lines, '\n')
end

-- window -------------------------------------------------------------------------------------------------------
local function toggle(label, key)
  if ui.checkbox(label, cfg[key]) then
    save(key, not cfg[key])
    timer = 1e9
  end
end

-- a whole-number slider for a setting
local function slider(key, lo, hi, format)
  ui.setNextItemWidth(ui.availableSpaceX())
  local value = ui.slider('##' .. key, cfg[key], lo, hi, format)
  if value ~= cfg[key] then
    save(key, math.round(value))
    timer = 1e9
  end
end

-- greys out (and blocks) the controls that follow while `cond` is true; returns what endGrey() needs
local function grey(cond)
  if cond then ui.pushDisabled() end
  return cond
end
local function endGrey(was)
  if was then ui.popDisabled() end
end

function script.windowMain(dt)
  toggle('Active', 'enabled')

  ui.separator()
  local g1 = grey(not cfg.enabled)

  toggle('Hide cars nobody is driving', 'hideEmpty')
  local g2 = grey(not cfg.hideEmpty)
  ui.indent()
  toggle('Only while parked in the pit lane', 'pitsOnly')
  ui.unindent()
  endGrey(g2)

  ui.separator()
  ui.text('How cars are hidden')
  for _, m in ipairs(METHODS) do
    if ui.radioButton(m.label, cfg.method == m.id) then
      save('method', m.id)
      timer = 1e9
    end
  end
  for _, m in ipairs(METHODS) do
    if m.id == cfg.method then ui.textWrapped(m.note) end
  end
  if cfg.method == 'active' and not hasActive() then
    ui.pushStyleColor(ui.StyleColor.Text, rgbm(1, 0.8, 0.3, 1))
    ui.textWrapped('ac.setCarActive is not available here, so the first way is used instead.')
    ui.popStyleColor()
  end

  ui.separator()
  toggle('Only draw the nearest cars', 'limit')
  local g3 = grey(not cfg.limit)

  ui.text('Measure the distance')
  for _, d in ipairs(DISTANCES) do
    if ui.radioButton(d.label, cfg.distMode == d.id) then
      save('distMode', d.id)
      timer = 1e9
    end
  end
  ui.indent()
  local g4 = grey(cfg.distMode ~= 'track')
  toggle('Straight line when off the track or in the pits', 'autoRaw')
  endGrey(g4)
  ui.unindent()

  toggle('Different limits in front of and behind me', 'split')
  if cfg.split then
    ui.indent()
    slider('splitFrom', 0, 100, 'Only with more than %.0f other cars')
    slider('maxFront', 0, 50, 'In front: draw the nearest %.0f cars')
    slider('withinFront', 0, 500, 'In front: always draw within %.0f m')
    slider('maxBack', 0, 50, 'Behind: draw the nearest %.0f cars')
    slider('withinBack', 0, 500, 'Behind: always draw within %.0f m')
    ui.unindent()
  end

  -- the normal limits: with the front/back limits on, they only apply when there are few cars
  -- (and not at all when those start at 0 other cars, so they are not shown then)
  if not cfg.split or cfg.splitFrom > 0 then
    if cfg.split then ui.text(string.format('With %d other cars or fewer:', cfg.splitFrom)) end
    slider('maxCars', 2, 50, 'Draw the nearest %.0f cars')
    slider('within', 0, 500, 'Always draw cars within: %.0f m')
  end
  endGrey(g3)

  endGrey(g1)

  ui.separator()
  ui.text(string.format('Cars in the session: %d', stats.total))
  ui.text(string.format('Driven by someone: %d', stats.driven))
  ui.text(string.format('Hidden, nobody driving: %d', stats.hiddenEmpty))
  if stats.splitState == 'on' then
    ui.text(string.format('Hidden, far away: %d (in front %d, behind %d)', stats.hiddenFar, stats.hiddenFront, stats.hiddenBack))
  else
    ui.text(string.format('Hidden, far away: %d', stats.hiddenFar))
  end
  if cfg.limit then
    ui.text('Distance: ' .. stats.measuring)
    if stats.splitState == 'on' then
      ui.text(string.format('Front/back limits: on (%d other cars)', stats.candidates))
    elseif stats.splitState == 'waiting' then
      ui.text(string.format('Front/back limits: not yet (%d other cars, from %d)', stats.candidates, cfg.splitFrom + 1))
    end
  end
  if cfg.hideEmpty and stats.emptyShown > 0 then
    ui.pushStyleColor(ui.StyleColor.Text, rgbm(1, 0.8, 0.3, 1))
    ui.textWrapped(string.format('%d unoccupied car(s) are still drawn (not parked in the pit lane, or moving).', stats.emptyShown))
    ui.popStyleColor()
  end

  local failed = 0
  for _, h in pairs(held) do if h.failed then failed = failed + 1 end end
  if failed > 0 then
    ui.pushStyleColor(ui.StyleColor.Text, rgbm(1, 0.5, 0.4, 1))
    ui.textWrapped(string.format('%d car(s) did not come back completely. Press "Stop and draw every car" to try again.', failed))
    ui.popStyleColor()
  end

  ui.separator()
  ui.textWrapped('To draw all the cars again, untick "Active". Closing this window does not stop the app.')
  if ui.button('Stop and draw every car') then drawEveryCar() end
  if ui.button('Copy report') then ac.setClipboardText(buildReport()) end
end
windowMain = script.windowMain
