-- VR tutorial (2026-11-13): image pages explaining the VR controls, the Hellraiser profile's vr_tutorial.lua ported to
-- Cronos (libs/tutorial.lua = jbusfield's Atomic Heart lib + the Hellraiser gate option + a Cronos slot-0 guard).
-- Pages: data/tutorial/intro.png + 1.png .. N.png (counted at runtime), icons data/tutorial/buttons/. They are rendered
-- from the Cronos art by UnrealVRMod\0. Cronos Tutorial\make_pages.ps1.
--
--   * First start: shown once at the first level, and the intro waits until the player has done the open gesture once
--     (forceInteractionAtStartup). Finishing it ("Done" on the last page) or "Hide at startup" stops the automatic
--     show; data/tutorial_state.json remembers that, the gesture and the last page.
--   * Any time: left controller up to the eyes + left trigger opens it again at the saved page (libs/gestures
--     EYESCRATCH: within 15 cm in front of the HMD). The trigger has to be PULLED there: an aim (LT) that is already
--     held when the hand passes the eyes never opens it. Not during cutscenes / vents / ladders / wall walking, while
--     two-handing, or while the game is paused or shows a mouse cursor (menus). A refused pull reaches the game as usual.
--   * While open: every button is kept from the game and the other scripts (A next / start / done, X back, B close,
--     Y hide at startup) and the game is paused (panel option).
--   * UI placement: Cronos keeps UEVR's UI head-locked (config UI_FollowView=true, offset right/down for the HUD), and
--     libs/ui.lua is not set up in this profile, so the lib's ui.lua view lock is off (lockView = false: clearing it
--     would turn UEVR's follow-view off for good). A world-locked page would also need a recenter, which snaps the view
--     under roomscale turning. So the page stays head-locked and is only moved while open: UI_X_Offset /
--     UI_Y_Offset are set to 0.213 / 0 on open and the exact previous values are restored on close.
-- Panel section "VR Tutorial": show now, gesture on/off, pause on/off, show again at the next start.

local uevrUtils = require('libs/uevr_utils')
local configui = require('libs/configui')
local tutorial = require('libs/tutorial')

_G.CRONOS_SECTIONS = _G.CRONOS_SECTIONS or {}
table.insert(_G.CRONOS_SECTIONS, { order = 6.7, label = "VR Tutorial", layout = {
	{ widgetType = "button", id = "tut_show", label = "Show the VR tutorial", size = {220, 24} },
	{ widgetType = "checkbox", id = "tut_gesture", label = "Open it with the left trigger at your eyes", initialValue = true },
	{ widgetType = "checkbox", id = "tut_pause", label = "Pause the game while it is open", initialValue = true },
	{ widgetType = "button", id = "tut_reset", label = "Show it again at the next start", size = {260, 24} },
	{ widgetType = "text", id = "tut_status", label = "" },
}})

local function enabled(id)
	return configui.getValue(id) ~= false -- nil until the panel exists: the initial value (true)
end

local function call(fn)
	if type(fn) ~= "function" then return false end
	local ok, result = pcall(fn)
	return ok and result == true
end

-- Rising edge of the left trigger, from the raw pad before the tutorial's gesture check (priority 100001) and every
-- other handler. gestures.lua's face detector uses the same threshold (face.triggerThreshold 128).
local TRIGGER_THRESHOLD = 128
local leftTriggerWasDown = false
local leftTriggerPulled = false
uevrUtils.registerOnPreInputGetStateCallback(function(retval, userIndex, state)
	if userIndex ~= nil and userIndex ~= 0 then return end
	local down = state.Gamepad.bLeftTrigger > TRIGGER_THRESHOLD
	leftTriggerPulled = down and not leftTriggerWasDown
	leftTriggerWasDown = down
end, 100002)

local function isPausedOrMenu()
	local ok, result = pcall(function()
		local world = uevrUtils.get_world()
		if Statics ~= nil and world ~= nil and Statics:IsGamePaused(world) then return true end
		local pc = uevr.api:get_player_controller(0)
		return pc ~= nil and pc.bShowMouseCursor == true
	end)
	return ok and result == true
end

-- false while the left trigger near the eyes belongs to something else (asked only once the gesture is detected)
local function gestureAllowed()
	if not enabled("tut_gesture") then return false end
	if not leftTriggerPulled then return false end
	if call(_G.cronosIsCutscene) then return false end
	if _G.isTwoHandingActive == true then return false end
	if isPausedOrMenu() then return false end
	return true
end

-- Place the head-locked UI for the tutorial while it is open (see the header): a little right of centre, level
local UI_OFFSET_KEYS = { "UI_X_Offset", "UI_Y_Offset" }
local TUTORIAL_OFFSETS = { UI_X_Offset = "0.213000", UI_Y_Offset = "0.000000" }
local savedOffsets = nil

local function centreUI()
	if savedOffsets ~= nil then return end
	local ok = pcall(function()
		local saved = {}
		for _, key in ipairs(UI_OFFSET_KEYS) do saved[key] = uevr.params.vr:get_mod_value(key) end
		savedOffsets = saved
		for _, key in ipairs(UI_OFFSET_KEYS) do uevr.params.vr.set_mod_value(key, TUTORIAL_OFFSETS[key]) end
	end)
	if not ok then savedOffsets = nil end
end

local function restoreUI()
	if savedOffsets == nil then return end
	local saved = savedOffsets
	savedOffsets = nil
	for _, key in ipairs(UI_OFFSET_KEYS) do
		if saved[key] ~= nil then pcall(function() uevr.params.vr.set_mod_value(key, saved[key]) end) end
	end
end

local t = tutorial.new({
	imageSize = 1536,
	pauseGame = enabled("tut_pause"),
	lockView = false,
	disableControllerMouse = false,
	buttons = { start = "A", next = "A", done = "A", back = "X", close = "B", skip = "B", hideAtStartup = "Y" },
	openGestureCondition = gestureAllowed,
	onOpen = function() centreUI() end,
	onClose = function() restoreUI() end,
})
t:forceInteractionAtStartup(true)
t:showOnce()

-- the lib's own script-reset teardown skips onClose
uevr.params.sdk.callbacks.on_script_reset(restoreUI)

local function updateStatus()
	configui.setLabel("tut_status", t:isCompleted() and "Shown at start: no (finished or hidden)" or "Shown at start: yes")
end

-- Panel buttons run while UEVR draws its overlay: widgets are made on the next engine tick instead
local pending = nil
configui.onUpdate("tut_show", function() pending = "show" end)
configui.onUpdate("tut_reset", function() pending = "reset" end)
configui.onCreateOrUpdate("tut_pause", function(value) t.options.pauseGame = value ~= false end)

uevrUtils.registerPreEngineTickCallback(function()
	if pending == nil then return end
	local action = pending
	pending = nil
	if action == "show" then
		t:show(t:getSavedPage() or 1)
	elseif action == "reset" then
		t:resetCompleted()
		t:resetInteraction()
		t:resetSavedPage()
	end
	updateStatus()
end)

uevrUtils.setTimeout(1000, updateStatus)
