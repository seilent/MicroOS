local function read_transform()
    local runtime = os.getenv("XDG_RUNTIME_DIR")
    if not runtime then
        return 3
    end

    local file = io.open(runtime .. "/microos/desktop-transform", "r")
    if not file then
        return 3
    end

    local line = file:read("*l")
    file:close()

    if not line then
        return 3
    end

    local digit = line:match("^%s*([0-7])%s*$")
    if not digit then
        return 3
    end

    return tonumber(digit)
end

local transform = read_transform()

hl.monitor({
    output = "",
    mode = "preferred",
    position = "auto",
})

hl.monitor({
    output = "DSI-1",
    mode = "640x960@60",
    scale = "2",
    transform = transform,
})

hl.device({
    name = "sitronix-st7123-touchscreen",
    output = "DSI-1",
    transform = transform,
})

hl.config({
    general = {
        gaps_in = 6,
        gaps_out = 16,
        border_size = 0,
    },
    decoration = {
        rounding = 0,
    },
    animations = {
        enabled = false,
    },
    gestures = {
        workspace_swipe_distance = 300,
        workspace_swipe_invert = true,
        workspace_swipe_min_speed_to_force = 30,
        workspace_swipe_cancel_ratio = 0.5,
        workspace_swipe_direction_lock = true,
        workspace_swipe_create_new = true,
        workspace_swipe_forever = false,
    },
    misc = {
        disable_watchdog_warning = true,
        disable_hyprland_guiutils_check = true,
        disable_hyprland_logo = true,
        disable_splash_rendering = true,
    },
    ecosystem = {
        no_update_news = true,
        no_donation_nag = true,
    },
})

hl.bind("code:191", hl.dsp.no_op())
hl.bind("code:192", hl.dsp.no_op())
hl.bind("code:193", hl.dsp.no_op())
hl.bind("code:123", hl.dsp.no_op())
hl.bind("code:122", hl.dsp.no_op())
hl.bind("code:124", hl.dsp.no_op())

local hyprgrass_path = "/usr/lib64/libhyprgrass.so"
local hyprgrass_file = io.open(hyprgrass_path, "r")

if hyprgrass_file then
    hyprgrass_file:close()
    hl.plugin.load(hyprgrass_path)
end

if hl.plugin.hyprgrass then
    local launcher_toggle = "gdbus call --session --dest net.seilent.MicroSet.Launcher --object-path /net/seilent/MicroSet/Launcher --method net.seilent.MicroSet.Launcher1.Toggle"

    local function spike_log(name)
        hl.dispatch(hl.dsp.exec_cmd("logger -t microos-spike " .. name))
    end

    local function zoom_step(multiplier)
        local current = hl.get_config("cursor.zoom_factor")
        if type(current) ~= "number" then
            current = 1
        end

        local next_factor = current * multiplier
        if next_factor < 1 then
            next_factor = 1
        end
        if next_factor > 10 then
            next_factor = 10
        end

        hl.config({ cursor = { zoom_factor = next_factor } })
    end

    hl.plugin.hyprgrass.gesture({
        pattern = { kind = "swipe", fingers = 3, direction = "horizontal" },
        action = "workspace",
    })

    hl.plugin.hyprgrass.gesture({
        pattern = { kind = "swipe", fingers = 3, direction = "up" },
        action = "fullscreen",
    })

    hl.plugin.hyprgrass.gesture({
        pattern = { kind = "swipe", fingers = 3, direction = "down" },
        action = function()
            hl.dispatch(hl.dsp.window.set_prop({ prop = "opaque", value = "toggle" }))
        end,
    })

    hl.plugin.hyprgrass.bind({
        pattern = { kind = "pinch", fingers = 3, direction = "pinchout" },
        action = hl.dsp.window.close(),
    })

    hl.plugin.hyprgrass.bind({
        pattern = { kind = "longpress", fingers = 3 },
        action = hl.dsp.window.resize(),
        mouse = true,
    })

    hl.plugin.hyprgrass.gesture({
        pattern = { kind = "swipe", fingers = 4, direction = "right" },
        action = function()
            hl.dispatch(hl.dsp.exec_cmd(launcher_toggle))
        end,
    })

    hl.plugin.hyprgrass.gesture({
        pattern = { kind = "swipe", fingers = 4, direction = "left" },
        action = function()
            spike_log("microset")
        end,
    })

    hl.plugin.hyprgrass.gesture({
        pattern = { kind = "swipe", fingers = 4, direction = "down" },
        action = function()
            hl.dispatch(hl.dsp.workspace.toggle_special("special"))
        end,
    })

    hl.plugin.hyprgrass.bind({
        pattern = { kind = "pinch", fingers = 4, direction = "pinchout" },
        action = function()
            zoom_step(1 / 1.5)
        end,
    })

    hl.plugin.hyprgrass.bind({
        pattern = { kind = "pinch", fingers = 4, direction = "pinchin" },
        action = function()
            zoom_step(1.5)
        end,
    })

    hl.plugin.hyprgrass.bind({
        pattern = { kind = "edge", origin = "down", direction = "up" },
        action = hl.dsp.exec_cmd("systemctl --user start --no-block microos-osk-toggle.service"),
    })

    hl.plugin.hyprgrass.bind({
        pattern = { kind = "edge", origin = "up", direction = "down" },
        action = hl.dsp.exec_cmd(launcher_toggle),
    })

    hl.plugin.hyprgrass.bind({
        pattern = { kind = "longpress", fingers = 2 },
        action = hl.dsp.window.drag(),
        mouse = true,
    })
end

hl.on("hyprland.start", function()
    hl.dispatch(hl.dsp.exec_cmd("/usr/libexec/microos/microos-desktop-env"))
end)

pcall(require, "~/.config/hypr/hyprland.lua")
