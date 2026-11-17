local hyprgrass = "/usr/lib64/libhyprgrass.so"
if is_file_exists(hyprgrass) then
    hl.plugin.load(hyprgrass)
    hl.config({ plugin = { hyprgrass = { sensitivity = 4.0, long_press_delay = 400, edge_margin = 20 } } })
    local g = hl.plugin.hyprgrass
    g.gesture({ pattern = { kind = "swipe", fingers = 3, direction = "horizontal" }, action = "workspace" })
    g.gesture({ pattern = { kind = "swipe", fingers = 3, direction = "up" }, action = "fullscreen" })
    g.bind({ pattern = { kind = "swipe", fingers = 3, direction = "down" }, action = hl.dsp.window.set_prop({ prop = "opaque", value = "toggle" }) })
    g.bind({ pattern = { kind = "pinch", fingers = 3, direction = "pinchout" }, action = hl.dsp.window.close() })
    g.bind({ pattern = { kind = "swipe", fingers = 4, direction = "right" }, action = hl.dsp.global("quickshell:sidebarLeftToggle") })
    g.bind({ pattern = { kind = "swipe", fingers = 4, direction = "left" }, action = hl.dsp.global("quickshell:sidebarRightToggle") })
    g.bind({ pattern = { kind = "swipe", fingers = 4, direction = "up" }, action = hl.dsp.global("quickshell:workPanelToggle") })
    g.bind({ pattern = { kind = "swipe", fingers = 4, direction = "down" }, action = hl.dsp.workspace.toggle_special("special") })
    g.bind({ pattern = { kind = "pinch", fingers = 4, direction = "pinchout" }, action = hl.dsp.exec_cmd([[hyprctl keyword cursor:zoom_factor "$(hyprctl getoption cursor:zoom_factor | awk 'NR==1 {factor = $2; if (factor < 1) {factor = 1}; print factor / 1.5}')"]]) })
    g.bind({ pattern = { kind = "pinch", fingers = 4, direction = "pinchin" }, action = hl.dsp.exec_cmd([[hyprctl keyword cursor:zoom_factor "$(hyprctl getoption cursor:zoom_factor | awk 'NR==1 {factor = $2; if (factor < 1) {factor = 1}; print factor * 1.5}')"]]) })
    g.bind({ pattern = { kind = "tap", fingers = 3 }, action = hl.dsp.global("quickshell:searchToggle") })
    g.bind({ pattern = { kind = "edge", origin = "l", direction = "r" }, action = hl.dsp.global("quickshell:sidebarLeftToggle") })
    g.bind({ pattern = { kind = "edge", origin = "r", direction = "l" }, action = hl.dsp.global("quickshell:sidebarRightToggle") })
    g.bind({ pattern = { kind = "edge", origin = "d", direction = "u" }, action = hl.dsp.global("quickshell:oskToggle") })
    g.bind({ pattern = { kind = "edge", origin = "u", direction = "d" }, action = hl.dsp.global("quickshell:overviewWorkspacesToggle") })
    g.bind({ pattern = { kind = "longpress", fingers = 2 }, action = hl.dsp.window.drag(), mouse = true })
end
