-- Builds the single user-facing "Cronos VR" panel in the UEVR overlay (same pattern as the Hellraiser
-- profile's zz_hellraiser_vr_panel.lua).
--
-- Every game script registers its settings as a section in _G.CRONOS_SECTIONS ({ order, label, layout })
-- instead of creating its own panel; this file loads LAST (UEVR loads scripts in case-insensitive name
-- order, hence zz_) and turns the sections into one panel. Widget ids are global in configui, so the owning
-- scripts use configui.getValue / onUpdate / setLabel directly. Values are saved together in
-- data/cronos_vr_config.json. configui.getValue returns nil until this panel exists, so every reader treats
-- nil as the widget's initial value.

local configui = require('libs/configui')

local PANEL_LABEL = "Cronos VR"
local SAVE_FILE   = "cronos_vr_config"

local sections = _G.CRONOS_SECTIONS or {}
table.sort(sections, function(a, b) return (a.order or 99) < (b.order or 99) end)

-- Main panel vs "Dev Config": keyed by section label, true = the whole section is dev; a list = the widget
-- ids that STAY in the main panel (everything else of that section goes to dev). Sections not listed stay
-- entirely in the main panel.
local DEV_RULES = {
    ["Hands"]             = { "hands_mode", "hands_mode_status" },
    ["Two-Handed Aiming"] = { "twoHandEnabled", "lhGlide", "th_grab_button", "th_suppress_grab", "th_snap_left_hand" },
    ["Weapon"]            = true,
}

-- Sections whose main part is shown without a collapsible header, together at the top of the panel
local FLAT_SECTIONS = {
    ["Hands"]             = true,
    ["Two-Handed Aiming"] = true,
}

local function splitSection(section)
    local rule = DEV_RULES[section.label]
    local items = section.layout or {}
    if rule == nil then return items, {} end
    if rule == true then return {}, items end
    local keep = {}
    for _, id in ipairs(rule) do keep[id] = true end
    local main, dev = {}, {}
    for _, item in ipairs(items) do
        table.insert((item.id ~= nil and keep[item.id]) and main or dev, item)
    end
    return main, dev
end

local function addNode(target, id, label, items, open)
    table.insert(target, { widgetType = "tree_node", id = id, label = label, initialOpen = open })
    for _, item in ipairs(items) do table.insert(target, item) end
    table.insert(target, { widgetType = "spacing" })
    table.insert(target, { widgetType = "tree_pop" })
end

local layout, devLayout, flatLayout = {}, {}, {}
if #sections == 0 then
    table.insert(layout, { widgetType = "text", label = "No sections registered (scripts/*.lua load order?)" })
end
local mainCount = 0
for i, section in ipairs(sections) do
    local label = section.label or ("Section " .. i)
    local main, dev = splitSection(section)
    if #main > 0 and FLAT_SECTIONS[label] then
        for _, item in ipairs(main) do table.insert(flatLayout, item) end
    elseif #main > 0 then
        mainCount = mainCount + 1
        addNode(layout, "cronos_section_" .. i, label, main, mainCount == 1)
    end
    if #dev > 0 then addNode(devLayout, "cronos_dev_section_" .. i, label, dev, false) end
end
if #flatLayout > 0 then
    table.insert(flatLayout, { widgetType = "spacing" })
    for i = #flatLayout, 1, -1 do table.insert(layout, 1, flatLayout[i]) end
end
table.insert(layout, 1, { widgetType = "spacing" })
table.insert(layout, 1, { widgetType = "text_colored", label = "Cronos: The New Dawn VR", color = "#8B0000FF" })
if #devLayout > 0 then
    table.insert(layout, { widgetType = "tree_node", id = "cronos_dev_config", label = "Dev Config", initialOpen = false })
    for _, item in ipairs(devLayout) do table.insert(layout, item) end
    table.insert(layout, { widgetType = "tree_pop" })
end

configui.create({
    {
        panelLabel = PANEL_LABEL,
        saveFile = SAVE_FILE,
        layout = layout,
    }
})

print("[cronos panel] '" .. PANEL_LABEL .. "' built with " .. #sections .. " sections")
