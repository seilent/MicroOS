log = Log.open_topic ("s-microos-dp-sink")

local dir = "/run/microos"
local flag = dir .. "/dp-audio"
local props = {
  ["factory.name"] = "api.alsa.pcm.sink",
  ["media.class"] = "Audio/Sink",
  ["api.alsa.path"] = "hw:CARD=PocketMICRO2,DEV=3",
  ["node.name"] = "alsa_output.platform-sound.DisplayPort__sink",
  ["node.description"] = "DisplayPort",
  ["node.pause-on-idle"] = false,
  ["session.suspend-timeout-seconds"] = 0,
  ["priority.session"] = 1050,
  ["audio.format"] = "S16LE",
  ["audio.rate"] = 48000,
  ["audio.channels"] = 2,
}
local sink = nil
local up = false
local retry = nil
local delay = 3000
local update

local function retry_later ()
  if retry ~= nil then
    return
  end
  retry = Core.timeout_add (delay, function ()
    retry = nil
    update ()
    return false
  end)
  delay = math.min (delay * 2, 60000)
end

local function retry_reset ()
  if retry ~= nil then
    retry:destroy ()
    retry = nil
  end
  delay = 3000
end

update = function ()
  if GLib.access (flag, "r") then
    if sink ~= nil then
      return
    end
    local n = Node ("adapter", props)
    sink = n
    up = false
    n:activate (Features.ALL, function (_, err)
      if sink ~= n then
        if not err then
          n:request_destroy ()
        end
      elseif err then
        log:warning ("DisplayPort sink failed: " .. tostring (err))
        sink = nil
        retry_later ()
      else
        up = true
        log:info ("DisplayPort sink added")
      end
    end)
  elseif sink ~= nil then
    if up then
      sink:request_destroy ()
    end
    sink = nil
    up = false
    log:info ("DisplayPort sink removed")
  end
end

local fm = Plugin.find ("file-monitor-api")
fm:connect ("changed", function (_, file, other, _)
  if file == flag or other == flag then
    retry_reset ()
    update ()
  end
end)
fm:call ("add-watch", dir, "m")
update ()
