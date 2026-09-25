local mq = require('mq')
local ImGui = require('ImGui')

local BUILDID = 'v1.0.0'
local UI_TITLE = 'PTDeathRecovery ' .. BUILDID

local STATE = {
    MONITORING = 'MONITORING',
    WAIT_BAZAAR = 'WAIT_BAZAAR',
    NAVIGATE_MAP = 'NAVIGATE_MAP',
    OPEN_MAP = 'OPEN_MAP',
    TRAVEL_EXPEDITION = 'TRAVEL_EXPEDITION',
    WAIT_ZONE_START = 'WAIT_ZONE_START',
    WAIT_ZONE_FINISH = 'WAIT_ZONE_FINISH',
    WAIT_TAC_READY = 'WAIT_TAC_READY',
    CHECK_TAC = 'CHECK_TAC',
    START_TAC = 'START_TAC',
}

local C = {
    bazaarShortName = 'bazaar',
    mapY = -644.09,
    mapX = 6.47,
    mapZ = 4.12,
    mapSwitchId = 146,
    waypointWindow = 'WaypointsWnd',
    expeditionButton = 'MyExpeditionButton',
    waitBazaarMs = 120000,
    navigationMs = 30000,
    mapOpenMs = 5000,
    zoneStartMs = 10000,
    zoneFinishMs = 120000,
    tacStatusMs = 5000,
    stableSampleMs = 500,
    retrySpacingMs = 1000,
    navActivationGraceMs = 2000,
    targetAcquireMs = 1000,
    tacReadinessProbeSpacingMs = 500,
    tacStartSettleMs = 2000,
    logMaxBytes = 1024 * 1024,
}

local app = {
    running = true,
    windowOpen = true,
    paused = false,
    pauseStartedAt = nil,
    state = STATE.MONITORING,
    stateEnteredAt = mq.gettime(),
    ctx = {},
    recoveryId = 0,
    retryCount = 5,
    lockedRetryCount = nil,
    verboseMQ = false,
    attempts = {},
    lastResult = 'None this session.',
    canaries = {},
    zoneCanaries = {},
    tacStatus = nil,
    tacQueryActive = false,
    navOwned = false,
    expeditionZoneId = nil,
    identityReady = false,
    serverName = nil,
    characterName = nil,
    settingsPath = nil,
    logPath = nil,
    logFile = nil,
}

local function now()
    return mq.gettime()
end

local function trim(value)
    return tostring(value or ''):match('^%s*(.-)%s*$')
end

local function lower(value)
    return string.lower(trim(value))
end

local function safeCall(fn)
    local ok, value = pcall(fn)
    if ok then return value end
    return nil
end

local function sanitizeFilePart(value)
    value = trim(value)
    value = value:gsub('[<>:"/\\|%?%*]', '_'):gsub('%s+', '_')
    if value == '' then value = 'unknown' end
    return value
end

local function pathJoin(base, name)
    base = tostring(base or '')
    if base:sub(-1) == '\\' or base:sub(-1) == '/' then return base .. name end
    return base .. '\\' .. name
end

local function rotateLogIfNeeded()
    if not app.logPath then return end
    local size = 0
    if app.logFile then
        app.logFile:flush()
        size = app.logFile:seek('end') or 0
    else
        local file = io.open(app.logPath, 'rb')
        if not file then return end
        size = file:seek('end') or 0
        file:close()
    end
    if size < C.logMaxBytes then return end

    if app.logFile then app.logFile:close(); app.logFile = nil end
    local backup = app.logPath .. '.1'
    os.remove(backup)
    os.rename(app.logPath, backup)
end

local function writeLog(level, message)
    if not app.logPath then return end
    rotateLogIfNeeded()
    if not app.logFile then app.logFile = io.open(app.logPath, 'a') end
    if not app.logFile then return end
    local line = string.format('%s | %s | build=%s | recovery=%s | state=%s | %s\n',
        os.date('%Y-%m-%d %H:%M:%S'), level, BUILDID,
        app.recoveryId > 0 and tostring(app.recoveryId) or '-', app.state, message)
    app.logFile:write(line)
    app.logFile:flush()
end

local function log(level, fmt, ...)
    local ok, message = pcall(string.format, fmt, ...)
    if not ok then message = tostring(fmt) end
    writeLog(level, message)
    if app.verboseMQ then print(string.format('[%s] %s', BUILDID, message)) end
end

local function announce(message)
    writeLog('INFO', message)
    print(string.format('[%s] %s', BUILDID, message))
end

local function currentGameState()
    return safeCall(function() return mq.TLO.EverQuest.GameState() end)
end

local function currentZoneId()
    local value = safeCall(function() return mq.TLO.Zone.ID() end)
    value = tonumber(value)
    if value and value > 0 then return value end
    return nil
end

local function currentZoneShort()
    return safeCall(function() return mq.TLO.Zone.ShortName() end)
end

local function currentZoneNames()
    local names = {}
    local function add(value)
        value = trim(value)
        if value ~= '' then names[#names + 1] = value end
    end
    add(safeCall(function() return mq.TLO.Zone.ShortName() end))
    add(safeCall(function() return mq.TLO.Zone.Name() end))
    add(safeCall(function() return mq.TLO.Zone.LongName() end))
    return names
end

local function currentMeId()
    local value = tonumber(safeCall(function() return mq.TLO.Me.ID() end))
    if value and value > 0 then return value end
    return nil
end

local function isInGameUsable()
    return currentGameState() == 'INGAME' and currentZoneId() ~= nil and currentMeId() ~= nil
end

local function isBazaarUsable()
    return isInGameUsable() and lower(currentZoneShort()) == C.bazaarShortName
end

local function currentPosition()
    local y = tonumber(safeCall(function() return mq.TLO.Me.Y() end))
    local x = tonumber(safeCall(function() return mq.TLO.Me.X() end))
    local z = tonumber(safeCall(function() return mq.TLO.Me.Z() end))
    if not y or not x or not z then return nil end
    return y, x, z
end

local function mapDistance()
    local y, x, z = currentPosition()
    if not y then return nil end
    local dy, dx, dz = y - C.mapY, x - C.mapX, z - C.mapZ
    return math.sqrt(dy * dy + dx * dx + dz * dz)
end

local function windowOpen(name)
    return safeCall(function() return mq.TLO.Window(name).Open() end) == true
end

local function childExists(windowName, childName)
    local value = safeCall(function() return mq.TLO.Window(windowName).Child(childName)() end)
    return value ~= nil and tostring(value) ~= 'NULL'
end

local function expeditionButtonEnabled()
    return safeCall(function()
        return mq.TLO.Window(C.waypointWindow).Child(C.expeditionButton).Enabled()
    end)
end

local function navActive()
    return safeCall(function() return mq.TLO.Navigation.Active() end) == true
end

local function navMeshLoaded()
    return safeCall(function() return mq.TLO.Navigation.MeshLoaded() end) == true
end

local function navPathExists()
    local spec = string.format('locyxz %.2f %.2f %.2f', C.mapY, C.mapX, C.mapZ)
    return safeCall(function() return mq.TLO.Navigation.PathExists(spec)() end) == true
end

local function stopNavigation(reason)
    if not app.navOwned then return end
    if navActive() then
        mq.cmd('/nav stop')
        log('ACTION', 'Issued /nav stop (%s).', reason or 'unspecified')
    end
    app.navOwned = false
end

local function stateElapsed()
    return now() - app.stateEnteredAt
end

local function maxAttempts()
    return (app.lockedRetryCount or app.retryCount) + 1
end

local function attemptFor(key)
    return app.attempts[key] or 0
end

local function enterState(newState, reason, context)
    local oldState = app.state
    app.state = newState
    app.stateEnteredAt = now()
    app.ctx = context or {}
    log('STATE', '%s -> %s; reason=%s', oldState, newState, reason or 'not specified')
end

local function saveSettings()
    if not app.settingsPath then return end
    local file = io.open(app.settingsPath, 'w')
    if not file then
        log('ERROR', 'Unable to write settings file: %s', app.settingsPath)
        return
    end
    file:write(string.format('RetryCount=%d\n', math.max(0, math.floor(app.retryCount))))
    file:write(string.format('VerboseMQOutput=%s\n', app.verboseMQ and 'true' or 'false'))
    file:close()
    log('SETTINGS', 'Saved RetryCount=%d VerboseMQOutput=%s', app.retryCount, tostring(app.verboseMQ))
end

local function loadSettings()
    if not app.settingsPath then return end
    local file = io.open(app.settingsPath, 'r')
    if not file then return end
    for line in file:lines() do
        local key, value = line:match('^([^=]+)=(.*)$')
        if key == 'RetryCount' then
            local parsed = tonumber(value)
            if parsed and parsed >= 0 then app.retryCount = math.floor(parsed) end
        elseif key == 'VerboseMQOutput' then
            app.verboseMQ = lower(value) == 'true'
        end
    end
    file:close()
end

local function initializeIdentity()
    if app.identityReady then return true end
    local server = safeCall(function() return mq.TLO.EverQuest.ServerName() end)
    if not server or trim(server) == '' then
        server = safeCall(function() return mq.TLO.MacroQuest.Server() end)
    end
    local character = safeCall(function() return mq.TLO.Me.CleanName() end)
    if not server or trim(server) == '' or not character or trim(character) == '' then return false end

    app.serverName = tostring(server)
    app.characterName = tostring(character)
    local stem = sanitizeFilePart(app.serverName) .. '_' .. sanitizeFilePart(app.characterName)
    local configDir = safeCall(function() return mq.TLO.MacroQuest.Path('config')() end) or mq.configDir
    local logDir = safeCall(function() return mq.TLO.MacroQuest.Path('logs')() end) or mq.logDir
    app.settingsPath = pathJoin(configDir, 'PTDeathRecovery_' .. stem .. '.ini')
    app.logPath = pathJoin(logDir, 'PTDeathRecovery_' .. stem .. '.log')
    app.identityReady = true
    loadSettings()
    writeLog('STARTUP', string.format('Started %s; server=%s; character=%s; settings=%s; log=%s',
        BUILDID, app.serverName, app.characterName, app.settingsPath, app.logPath))
    announce('Monitoring - waiting for death.')
    return true
end

local function clearRecoveryEvidence()
    app.canaries = {}
    app.zoneCanaries = {}
    app.tacStatus = nil
    app.tacQueryActive = false
    app.expeditionZoneId = nil
end

local function returnToMonitoring(result)
    stopNavigation('returning to Monitoring')
    app.paused = false
    app.pauseStartedAt = nil
    app.lockedRetryCount = nil
    app.attempts = {}
    clearRecoveryEvidence()
    enterState(STATE.MONITORING, result)
end

local function failRecovery(stage, reason)
    local message = string.format('Recovery failed at %s: %s', stage, reason)
    app.lastResult = message
    writeLog('FAILURE', message)
    print(string.format('[%s] %s', BUILDID, message))
    returnToMonitoring(message)
end

local function succeedRecovery()
    local message = 'Recovery successful: returned to expedition and TAC is running.'
    app.lastResult = message
    writeLog('SUCCESS', message)
    print(string.format('[%s] %s', BUILDID, message))
    returnToMonitoring(message)
end

local function beginRecovery(reason, keepPaused)
    stopNavigation('new recovery attempt')
    app.recoveryId = app.recoveryId + 1
    app.lockedRetryCount = app.retryCount
    app.attempts = {}
    clearRecoveryEvidence()
    if keepPaused then app.pauseStartedAt = now() end
    enterState(STATE.WAIT_BAZAAR, reason, { stableSince = nil })
    writeLog('RECOVERY', string.format('Recovery attempt %d began; retry_count=%d; paused=%s; reason=%s',
        app.recoveryId, app.lockedRetryCount, tostring(keepPaused), reason))
    if not keepPaused then announce(string.format('Recovery attempt %d started.', app.recoveryId)) end
end

local function onDeath(line)
    log('EVENT', 'Recognized death event: %s', tostring(line))
    if app.state == STATE.MONITORING then
        if app.paused then
            log('EVENT', 'Death ignored because Monitoring is paused.')
            return
        end
        beginRecovery('recognized death while Monitoring', false)
        return
    end

    local wasPaused = app.paused
    beginRecovery('recognized re-death invalidated active recovery', wasPaused)
    if wasPaused then
        writeLog('RECOVERY', 'Underlying recovery reset to WAIT_BAZAAR; explicit Pause remains in force.')
    end
end

local function normalizeZone(value)
    value = lower(value)
    value = value:gsub('[^%w]+', ' '):gsub('%s+', ' ')
    return trim(value)
end

local function canaryMatchesCurrentZone(canary)
    local reported = normalizeZone(canary.zone)
    if reported == '' then return false end
    for _, name in ipairs(currentZoneNames()) do
        if normalizeZone(name) == reported then return true end
    end
    return false
end

local function onTacCanary(line, zone, count)
    if app.state == STATE.MONITORING or not app.lockedRetryCount then return end
    local entry = {
        line = tostring(line or ''),
        zone = trim(zone),
        count = tonumber(count),
        receivedAt = now(),
        recoveryId = app.recoveryId,
    }
    app.canaries[#app.canaries + 1] = entry
    log('EVENT', 'TAC canary captured: zone=%q waypoints=%s', entry.zone, tostring(entry.count))
end

local function onTacZoneCanary(line, kind)
    if app.state == STATE.MONITORING or not app.lockedRetryCount then return end
    app.zoneCanaries[#app.zoneCanaries + 1] = {
        kind = kind,
        receivedAt = now(),
        recoveryId = app.recoveryId,
    }
    log('EVENT', 'TAC zoning canary captured: kind=%s', tostring(kind))
end

local function onTacZonePaused(line)
    onTacZoneCanary(line, 'pause_on_zone')
end

local function onTacZoneContinuing(line)
    onTacZoneCanary(line, 'continue_on_zone')
end

local function onTacStatus(line, runningState, mode, burn)
    if not app.tacQueryActive then
        writeLog('EVENT', string.format('Ignored unsolicited TAC status response without MQ echo; state=%s mode=%s burn=%s',
            lower(runningState), trim(mode), trim(burn)))
        return
    end
    app.tacStatus = {
        state = lower(runningState),
        mode = trim(mode),
        burn = trim(burn),
        receivedAt = now(),
        line = tostring(line or ''),
    }
    app.tacQueryActive = false
    log('OBSERVE', 'TAC status response: state=%s mode=%s burn=%s',
        app.tacStatus.state, app.tacStatus.mode, app.tacStatus.burn)
end

mq.event('PTDRDeathSlain', 'You have been slain by #*#!', onDeath)
mq.event('PTDRDeathDied', 'You died.', onDeath)
mq.event('PTDRTacCanary', '#*#[Triune] Loaded saved waypoint route for #1# (#2# waypoint(s)).#*#', onTacCanary)
mq.event('PTDRTacZonePaused', '#*#[Triune] zoned -- pausing autocombat.#*#', onTacZonePaused)
mq.event('PTDRTacZoneContinuing', '#*#[Triune] zoned -- continuing autocombat (pause on zone disabled).#*#', onTacZoneContinuing)
mq.event('PTDRTacStatus', '#*#[Triune] status: #1#, mode: #2#, burn: #3##*#', onTacStatus)

local function startNavigationAttempt()
    local attempt = attemptFor('navigation') + 1
    app.attempts.navigation = attempt
    if attempt > maxAttempts() then
        failRecovery('navigation', string.format('navigation attempts exhausted after %d total attempts', maxAttempts()))
        return
    end
    if not isBazaarUsable() then
        failRecovery('navigation', 'character is no longer in a usable Bazaar state')
        return
    end
    if not navMeshLoaded() then
        failRecovery('navigation', 'MQ2Nav is unavailable or the Bazaar navmesh is not loaded')
        return
    end
    if not navPathExists() then
        log('OBSERVE', 'Navigation attempt %d has no confirmed path to the waypoint map.', attempt)
        enterState(STATE.NAVIGATE_MAP, 'navigation path unavailable; waiting to retry', {
            phase = 'retry_wait', retryAt = now() + C.retrySpacingMs,
        })
        return
    end

    local command = string.format('/nav locyxz %.2f %.2f %.2f', C.mapY, C.mapX, C.mapZ)
    app.navOwned = true
    mq.cmd(command)
    enterState(STATE.NAVIGATE_MAP, string.format('navigation attempt %d issued', attempt), {
        phase = 'moving', commandAt = now(), seenActive = navActive(),
    })
    log('ACTION', 'Navigation attempt %d/%d command=%s', attempt, maxAttempts(), command)
end

local function startMapOpenAttempt()
    if windowOpen(C.waypointWindow) then
        enterState(STATE.TRAVEL_EXPEDITION, 'waypoint window already open')
        return
    end
    local attempt = attemptFor('open_map') + 1
    app.attempts.open_map = attempt
    if attempt > maxAttempts() then
        failRecovery('opening waypoint map', string.format('map-opening attempts exhausted after %d total attempts', maxAttempts()))
        return
    end
    local switchId = tonumber(safeCall(function() return mq.TLO.Switch(C.mapSwitchId).ID() end))
    if switchId ~= C.mapSwitchId then
        log('OBSERVE', 'Map-opening attempt %d cannot observe switch ID %d.', attempt, C.mapSwitchId)
        enterState(STATE.OPEN_MAP, 'switch unavailable; waiting to retry', {
            phase = 'retry_wait', retryAt = now() + C.retrySpacingMs,
        })
        return
    end
    mq.cmdf('/doortarget id %d', C.mapSwitchId)
    enterState(STATE.OPEN_MAP, string.format('map-opening attempt %d targeting switch', attempt), {
        phase = 'targeting', targetDeadline = now() + C.targetAcquireMs,
    })
    log('ACTION', 'Map-opening attempt %d/%d issued /doortarget id %d; distance_to_nav_target=%s',
        attempt, maxAttempts(), C.mapSwitchId, tostring(mapDistance()))
end

local function beginTravelAttempt()
    if not windowOpen(C.waypointWindow) then
        log('OBSERVE', 'WaypointsWnd is not open before the next expedition-travel attempt; reopening it without spending a travel attempt.')
        enterState(STATE.OPEN_MAP, 'waypoint window must be reopened before expedition-travel retry')
        startMapOpenAttempt()
        return
    end
    local attempt = attemptFor('travel') + 1
    app.attempts.travel = attempt
    if attempt > maxAttempts() then
        failRecovery('expedition travel', string.format('travel attempts exhausted after %d total attempts', maxAttempts()))
        return
    end
    if not childExists(C.waypointWindow, C.expeditionButton) then
        failRecovery('expedition travel', 'MyExpeditionButton could not be observed')
        return
    end
    local enabled = expeditionButtonEnabled()
    if enabled == false then
        failRecovery('expedition travel', 'no interactable current expedition is available (MyExpeditionButton.Enabled is false)')
        return
    elseif enabled ~= true then
        failRecovery('expedition travel', 'MyExpeditionButton.Enabled could not be read reliably')
        return
    end
    local originZoneId = currentZoneId()
    if not originZoneId then
        failRecovery('expedition travel', 'current Bazaar Zone.ID is unavailable')
        return
    end

    mq.flushevents('PTDRTacCanary')
    mq.flushevents('PTDRTacZonePaused')
    mq.flushevents('PTDRTacZoneContinuing')
    app.canaries = {}
    app.zoneCanaries = {}
    mq.cmdf('/notify %s %s leftmouseup', C.waypointWindow, C.expeditionButton)
    enterState(STATE.WAIT_ZONE_START, string.format('expedition travel attempt %d activated', attempt), {
        originZoneId = originZoneId,
        commandAt = now(),
    })
    log('ACTION', 'Expedition travel attempt %d/%d activated %s.%s; origin_zone_id=%d',
        attempt, maxAttempts(), C.waypointWindow, C.expeditionButton, originZoneId)
end

local function issueTacStatusQuery(reason)
    mq.flushevents('PTDRTacStatus')
    app.tacStatus = nil
    app.tacQueryActive = true
    app.ctx.queryAt = now()
    mq.cmd('/ac status')
    log('ACTION', 'Issued /ac status; reason=%s', reason)
end

local function startTacAttempt()
    local attempt = attemptFor('start_tac') + 1
    app.attempts.start_tac = attempt
    if attempt > maxAttempts() then
        failRecovery('starting TAC', string.format('TAC-start attempts exhausted after %d total attempts', maxAttempts()))
        return
    end
    mq.cmd('/ac run')
    enterState(STATE.START_TAC, string.format('TAC-start attempt %d issued', attempt), {
        phase = 'settle', runAt = now(),
    })
    log('ACTION', 'TAC-start attempt %d/%d issued /ac run; acknowledgement is not treated as proof.',
        attempt, maxAttempts())
end

local function tickWaitBazaar()
    if isBazaarUsable() then
        if not app.ctx.stableSince then
            app.ctx.stableSince = now()
            log('OBSERVE', 'Bazaar usable-state sample 1 observed.')
        elseif now() - app.ctx.stableSince >= C.stableSampleMs then
            log('OBSERVE', 'Bazaar usable-state sample 2 observed after %d ms.', now() - app.ctx.stableSince)
            startNavigationAttempt()
        end
    else
        app.ctx.stableSince = nil
    end
    if app.state == STATE.WAIT_BAZAAR and stateElapsed() >= C.waitBazaarMs then
        failRecovery('waiting for Bazaar', '120-second Bazaar-return timeout expired without a stable usable Bazaar state')
    end
end

local function tickNavigateMap()
    if app.ctx.phase == 'retry_wait' then
        if now() >= app.ctx.retryAt then startNavigationAttempt() end
        return
    end
    if not isBazaarUsable() then
        failRecovery('navigation', 'character left the usable Bazaar state during navigation')
        return
    end
    local active = navActive()
    if active then app.ctx.seenActive = true end
    if not active and (app.ctx.seenActive or now() - app.ctx.commandAt >= C.navActivationGraceMs) then
        app.navOwned = false
        local distance = mapDistance()
        log('OBSERVE', 'Navigation command ended; seen_active=%s final_distance=%.2f. Map usability will determine arrival success.',
            tostring(app.ctx.seenActive), distance or -1)
        enterState(STATE.OPEN_MAP, 'navigation command ended; testing functional map usability')
        startMapOpenAttempt()
        return
    end
    if stateElapsed() >= C.navigationMs then
        stopNavigation('navigation attempt timed out')
        log('TIMEOUT', 'Navigation attempt %d timed out after 30 seconds.', attemptFor('navigation'))
        if attemptFor('navigation') >= maxAttempts() then
            failRecovery('navigation', string.format('navigation attempts exhausted after %d total attempts', maxAttempts()))
        else
            enterState(STATE.NAVIGATE_MAP, 'navigation timeout; waiting to retry', {
                phase = 'retry_wait', retryAt = now() + C.retrySpacingMs,
            })
        end
    end
end

local function tickOpenMap()
    if windowOpen(C.waypointWindow) then
        log('OBSERVE', 'WaypointsWnd is open; functional map usability confirmed. distance_to_nav_target=%s', tostring(mapDistance()))
        enterState(STATE.TRAVEL_EXPEDITION, 'waypoint window confirmed open')
        return
    end
    if app.ctx.phase == 'retry_wait' then
        if now() >= app.ctx.retryAt then startMapOpenAttempt() end
        return
    end
    if app.ctx.phase == 'targeting' then
        local targetId = tonumber(safeCall(function() return mq.TLO.SwitchTarget.ID() end))
        if targetId == C.mapSwitchId then
            mq.cmd('/click left door')
            app.ctx.phase = 'waiting_window'
            app.ctx.windowDeadline = now() + C.mapOpenMs
            log('ACTION', 'Confirmed SwitchTarget.ID=%d; issued /click left door.', targetId)
        elseif now() >= app.ctx.targetDeadline then
            log('OBSERVE', 'Map-opening attempt %d failed to confirm SwitchTarget.ID=%d.',
                attemptFor('open_map'), C.mapSwitchId)
            app.ctx.phase = 'retry_wait'
            app.ctx.retryAt = now() + C.retrySpacingMs
        end
        return
    end
    if app.ctx.phase == 'waiting_window' and now() >= app.ctx.windowDeadline then
        log('TIMEOUT', 'Map-opening attempt %d did not open WaypointsWnd within 5 seconds; distance_to_nav_target=%s',
            attemptFor('open_map'), tostring(mapDistance()))
        if attemptFor('open_map') >= maxAttempts() then
            failRecovery('opening waypoint map', string.format('map-opening attempts exhausted after %d total attempts', maxAttempts()))
        else
            app.ctx.phase = 'retry_wait'
            app.ctx.retryAt = now() + C.retrySpacingMs
        end
    end
end

local function tickTravelExpedition()
    beginTravelAttempt()
end

local function tickWaitZoneStart()
    local gameState = currentGameState()
    local zoneId = currentZoneId()
    local reason
    if gameState and gameState ~= 'INGAME' then
        reason = 'EverQuest.GameState changed from INGAME to ' .. tostring(gameState)
    elseif zoneId and zoneId ~= app.ctx.originZoneId then
        reason = string.format('Zone.ID changed from %d to %d', app.ctx.originZoneId, zoneId)
    end
    if reason then
        local originZoneId = app.ctx.originZoneId
        log('OBSERVE', 'Expedition zoning start confirmed: %s', reason)
        enterState(STATE.WAIT_ZONE_FINISH, reason, { originZoneId = originZoneId, stableSince = nil })
        return
    end
    if stateElapsed() >= C.zoneStartMs then
        log('TIMEOUT', 'Expedition travel attempt %d did not produce zone-start confirmation within 10 seconds.',
            attemptFor('travel'))
        if attemptFor('travel') >= maxAttempts() then
            failRecovery('expedition travel', string.format('travel attempts exhausted after %d total attempts', maxAttempts()))
        else
            enterState(STATE.TRAVEL_EXPEDITION, 'zone start not confirmed; retrying expedition travel')
        end
    end
end

local function tickWaitZoneFinish()
    local zoneId = currentZoneId()
    local ready = currentGameState() == 'INGAME' and currentMeId() ~= nil
        and zoneId ~= nil and zoneId ~= app.ctx.originZoneId
    if ready then
        if not app.ctx.stableSince then
            app.ctx.stableSince = now()
            app.ctx.stableZoneId = zoneId
            log('OBSERVE', 'Expedition usable-state sample 1 observed: zone_id=%d.', zoneId)
        elseif app.ctx.stableZoneId ~= zoneId then
            app.ctx.stableSince = now()
            app.ctx.stableZoneId = zoneId
            log('OBSERVE', 'Zone.ID changed during stability check; restarting completion sample: zone_id=%d.', zoneId)
        elseif now() - app.ctx.stableSince >= C.stableSampleMs then
            log('OBSERVE', 'Expedition usable-state sample 2 observed: zone_id=%d names=%s.',
                zoneId, table.concat(currentZoneNames(), ' | '))
            app.expeditionZoneId = zoneId
            enterState(STATE.WAIT_TAC_READY, 'expedition zoning completed; establishing TAC readiness', {
                expeditionZoneId = zoneId,
            })
            return
        end
    else
        app.ctx.stableSince = nil
        app.ctx.stableZoneId = nil
    end
    if app.state == STATE.WAIT_ZONE_FINISH and stateElapsed() >= C.zoneFinishMs then
        failRecovery('waiting for expedition zoning to finish', '120-second zone-completion timeout expired without a stable usable expedition state')
    end
end

local function beginTacReadiness()
    local evidence
    for _, canary in ipairs(app.canaries) do
        if canary.recoveryId == app.recoveryId and not canary.checked then
            canary.checked = true
            if canaryMatchesCurrentZone(canary) then
                log('OBSERVE', 'Accepted matching TAC canary: zone=%q waypoints=%s.', canary.zone, tostring(canary.count))
                evidence = 'matching waypoint-route canary'
                break
            end
            log('OBSERVE', 'Rejected TAC canary for nonmatching zone=%q; current_names=%s.',
                canary.zone, table.concat(currentZoneNames(), ' | '))
        end
    end

    if not evidence then
        for _, canary in ipairs(app.zoneCanaries) do
            if canary.recoveryId == app.recoveryId then
                evidence = 'TAC zoning ' .. tostring(canary.kind) .. ' canary'
                log('OBSERVE', 'Accepted TAC zoning canary for readiness synchronization: kind=%s.', tostring(canary.kind))
                break
            end
        end
    end

    if evidence then
        app.ctx.phase = 'wait_single_probe'
        app.ctx.readinessEvidence = evidence
        issueTacStatusQuery('readiness probe after ' .. evidence)
    else
        log('OBSERVE', 'No TAC zone canary is available; using the two-probe readiness fallback.')
        app.ctx.phase = 'wait_probe_1'
        app.ctx.readinessEvidence = 'two-probe fallback'
        issueTacStatusQuery('readiness fallback probe 1; returned state will be ignored')
    end
end

local function enterTacStateCheck(readinessEvidence)
    log('OBSERVE', 'TAC readiness established: %s.', tostring(readinessEvidence))
    enterState(STATE.CHECK_TAC, 'TAC readiness established; querying actionable state', {
        phase = 'state_query', readinessEvidence = readinessEvidence,
    })
    issueTacStatusQuery('post-readiness state decision')
end

local function tickWaitTacReady()
    if not app.ctx.phase then
        beginTacReadiness()
        return
    end

    if app.ctx.phase == 'between_probes' then
        if now() >= app.ctx.nextProbeAt then
            app.ctx.phase = 'wait_probe_2'
            issueTacStatusQuery('readiness fallback probe 2; returned state will be ignored')
        end
        return
    end

    if app.tacStatus then
        local status = app.tacStatus
        app.tacStatus = nil
        if app.ctx.phase == 'wait_single_probe' then
            log('OBSERVE', 'Readiness probe answered; state=%s ignored for readiness.', tostring(status.state))
            enterTacStateCheck(app.ctx.readinessEvidence)
        elseif app.ctx.phase == 'wait_probe_1' then
            log('OBSERVE', 'Readiness fallback probe 1 answered; state=%s ignored.', tostring(status.state))
            app.ctx.phase = 'between_probes'
            app.ctx.nextProbeAt = now() + C.tacReadinessProbeSpacingMs
            app.ctx.queryAt = nil
        elseif app.ctx.phase == 'wait_probe_2' then
            log('OBSERVE', 'Readiness fallback probe 2 answered; state=%s ignored.', tostring(status.state))
            enterTacStateCheck(app.ctx.readinessEvidence)
        end
        return
    end

    if app.ctx.queryAt and now() - app.ctx.queryAt >= C.tacStatusMs then
        app.tacQueryActive = false
        failRecovery('establishing TAC readiness', 'TAC did not answer a readiness /ac status probe within 5 seconds')
    end
end

local function tickCheckTac()
    if app.tacStatus then
        local status = app.tacStatus
        app.tacStatus = nil
        if status.state == 'running' then
            succeedRecovery()
        elseif status.state == 'paused' then
            startTacAttempt()
        else
            failRecovery('checking TAC state', 'TAC returned an unrecognized running state: ' .. tostring(status.state))
        end
        return
    end
    if app.ctx.queryAt and now() - app.ctx.queryAt >= C.tacStatusMs then
        app.tacQueryActive = false
        failRecovery('checking TAC state', 'TAC did not answer /ac status within 5 seconds')
    end
end

local function tickStartTac()
    if app.ctx.phase == 'retry_wait' then
        if now() >= app.ctx.retryAt then startTacAttempt() end
        return
    end
    if app.ctx.phase == 'settle' and now() - app.ctx.runAt >= C.tacStartSettleMs then
        app.ctx.phase = 'verify'
        issueTacStatusQuery('verification after /ac run')
        return
    end
    if app.ctx.phase ~= 'verify' then return end
    if app.tacStatus then
        local status = app.tacStatus
        app.tacStatus = nil
        if status.state == 'running' then
            succeedRecovery()
            return
        end
        log('OBSERVE', 'TAC-start attempt %d verification returned state=%s.',
            attemptFor('start_tac'), tostring(status.state))
        if attemptFor('start_tac') >= maxAttempts() then
            failRecovery('starting TAC', string.format('TAC-start attempts exhausted after %d total attempts', maxAttempts()))
        else
            enterState(STATE.START_TAC, 'TAC not verified running; waiting to retry', {
                phase = 'retry_wait', retryAt = now() + C.retrySpacingMs,
            })
        end
        return
    end
    if app.ctx.queryAt and now() - app.ctx.queryAt >= C.tacStatusMs then
        app.tacQueryActive = false
        log('TIMEOUT', 'TAC-start attempt %d received no /ac status response within 5 seconds.', attemptFor('start_tac'))
        if attemptFor('start_tac') >= maxAttempts() then
            failRecovery('starting TAC', string.format('TAC-start attempts exhausted after %d total attempts', maxAttempts()))
        else
            enterState(STATE.START_TAC, 'TAC verification timed out; waiting to retry', {
                phase = 'retry_wait', retryAt = now() + C.retrySpacingMs,
            })
        end
        return
    end
end

local function validateResume()
    if app.state == STATE.MONITORING or app.state == STATE.WAIT_BAZAAR then return true end
    if app.state == STATE.NAVIGATE_MAP or app.state == STATE.OPEN_MAP or app.state == STATE.TRAVEL_EXPEDITION then
        if not isBazaarUsable() then return false, 'the character is no longer in a usable Bazaar state' end
        return true
    end
    if app.state == STATE.WAIT_ZONE_START then
        if not app.ctx.originZoneId then return false, 'the pre-travel Bazaar Zone.ID is unavailable' end
        return true
    end
    if app.state == STATE.WAIT_ZONE_FINISH then
        if isBazaarUsable() then return false, 'the character is back in the Bazaar after expedition zoning had begun' end
        return true
    end
    if app.state == STATE.WAIT_TAC_READY or app.state == STATE.CHECK_TAC or app.state == STATE.START_TAC then
        local expected = app.expeditionZoneId or app.ctx.expeditionZoneId
        if not isInGameUsable() then return false, 'the character is not in a usable in-game state' end
        if expected and currentZoneId() ~= expected then return false, 'the current zone no longer matches the expedition zone' end
        return true
    end
    return false, 'the suspended state is not recognized'
end

local function pauseApp()
    if app.paused then return end
    app.paused = true
    app.pauseStartedAt = now()
    if app.state == STATE.NAVIGATE_MAP then stopNavigation('PTDeathRecovery paused') end
    writeLog('PAUSE', 'Paused; suspended_state=' .. app.state)
end

local function resumeApp()
    if not app.paused then return end
    local pauseDuration = now() - (app.pauseStartedAt or now())
    local valid, reason = validateResume()
    if not valid then
        app.paused = false
        app.pauseStartedAt = nil
        failRecovery('resuming ' .. app.state, 'suspended context is no longer valid: ' .. tostring(reason))
        return
    end
    app.stateEnteredAt = app.stateEnteredAt + pauseDuration
    if app.ctx.queryAt then app.ctx.queryAt = app.ctx.queryAt + pauseDuration end
    if app.ctx.retryAt then app.ctx.retryAt = app.ctx.retryAt + pauseDuration end
    if app.ctx.targetDeadline then app.ctx.targetDeadline = app.ctx.targetDeadline + pauseDuration end
    if app.ctx.windowDeadline then app.ctx.windowDeadline = app.ctx.windowDeadline + pauseDuration end
    if app.ctx.stableSince then app.ctx.stableSince = app.ctx.stableSince + pauseDuration end
    if app.ctx.commandAt then app.ctx.commandAt = app.ctx.commandAt + pauseDuration end
    if app.ctx.runAt then app.ctx.runAt = app.ctx.runAt + pauseDuration end
    app.paused = false
    app.pauseStartedAt = nil
    if app.state == STATE.NAVIGATE_MAP and app.ctx.phase == 'moving' then
        local command = string.format('/nav locyxz %.2f %.2f %.2f', C.mapY, C.mapX, C.mapZ)
        app.navOwned = true
        mq.cmd(command)
        app.ctx.commandAt = now()
        app.ctx.seenActive = navActive()
        log('ACTION', 'Reissued navigation command after Resume without spending another attempt.')
    end
    writeLog('RESUME', 'Resumed; state=' .. app.state)
end

local STATE_LABEL = {
    [STATE.MONITORING] = 'Monitoring - waiting for death',
    [STATE.WAIT_BAZAAR] = 'Waiting for automatic return to The Bazaar',
    [STATE.NAVIGATE_MAP] = 'Navigating to waypoint map',
    [STATE.OPEN_MAP] = 'Opening waypoint map',
    [STATE.TRAVEL_EXPEDITION] = 'Initiating expedition travel',
    [STATE.WAIT_ZONE_START] = 'Waiting for expedition zoning to begin',
    [STATE.WAIT_ZONE_FINISH] = 'Waiting for expedition zoning to complete',
    [STATE.WAIT_TAC_READY] = 'Establishing TAC post-zone readiness',
    [STATE.CHECK_TAC] = 'Checking TAC running state',
    [STATE.START_TAC] = 'Starting and verifying TAC',
}

local function statusText()
    local text = STATE_LABEL[app.state] or app.state
    if app.state == STATE.NAVIGATE_MAP then
        text = string.format('%s - attempt %d of %d', text, attemptFor('navigation'), maxAttempts())
    elseif app.state == STATE.OPEN_MAP then
        text = string.format('%s - attempt %d of %d', text, attemptFor('open_map'), maxAttempts())
    elseif app.state == STATE.TRAVEL_EXPEDITION or app.state == STATE.WAIT_ZONE_START then
        text = string.format('Expedition travel - attempt %d of %d', attemptFor('travel'), maxAttempts())
    elseif app.state == STATE.START_TAC then
        text = string.format('%s - attempt %d of %d', text, attemptFor('start_tac'), maxAttempts())
    end
    if app.paused then return 'Paused - ' .. text end
    return text
end

local function drawUI()
    ImGui.SetNextWindowSize(460, 205, ImGuiCond.FirstUseEver)
    local open, show = ImGui.Begin(UI_TITLE, app.windowOpen, ImGuiWindowFlags.NoCollapse)
    app.windowOpen = open
    if not open then app.running = false end
    if show then
        if ImGui.Button(app.paused and 'Resume' or 'Pause', 90, 0) then
            if app.paused then resumeApp() else pauseApp() end
        end
        ImGui.SameLine()
        ImGui.TextWrapped('%s', statusText())
        ImGui.Separator()
        ImGui.Text('Last result/error:')
        ImGui.TextWrapped('%s', app.lastResult)
        ImGui.Separator()
        ImGui.Text('Settings')

        local settingsEditable = app.state == STATE.MONITORING
        if not settingsEditable then ImGui.BeginDisabled() end
        local newRetry = ImGui.InputInt('Retry Count', app.retryCount, 1, 5)
        if not settingsEditable then ImGui.EndDisabled() end
        if settingsEditable and newRetry ~= app.retryCount then
            newRetry = math.max(0, math.floor(tonumber(newRetry) or app.retryCount))
            app.retryCount = newRetry
            saveSettings()
        end

        local newVerbose = ImGui.Checkbox('Verbose MQ output', app.verboseMQ)
        if newVerbose ~= app.verboseMQ then
            app.verboseMQ = newVerbose == true
            saveSettings()
        end
    end
    ImGui.End()
end

mq.imgui.init(BUILDID, drawUI)

local function tickState()
    if app.state == STATE.MONITORING then return end
    if app.state == STATE.WAIT_BAZAAR then tickWaitBazaar()
    elseif app.state == STATE.NAVIGATE_MAP then tickNavigateMap()
    elseif app.state == STATE.OPEN_MAP then tickOpenMap()
    elseif app.state == STATE.TRAVEL_EXPEDITION then tickTravelExpedition()
    elseif app.state == STATE.WAIT_ZONE_START then tickWaitZoneStart()
    elseif app.state == STATE.WAIT_ZONE_FINISH then tickWaitZoneFinish()
    elseif app.state == STATE.WAIT_TAC_READY then tickWaitTacReady()
    elseif app.state == STATE.CHECK_TAC then tickCheckTac()
    elseif app.state == STATE.START_TAC then tickStartTac()
    end
end

while app.running do
    initializeIdentity()
    mq.doevents()
    if not app.paused then tickState() end
    mq.delay(50)
end

stopNavigation('Lua stopping')
mq.unevent('PTDRDeathSlain')
mq.unevent('PTDRDeathDied')
mq.unevent('PTDRTacCanary')
mq.unevent('PTDRTacZonePaused')
mq.unevent('PTDRTacZoneContinuing')
mq.unevent('PTDRTacStatus')
mq.imgui.destroy(BUILDID)
if app.logFile then
    writeLog('SHUTDOWN', 'Lua stopped.')
    app.logFile:close()
    app.logFile = nil
end

