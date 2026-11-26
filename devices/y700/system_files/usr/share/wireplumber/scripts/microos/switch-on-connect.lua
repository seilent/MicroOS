log = Log.open_topic ("s-microos-switch")

local skip = { "controller", "gamepad", "hdmi", "displaylink" }

local function external (name)
  if name:find ("^alsa_output%.usb%-") == nil and name:find ("^bluez_output%.") == nil then
    return false
  end
  local lower = name:lower ()
  for _, word in ipairs (skip) do
    if lower:find (word, 1, true) then
      return false
    end
  end
  return true
end

SimpleEventHook {
  name = "microos/switch-on-connect",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "node-added" },
      Constraint { "media.class", "=", "Audio/Sink", type = "pw-global" },
    },
  },
  execute = function (event)
    local name = event:get_subject ().properties ["node.name"]
    if name == nil or not external (name) then
      return
    end
    local om = event:get_source ():call ("get-object-manager", "metadata")
    local metadata = om:lookup { Constraint { "metadata.name", "=", "default" } }
    if metadata == nil then
      log:warning ("no default metadata, " .. name .. " stays as it is")
      return
    end
    metadata:set (0, "default.configured.audio.sink", "Spa:String:JSON", Json.Object { ["name"] = name }:to_string ())
    log:notice (name .. " connected, now the default output")
  end
}:register ()
