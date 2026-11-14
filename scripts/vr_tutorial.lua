-- VR tutorial (2026-11-13): image pages explaining the VR controls, the Hellraiser profile's vr_tutorial.lua ported to
-- Cronos (libs/tutorial.lua = jbusfield's Atomic Heart lib + the Hellraiser gate option + a Cronos slot-0 guard).
-- Pages: data/tutorial/intro.png + 1.png .. N.png (counted at runtime), icons data/tutorial/buttons/. They are rendered
-- from the Cronos art by UnrealVRMod\0. Cronos Tutorial\make_pages.ps1.
--
--   * Startup (1.7): shown when gameplay is first reached (never in the main menu, see inGameplay), unless the panel
--     option "Show it when gameplay starts" (tut_startup) is off, at every start until the player closes it once
--     (B or the gesture). After that only the gesture opens it, in any session. Also stops when the player finishes
--     it ("Done" on the last page) or turns on "Hide at startup" (Y).
--     All intro buttons work at once (the old forced gesture wait is gone). data/tutorial_state.json remembers that,
--     the gesture and the last page. It is never shipped, and the launcher no longer carries it over, so every fresh
--     install or launcher update shows the tutorial again.
--   * Any time: left controller up to the eyes + left trigger opens it again at the saved page (libs/gestures
--     EYESCRATCH: within 15 cm in front of the HMD). The trigger has to be PULLED there: an aim (LT) that is already
--     held when the hand passes the eyes never opens it. Not during cutscenes / vents / ladders / wall walking, while
--     two-handing, or while the game is paused or shows a mouse cursor (menus). A refused pull reaches the game as usual.
--   * While open: every button is kept from the game and the other scripts (A next / start / done, X back, B close,
--     Y hide at startup) and the game is paused (panel option). The open gesture closes it again on any page
--     (gestureCloses), the same as B.
--   * UI placement: Cronos keeps UEVR's UI head-locked (config UI_FollowView=true, offset right/down for the HUD), and
--     libs/ui.lua is not set up in this profile, so the lib's ui.lua view lock is off (lockView = false: clearing it
--     would turn UEVR's follow-view off for good). A world-locked page would also need a recenter, which snaps the view
--     under roomscale turning. So the page stays head-locked and appears where UI_X_Offset / UI_Y_Offset 0.213 / 0
--     would put it, but the offsets are never written: the page moves inside its own widget instead (pageOffset
--     below). Writing them meant a UEVR config save while the tutorial was open stored the tutorial's offset as the
--     HUD's (happened 2026-11-13).
-- Panel section "VR Tutorial": show now, gesture on/off, pause on/off, show again at the next start.

local uevrUtils = require('libs/uevr_utils')
local configui = require('libs/configui')
local tutorial = require('libs/tutorial')

_G.CRONOS_SECTIONS = _G.CRONOS_SECTIONS or {}
table.insert(_G.CRONOS_SECTIONS, { order = 6.7, label = "VR Tutorial", layout = {
	{ widgetType = "button", id = "tut_show", label = "Show the VR tutorial", size = {220, 24} },
	{ widgetType = "checkbox", id = "tut_startup", label = "Show it when gameplay starts (until closed once)", initialValue = true },
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

-- Where the page appears, in UEVR UI offset metres (see the header): a little right of centre, level
local PAGE_UI_OFFSET_X = 0.213
local PAGE_UI_OFFSET_Y = 0.0

-- UEVR moves the whole UI quad by UI_X_Offset / UI_Y_Offset metres along its right / up axes (OverlayComponent),
-- and the quad is UI_Size metres tall for the full viewport height. So moving the page by (target - current) metres
-- is (target - current) / UI_Size viewport heights inside the widget (Slate y points down, UEVR's up axis up).
-- Read at every page layout, so the HUD offset can change in between.
local function pageOffset()
	local ok, x, y = pcall(function()
		local vr = uevr.params.vr
		local currentX = tonumber(vr:get_mod_value("UI_X_Offset")) or 0
		local currentY = tonumber(vr:get_mod_value("UI_Y_Offset")) or 0
		local size = tonumber(vr:get_mod_value("UI_Size")) or 0
		if size <= 0 or WidgetLayoutLibrary == nil then return 0, 0 end
		local world = uevrUtils.get_world()
		local viewport = WidgetLayoutLibrary:GetViewportSize(world)
		local scale = WidgetLayoutLibrary:GetViewportScale(world)
		if viewport == nil or scale == nil or scale <= 0 then return 0, 0 end
		local height = viewport.Y / scale
		return (PAGE_UI_OFFSET_X - currentX) / size * height, -(PAGE_UI_OFFSET_Y - currentY) / size * height
	end)
	if not ok then return 0, 0 end
	return x or 0, y or 0
end

-- true while the tutorial on screen is the automatic startup one: closing that one stops the startup show
local startupShow = false
-- true until the startup tutorial has been shown in gameplay this session (see inGameplay below)
local startupPending = false

local t = tutorial.new({
	imageSize = 1536,
	pauseGame = enabled("tut_pause"),
	lockView = false,
	disableControllerMouse = false,
	buttons = { start = "A", next = "A", done = "A", back = "X", close = "B", skip = "B", hideAtStartup = "Y" },
	labels = { close = "Close (or gesture)" },
	openGestureCondition = gestureAllowed,
	gestureCloses = true, -- the open gesture is a toggle: it closes the tutorial on any page too
	pageOffset = pageOffset,
	onClose = function(self, reason)
		if reason == "level_change" then
			-- closed without the player choosing to: the startup tutorial comes back in the next gameplay
			if startupShow then startupPending = true end
			startupShow = false
			return
		end
		if startupShow and (reason == "closed" or reason == "skipped") then self:setCompleted(true) end
		startupShow = false
	end,
})

-- The startup tutorial waits for real gameplay, never the main menu (which also has a pawn and the VR controllers):
--   * the pawn is the game's play character (native ASHCharacterPlay, CronosCharacterPlay_BP_C in game)
--   * the player controller is the play controller (native ASHPlayerControllerPlay, SHPlayerControllerPlay_BP_C)
--   * the world's game mode is not the main menu's (native AMainMenuGameMode)
--   * the motion controller components exist (libs/gestures reads the cached left controller and HMD for the gesture)
--   * no cutscene / vent / ladder, not paused, no menu mouse cursor
-- Classes are matched by name up the class chain, so the /Script/ module they live in does not matter.
local controllers = require('libs/controllers')

local function isA(object, className)
	if object == nil then return false end
	local class = object:get_class()
	while class ~= nil do
		if class:get_fname():to_string() == className then return true end
		class = class:get_super_struct()
	end
	return false
end

local function inGameplay()
	local ok, result = pcall(function()
		if not isA(uevr.api:get_local_pawn(0), "SHCharacterPlay") then return false end
		if not isA(uevr.api:get_player_controller(0), "SHPlayerControllerPlay") then return false end
		local world = uevrUtils.get_world()
		if world == nil or isA(world.AuthorityGameMode, "MainMenuGameMode") then return false end
		if not controllers.controllerExists(Handed.Left) or not controllers.hmdControllerExists() then return false end
		if call(_G.cronosIsCutscene) then return false end
		return not isPausedOrMenu()
	end)
	return ok and result == true
end

startupPending = not t:isCompleted()
local STARTUP_POLL_S = 0.5
local startupPollTimer = 0
uevrUtils.registerPreEngineTickCallback(function(engine, delta)
	if not startupPending or t:isOpen() then return end
	startupPollTimer = startupPollTimer + (tonumber(delta) or 0)
	if startupPollTimer < STARTUP_POLL_S then return end
	startupPollTimer = 0
	if t:isCompleted() then startupPending = false return end
	if not enabled("tut_startup") then return end -- panel option off: keep waiting in case it is turned back on
	if inGameplay() then
		startupPending = false
		startupShow = t:showOnce()
	end
end)

local function updateStatus()
	configui.setLabel("tut_status", t:isCompleted() and "Shown at start: no (closed, finished or hidden)" or "Shown at start: yes")
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
		startupShow = false
		t:show(t:getSavedPage() or 1)
	elseif action == "reset" then
		startupShow = false
		t:resetCompleted()
		t:resetInteraction()
		t:resetSavedPage()
	end
	updateStatus()
end)

uevrUtils.setTimeout(1000, updateStatus)
