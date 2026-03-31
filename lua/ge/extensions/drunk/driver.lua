local M = {}
local im = ui_imgui

local personas = {
  {
    name = "Normal",
    weight = 84,
    aggression = {0.3, 0.6},
    speed = {10, 18},
    speedMode = "legal",
    driveInLane = "on",
    avoidCars = "on",
  },
  {
    name = "Tipsy",
    weight = 3,
    aggression = {0.5, 0.8},
    speed = {10, 20},
    speedMode = "legal",
    driveInLane = "on",
    avoidCars = "on",
    params = {
      awarenessForceCoef = 0.4,
      turnForceCoef = 0.5,
      lookAheadKv = 0.6,
    },
    steerWobble = {amp = 0.05, freq1 = 1.0, freq2 = 0.4},
  },
  {
    name = "Drunk",
    weight = 2,
    aggression = {0.8, 1.2},
    speed = {12, 22},
    speedMode = "set",
    driveInLane = "off",
    avoidCars = "on",
    params = {
      awarenessForceCoef = 0.2,
      turnForceCoef = 0.3,
      lookAheadKv = 0.4,
      trafficWaitTime = 0.5,
    },
    steerWobble = {amp = 0.12, freq1 = 1.5, freq2 = 0.6},
  },
  {
    name = "Wasted",
    weight = 1,
    aggression = {1.0, 1.5},
    speed = {14, 28},
    speedMode = "set",
    driveInLane = "off",
    avoidCars = "off",
    params = {
      awarenessForceCoef = 0.1,
      turnForceCoef = 0.3,
      lookAheadKv = 0.3,
      trafficWaitTime = 0.5,
    },
    steerWobble = {amp = 0.2, freq1 = 1.5, freq2 = 0.6},
  },
  {
    name = "Speed Demon",
    weight = 2,
    aggression = {1.2, 1.5},
    speed = {30, 45},
    speedMode = "set",
    driveInLane = "on",
    avoidCars = "on",
  },
}

local vehiclePersonas = {}

local totalWeight = 0
for _, p in ipairs(personas) do
  totalWeight = totalWeight + p.weight
end

-- Store defaults before settings load
local defaultWeights = {}
for i, p in ipairs(personas) do
  defaultWeights[i] = p.weight
end

-- Settings persistence
local settingsPath = 'settings/drunk_driver/settings.json'

local function recalcTotalWeight()
  totalWeight = 0
  for _, p in ipairs(personas) do
    totalWeight = totalWeight + p.weight
  end
end

local function saveSettings()
  local data = {}
  for _, p in ipairs(personas) do
    data[p.name] = p.weight
  end
  jsonWriteFile(settingsPath, data, true)
  log('W', 'drunk_driver', 'Settings saved')
end

local function loadSettings()
  local data = jsonReadFile(settingsPath)
  if not data then return end
  for _, p in ipairs(personas) do
    if data[p.name] then
      p.weight = data[p.name]
    end
  end
  recalcTotalWeight()
  log('W', 'drunk_driver', 'Settings loaded')
end

-- UI state
local showUI = false
local weightPtrs = nil

local function initWeightPtrs()
  weightPtrs = {}
  for i, p in ipairs(personas) do
    weightPtrs[i] = im.IntPtr(p.weight)
  end
end

local function toggleSettings()
  showUI = not showUI
  if showUI then
    if not weightPtrs then initWeightPtrs() end
    for i, p in ipairs(personas) do
      weightPtrs[i][0] = p.weight
    end
  end
end

local function renderSettingsWindow()
  if not showUI then return end
  if not weightPtrs then initWeightPtrs() end

  im.SetNextWindowSize(im.ImVec2(400, 0), im.Cond_FirstUseEver)
  local open = im.BoolPtr(true)
  if im.Begin("Drunk Driver Settings", open) then
    im.Text("Adjust how often each persona appears in traffic.")
    im.Separator()

    local changed = false
    for i, p in ipairs(personas) do
      if im.SliderInt(p.name .. "##weight", weightPtrs[i], 0, 100) then
        p.weight = weightPtrs[i][0]
        changed = true
      end
      local pct = totalWeight > 0 and (p.weight / totalWeight * 100) or 0
      im.SameLine()
      im.Text(string.format("%.1f%%", pct))
    end

    if changed then
      recalcTotalWeight()
    end

    im.Separator()

    if im.Button("Save") then
      saveSettings()
    end
    im.SameLine()
    if im.Button("Reset Defaults") then
      for i, p in ipairs(personas) do
        p.weight = defaultWeights[i]
        weightPtrs[i][0] = defaultWeights[i]
      end
      recalcTotalWeight()
    end
    im.SameLine()
    if im.Button("Reassign All Traffic") then
      vehiclePersonas = {}
    end
  end
  im.End()

  if not open[0] then
    showUI = false
  end
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
      local _origUpdateGFX = updateGFX
      updateGFX = function(dt)
        if _origUpdateGFX then _origUpdateGFX(dt) end
        _dd_steer.t = _dd_steer.t + dt
        local w = math.sin(_dd_steer.t * _dd_steer.f1 * 6.283) * _dd_steer.amp
                + math.sin(_dd_steer.t * _dd_steer.f2 * 6.283) * _dd_steer.amp * 0.5
        local steerVal = electrics.values.steering_input or electrics.values.steering or 0
        electrics.values.steering_input = steerVal + w
        electrics.values.steering = (electrics.values.steering or 0) + w
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
  log('W', 'drunk_driver', string.format('Vehicle %d assigned persona: %s (aggression=%.2f, speed=%.1f, aiMode=%s)',
    vid, persona.name, data.aggression, data.speed, tostring(data.aiMode or "traffic")))
  return data
end

local function applyPersona(vid, data)
  local veh = be:getObjectByID(vid)
  if not veh then
    vehiclePersonas[vid] = nil
    return
  end
  veh:queueLuaCommand(data.vluaCmd)
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
  renderSettingsWindow()
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

local function setupKeybind()
  local am = scenetree.findObject("DrunkDriverActionMap")
  if not am then
    am = createObject("ActionMap")
    am:registerObject("DrunkDriverActionMap")
  end
  am:bindCmd("keyboard", "lctrl+lalt+lshift+d", "extensions.drunk_driver.toggleSettings()", "")
  am:push()
end

local function onExtensionLoaded()
  loadSettings()
  setupKeybind()
  log('W', 'drunk_driver', 'Drunk Driver mod loaded - traffic personas active (Ctrl+Alt+Shift+D for settings)')
  adoptExistingTraffic()
end

local function onInit()
  log('W', 'drunk_driver', 'Drunk Driver mod initialized')
  adoptExistingTraffic()
end

local function getVehiclePersona(vid)
  return vehiclePersonas[vid]
end

local function listPersonas()
  for _, p in ipairs(personas) do
    log('W', 'drunk_driver', string.format('  %s (weight: %d, aggression: %.1f-%.1f, speed: %.0f-%.0f m/s, aiMode=%s)',
      p.name, p.weight, p.aggression[1], p.aggression[2], p.speed[1], p.speed[2], tostring(p.aiMode or "traffic")))
  end
end

M.onInit = onInit
M.onExtensionLoaded = onExtensionLoaded
M.onUpdate = onUpdate
M.onPreRender = onPreRender
M.onVehicleSpawned = onVehicleSpawned
M.onVehicleDestroyed = onVehicleDestroyed
M.onTrafficStarted = onTrafficStarted
M.getVehiclePersona = getVehiclePersona
M.toggleSettings = toggleSettings
M.listPersonas = listPersonas

return M
