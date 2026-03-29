local M = {}

local personas = {
  {
    name = "Drunk",
    weight = 1,
    aiMode = "span",
    aggression = {0.6, 1.2},
    speed = {12, 28},
    speedMode = "limit",
    driveInLane = "off",
    avoidCars = "off",
    params = {
      awarenessForceCoef = 0.2,
      turnForceCoef = 0.5,
      lookAheadKv = 0.4,
      trafficWaitTime = 5.0,
    },
    steerWobble = {amp = 0.15, freq1 = 1.5, freq2 = 0.6},
  },
}

local vehiclePersonas = {}

local totalWeight = 0
for _, p in ipairs(personas) do
  totalWeight = totalWeight + p.weight
end

local reapplyInterval = 0.1
local reapplyTimer = 0
local scanInterval = 2.0
local scanTimer = 0
local hookReinjectInterval = 5.0
local hookReinjectTimer = 0

local function randRange(range)
  return range[1] + math.random() * (range[2] - range[1])
end

local function pickPersona()
  local roll = math.random() * totalWeight
  local cumulative = 0
  for _, p in ipairs(personas) do
    cumulative = cumulative + p.weight
    if roll <= cumulative then
      return p
    end
  end
  return personas[#personas]
end

local function buildVluaCmd(data)
  local cmd = ""
  if data.aiMode then
    cmd = string.format('ai.setMode("%s"); ', data.aiMode)
  end
  cmd = cmd .. string.format(
    'ai.setAggression(%f); ai.setSpeed(%f); ai.setSpeedMode("%s"); ai.driveInLane("%s"); ai.setAvoidCars("%s")',
    data.aggression, data.speed, data.speedMode, data.driveInLane, data.avoidCars
  )
  if data.paramStr then
    cmd = cmd .. string.format('; ai.setParameters(%s)', data.paramStr)
  end
  return cmd
end

local function buildSteerHookCmd(wobble)
  return string.format([[
    if not _dd_steer then
      _dd_steer = {t = 0, amp = %f, f1 = %f, f2 = %f}
      local _dd_gfx = updateGFX
      updateGFX = function(dt)
        if _dd_gfx then _dd_gfx(dt) end
        _dd_steer.t = _dd_steer.t + dt
        local w = math.sin(_dd_steer.t * _dd_steer.f1 * 6.283) * _dd_steer.amp
                + math.sin(_dd_steer.t * _dd_steer.f2 * 6.283) * _dd_steer.amp * 0.5
        local s = electrics.values.steering
        if s then electrics.values.steering = s + w end
      end
    end
  ]], wobble.amp, wobble.freq1, wobble.freq2)
end

local function isPlayerVehicle(vid)
  local playerVeh = be:getPlayerVehicle(0)
  return playerVeh and playerVeh:getID() == vid
end

local function assignPersona(vid)
  local persona = pickPersona()
  local paramStr = nil
  if persona.params then
    paramStr = "{"
    for k, v in pairs(persona.params) do
      paramStr = paramStr .. string.format('%s = %f, ', k, v)
    end
    paramStr = paramStr .. "}"
  end

  local data = {
    name = persona.name,
    aiMode = persona.aiMode,
    aggression = randRange(persona.aggression),
    speed = randRange(persona.speed),
    speedMode = persona.speedMode,
    driveInLane = persona.driveInLane,
    avoidCars = persona.avoidCars,
    paramStr = paramStr,
  }
  data.vluaCmd = buildVluaCmd(data)

  if persona.steerWobble then
    data.steerHookCmd = buildSteerHookCmd(persona.steerWobble)
  end

  vehiclePersonas[vid] = data
  log('I', 'drunk_driver', string.format('Vehicle %d assigned persona: %s (aggression=%.2f, speed=%.1f, aiMode=%s)',
    vid, persona.name, data.aggression, data.speed, tostring(data.aiMode or "traffic")))
  return data
end

local function applyPersona(vid, data)
  local veh = be:getObjectByID(vid)
  if veh then
    veh:queueLuaCommand(data.vluaCmd)
  end
end

local function injectSteerHook(vid, data)
  if not data.steerHookCmd then return end
  local veh = be:getObjectByID(vid)
  if veh then
    veh:queueLuaCommand(data.steerHookCmd)
  end
end

local function onVehicleSpawned(gameVehicleID)
  if isPlayerVehicle(gameVehicleID) then return end
  local data = assignPersona(gameVehicleID)
  applyPersona(gameVehicleID, data)
  injectSteerHook(gameVehicleID, data)
end

local function onVehicleDestroyed(gameVehicleID)
  vehiclePersonas[gameVehicleID] = nil
end

local function adoptExistingTraffic()
  local count = be:getObjectCount()
  for i = 0, count - 1 do
    local veh = be:getObject(i)
    if veh then
      local vid = veh:getID()
      if not isPlayerVehicle(vid) and not vehiclePersonas[vid] then
        local data = assignPersona(vid)
        applyPersona(vid, data)
        injectSteerHook(vid, data)
      end
    end
  end
end

local function onPreRender(dtReal, dtSim, dtRaw)
  reapplyTimer = reapplyTimer + dtSim
  if reapplyTimer < reapplyInterval then return end
  reapplyTimer = 0

  for vid, data in pairs(vehiclePersonas) do
    if not isPlayerVehicle(vid) then
      applyPersona(vid, data)
    end
  end
end

local function onUpdate(dtReal, dtSim, dtRaw)
  scanTimer = scanTimer + dtSim
  if scanTimer >= scanInterval then
    scanTimer = 0
    adoptExistingTraffic()
  end

  hookReinjectTimer = hookReinjectTimer + dtSim
  if hookReinjectTimer >= hookReinjectInterval then
    hookReinjectTimer = 0
    for vid, data in pairs(vehiclePersonas) do
      if not isPlayerVehicle(vid) then
        injectSteerHook(vid, data)
      end
    end
  end
end

local function onTrafficStarted()
  adoptExistingTraffic()
end

local function onInit()
  log('I', 'drunk_driver', 'Drunk Driver mod loaded - traffic personas active')
  adoptExistingTraffic()
end

local function getVehiclePersona(vid)
  return vehiclePersonas[vid]
end

local function listPersonas()
  for _, p in ipairs(personas) do
    log('I', 'drunk_driver', string.format('  %s (weight: %d, aggression: %.1f-%.1f, speed: %.0f-%.0f m/s, aiMode=%s)',
      p.name, p.weight, p.aggression[1], p.aggression[2], p.speed[1], p.speed[2], tostring(p.aiMode or "traffic")))
  end
end

M.onInit = onInit
M.onUpdate = onUpdate
M.onPreRender = onPreRender
M.onVehicleSpawned = onVehicleSpawned
M.onVehicleDestroyed = onVehicleDestroyed
M.onTrafficStarted = onTrafficStarted
M.getVehiclePersona = getVehiclePersona
M.listPersonas = listPersonas

return M
