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

-- Track assigned personas and their rolled values per vehicle
local vehiclePersonas = {}

-- Total weight for weighted random selection
local totalWeight = 0
for _, p in ipairs(personas) do
  totalWeight = totalWeight + p.weight
end

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

-- Build the vlua command string for a persona
local function buildVluaCmd(data)
  local cmd = string.format(
    'ai.setAggression(%f); ai.setSpeed(%f); ai.setSpeedMode("%s"); ai.driveInLane("%s"); ai.setAvoidCars("%s")',
    data.aggression, data.speed, data.speedMode, data.driveInLane, data.avoidCars
  )
  if data.paramStr then
    cmd = cmd .. string.format('; ai.setParameters(%s)', data.paramStr)
  end
  return cmd
end

local function isPlayerVehicle(vid)
  local playerVeh = be:getPlayerVehicle(0)
  return playerVeh and playerVeh:getID() == vid
end

-- Assign a persona to a vehicle and roll its values
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
    aggression = randRange(persona.aggression),
    speed = randRange(persona.speed),
    speedMode = persona.speedMode,
    driveInLane = persona.driveInLane,
    avoidCars = persona.avoidCars,
    paramStr = paramStr,
  }
  data.vluaCmd = buildVluaCmd(data)

  vehiclePersonas[vid] = data
  log('I', 'drunk_driver', string.format('Vehicle %d assigned persona: %s (aggression=%.2f, driveInLane=%s)', vid, persona.name, data.aggression, data.driveInLane))
  return data
end

-- Inject our overrides into the traffic vehicle's queuedFuncs
-- These run INSIDE the traffic system's own update loop, AFTER setAiMode resets things
local function injectOverride(vid, data)
  if not gameplay_traffic then return end
  local trafficData = gameplay_traffic.getTrafficData()
  if not trafficData then return end
  local trafficVeh = trafficData[vid]
  if not trafficVeh then return end

  -- Use the traffic vehicle's own queuedFuncs mechanism
  -- Timer of 0 means it executes next frame inside the traffic update loop
  trafficVeh.queuedFuncs = trafficVeh.queuedFuncs or {}
  trafficVeh.queuedFuncs.drunk_driver = {timer = 0, vLua = data.vluaCmd}
end

local function onVehicleSpawned(gameVehicleID)
  if isPlayerVehicle(gameVehicleID) then return end
  assignPersona(gameVehicleID)
end

local function onVehicleDestroyed(gameVehicleID)
  vehiclePersonas[gameVehicleID] = nil
end

-- Continuously re-inject overrides every frame via the traffic system's own queuedFuncs
local function onUpdate(dtReal, dtSim, dtRaw)
  if not gameplay_traffic then return end
  local trafficData = gameplay_traffic.getTrafficData()
  if not trafficData then return end

  for vid, data in pairs(vehiclePersonas) do
    local trafficVeh = trafficData[vid]
    if trafficVeh and trafficVeh.isAi and not isPlayerVehicle(vid) then
      -- Continuously inject via queuedFuncs — this runs inside the traffic update loop
      -- so it executes AFTER setAiMode/resetAction override our settings
      trafficVeh.queuedFuncs = trafficVeh.queuedFuncs or {}
      trafficVeh.queuedFuncs.drunk_driver = {timer = 0, vLua = data.vluaCmd}
    end
  end
end

local function onInit()
  log('I', 'drunk_driver', 'Drunk Driver mod loaded - traffic personas active')
end

local function getVehiclePersona(vid)
  return vehiclePersonas[vid]
end

local function listPersonas()
  for _, p in ipairs(personas) do
    log('I', 'drunk_driver', string.format('  %s (weight: %d, aggression: %.1f-%.1f, speed: %.0f-%.0f m/s)',
      p.name, p.weight, p.aggression[1], p.aggression[2], p.speed[1], p.speed[2]))
  end
end

M.onInit = onInit
M.onUpdate = onUpdate
M.onVehicleSpawned = onVehicleSpawned
M.onVehicleDestroyed = onVehicleDestroyed
M.getVehiclePersona = getVehiclePersona
M.listPersonas = listPersonas

return M
