local M = {}

local personas = {
  {
    name = "Grandma",
    weight = 20,
    aggression = {0.15, 0.25},
    speed = {8, 14},
    speedMode = "limit",
    driveInLane = "on",
    avoidCars = "on",
    params = {
      awarenessForceCoef = 2.0,
      turnForceCoef = 0.4,
      lookAheadKv = 0.6,
      trafficWaitTime = 4.0,
    },
  },
  {
    name = "Cautious",
    weight = 25,
    aggression = {0.3, 0.45},
    speed = {13, 18},
    speedMode = "limit",
    driveInLane = "on",
    avoidCars = "on",
    params = {
      awarenessForceCoef = 1.5,
      turnForceCoef = 0.6,
      lookAheadKv = 0.8,
      trafficWaitTime = 3.0,
    },
  },
  {
    name = "Commuter",
    weight = 30,
    aggression = {0.5, 0.7},
    speed = {18, 25},
    speedMode = "limit",
    driveInLane = "on",
    avoidCars = "on",
    params = {
      awarenessForceCoef = 1.0,
      turnForceCoef = 0.8,
      lookAheadKv = 1.0,
      trafficWaitTime = 2.0,
    },
  },
  {
    name = "Rusher",
    weight = 15,
    aggression = {0.9, 1.3},
    speed = {25, 35},
    speedMode = "limit",
    driveInLane = "on",
    avoidCars = "on",
    params = {
      awarenessForceCoef = 0.6,
      turnForceCoef = 1.2,
      lookAheadKv = 1.3,
      trafficWaitTime = 0.8,
    },
  },
  {
    name = "Road Rager",
    weight = 7,
    aggression = {1.4, 1.8},
    speed = {30, 42},
    speedMode = "limit",
    driveInLane = "off",
    avoidCars = "off",
    params = {
      awarenessForceCoef = 0.3,
      turnForceCoef = 1.5,
      lookAheadKv = 1.5,
      trafficWaitTime = 0.3,
    },
  },
  {
    name = "Drunk",
    weight = 3,
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
  },
}

-- Track assigned personas per vehicle
local vehiclePersonas = {}

-- Total weight for weighted random selection
local totalWeight = 0
for _, p in ipairs(personas) do
  totalWeight = totalWeight + p.weight
end

-- Pick a random value within a range
local function randRange(range)
  return range[1] + math.random() * (range[2] - range[1])
end

-- Weighted random persona selection
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

-- Apply a persona's settings to a vehicle
local function applyPersona(veh, persona)
  local aggression = randRange(persona.aggression)
  local speed = randRange(persona.speed)

  veh:queueLuaCommand(string.format('ai.setAggression(%f)', aggression))
  veh:queueLuaCommand(string.format('ai.setSpeed(%f)', speed))
  veh:queueLuaCommand(string.format('ai.setSpeedMode("%s")', persona.speedMode))
  veh:queueLuaCommand(string.format('ai.driveInLane("%s")', persona.driveInLane))
  veh:queueLuaCommand(string.format('ai.setAvoidCars("%s")', persona.avoidCars))

  if persona.params then
    local paramStr = "{"
    for k, v in pairs(persona.params) do
      paramStr = paramStr .. string.format('%s = %f, ', k, v)
    end
    paramStr = paramStr .. "}"
    veh:queueLuaCommand(string.format('ai.setParameters(%s)', paramStr))
  end
end

local function isPlayerVehicle(vid)
  local playerVeh = be:getPlayerVehicle(0)
  return playerVeh and playerVeh:getID() == vid
end

-- Hook: called when any vehicle spawns
local function onVehicleSpawned(gameVehicleID)
  if isPlayerVehicle(gameVehicleID) then return end

  local veh = be:getObjectByID(gameVehicleID)
  if not veh then return end

  local persona = pickPersona()
  vehiclePersonas[gameVehicleID] = persona

  -- Small delay to let the vehicle initialize before applying AI settings
  local vid = gameVehicleID
  local function delayedApply()
    local v = be:getObjectByID(vid)
    if v then
      applyPersona(v, persona)
      log('I', 'drunkDriver', string.format('Vehicle %d assigned persona: %s', vid, persona.name))
    end
  end

  -- Schedule for next frame via onUpdate
  M._pendingApply = M._pendingApply or {}
  table.insert(M._pendingApply, {fn = delayedApply, delay = 0.5, elapsed = 0})
end

-- Hook: clean up when vehicle is removed
local function onVehicleDestroyed(gameVehicleID)
  vehiclePersonas[gameVehicleID] = nil
end

-- Hook: re-apply persona on vehicle reset
local function onVehicleResetted(gameVehicleID)
  if isPlayerVehicle(gameVehicleID) then return end

  local veh = be:getObjectByID(gameVehicleID)
  local persona = vehiclePersonas[gameVehicleID]
  if veh and persona then
    M._pendingApply = M._pendingApply or {}
    table.insert(M._pendingApply, {
      fn = function()
        local v = be:getObjectByID(gameVehicleID)
        if v then applyPersona(v, persona) end
      end,
      delay = 0.5,
      elapsed = 0,
    })
  end
end

-- Process delayed applications
local function onUpdate(dtReal, dtSim, dtRaw)
  if not M._pendingApply then return end

  local remaining = {}
  for _, entry in ipairs(M._pendingApply) do
    entry.elapsed = entry.elapsed + dtReal
    if entry.elapsed >= entry.delay then
      entry.fn()
    else
      table.insert(remaining, entry)
    end
  end

  if #remaining > 0 then
    M._pendingApply = remaining
  else
    M._pendingApply = nil
  end
end

local function onInit()
  log('I', 'drunkDriver', 'Drunk Driver mod loaded - traffic personas active')
end

-- Public API for other mods or console use
local function getVehiclePersona(vid)
  return vehiclePersonas[vid]
end

local function listPersonas()
  for _, p in ipairs(personas) do
    log('I', 'drunkDriver', string.format('  %s (weight: %d, aggression: %.1f-%.1f, speed: %.0f-%.0f m/s)',
      p.name, p.weight, p.aggression[1], p.aggression[2], p.speed[1], p.speed[2]))
  end
end

M.onInit = onInit
M.onUpdate = onUpdate
M.onVehicleSpawned = onVehicleSpawned
M.onVehicleDestroyed = onVehicleDestroyed
M.onVehicleResetted = onVehicleResetted
M.getVehiclePersona = getVehiclePersona
M.listPersonas = listPersonas

return M
