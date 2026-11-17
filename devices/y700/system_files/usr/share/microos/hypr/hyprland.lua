require("hyprland.lib")
require("hyprland.services")
require("hyprland.env")
require("custom.env")
require("hyprland.execs")
require("hyprland.general")
require("hyprland.rules")
require("hyprland.colors")
require("hyprland.keybinds")
require("custom.execs")
require("custom.general")
require("custom.rules")
require("custom.keybinds")
require("hyprland.shellOverrides.main")

local function read_transform()
    local default = 3
    local runtime = os.getenv("XDG_RUNTIME_DIR")
    if not runtime then
        return default
    end

    local file = io.open(runtime .. "/microos/desktop-transform", "r")
    if not file then
        return default
    end

    local line = file:read("*l")
    file:close()

    if not line then
        return default
    end

    local digit = line:match("^%s*([0-7])%s*$")
    if not digit then
        return default
    end

    return tonumber(digit)
end

local transform = read_transform()

hl.monitor({
    output = "DSI-1",
    mode = "1600x2560@120",
    scale = 1.6,
    transform = transform,
})

hl.config({
    input = {
        touchdevice = { output = "DSI-1", transform = 0 },
        tablet = { output = "DSI-1", transform = 0 },
    },
})

hl.on("hyprland.start", function()
    hl.dispatch(hl.dsp.exec_cmd("/usr/libexec/microos/microos-desktop-env"))
end)
