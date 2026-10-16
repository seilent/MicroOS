lutils = require ("linking-utils")
cutils = require ("common-utils")
log = Log.open_topic ("s-linking")

SimpleEventHook {
  name = "linking/microos-eq-bypass",
  after = "linking/get-filter-from-target",
  before = "linking/prepare-link",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "select-target" },
    },
  },
  execute = function (event)
    local source, om, si, si_props, si_flags, target =
        lutils:unwrap_select_target_event (event)

    if target == nil or si_props ["node.link-group"] ~= nil or
        not cutils.parseBool (si_props ["node.dont-reconnect"]) then
      return
    end

    local value = si_props ["target.object"]
    local key = "object.serial"
    if value == nil then
      value = si_props ["node.target"]
      key = "node.id"
    end
    if value == nil then
      return
    end

    local direction = cutils.getTargetDirection (si_props)
    local defined = nil
    for lnkbl in om:iterate { type = "SiLinkable" } do
      local p = lnkbl.properties
      if p ["item.node.direction"] == direction and
          (p [key] == value or p ["node.name"] == value or p ["object.path"] == value) then
        defined = lnkbl
        break
      end
    end

    if defined == nil or defined.id == target.id or
        defined.properties ["node.link-group"] ~= nil or
        not lutils.canLink (si_props, defined) then
      return
    end

    log:info (si, "... microos: defined target " ..
        tostring (defined.properties ["node.name"]) .. " kept, filter bypassed")
    event:set_data ("target", defined)
  end
}:register ()
