-- page_lib.lua: shared loader for zone_page.lua / page_leg.lua / page_check.lua
--
-- Everything lives in FusionPBX > Advanced > Default Settings, Category = paging, Type = array,
-- Enabled = true, one row per item:
--
--   Subcategory  stream   Value  id|address|port|control_port|poly_channel[|ttl]
--       a multicast stream: where the audio goes (Mitel/plain RTP) and which Polycom channel it uses
--       example:  1|239.1.1.11|5001|6061|26|4
--
--   Subcategory  zone     Value  number|name|stream ids|save|recipients[|transcribe]
--       a pageable zone: one or more streams, plus whether to record and who gets the recording
--       stream ids are comma separated, recipients are separated by ; or ,   save is true or false
--       transcribe (true/false, default false) is a PLACEHOLDER: it records the page and logs the
--       request, but nothing transcribes yet (see the TODO in zone_page.lua)
--       example:  3|All Zones|1,2|true|principal@school.org;office@school.org|false
--
-- Bad rows are rejected (and reported), so a typo can't silently misroute a page.
local M = {}

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function fields(raw)
  local f = {}
  for part in (raw .. "|"):gmatch("([^|]*)|") do f[#f + 1] = trim(part) end
  return f
end

local function is_multicast(a)
  local o1, o2, o3, o4 = a:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not o1 then return false end
  o1, o2, o3, o4 = tonumber(o1), tonumber(o2), tonumber(o3), tonumber(o4)
  return o1 >= 224 and o1 <= 239 and o2 <= 255 and o3 <= 255 and o4 <= 255
end

local function in_range(v, lo, hi)
  v = tonumber(v)
  return v ~= nil and v == math.floor(v) and v >= lo and v <= hi
end

local function valid_email(v) return v:match("^[%w%._%%%+%-]+@[%w%.%-]+%.%a%a+$") ~= nil end

-- returns cfg, errors
--   cfg.streams[id] = { id, addr, port, ctl, chan, ttl };  cfg.stream_order = { id, ... }
--   cfg.zones[num]  = { num, name, streams = { stream, ... }, save = bool, emails = { ... } };  cfg.zone_order
function M.load()
  require "resources.functions.config"
  local Database = require "resources.functions.database"
  local db = Database.new("system")

  local function rows(sub)
    local out = {}
    db:query([[select default_setting_value as val from v_default_settings
               where default_setting_category = 'paging'
                 and default_setting_subcategory = :s
                 and default_setting_enabled = 'true'
               order by default_setting_order, default_setting_value]], { s = sub },
      function(row) out[#out + 1] = row.val end)
    return out
  end

  local cfg = { streams = {}, stream_order = {}, zones = {}, zone_order = {} }
  local errors = {}
  local seen_addr, seen_ctl, seen_chan = {}, {}, {}

  -- streams
  for _, raw in ipairs(rows("stream")) do
    local f = fields(raw)
    local id, addr, port, ctl, chan, ttl = f[1], f[2], f[3], f[4], f[5], f[6]
    if not ttl or ttl == "" then ttl = "4" end

    local problem
    if not id or not id:match("^%w+$") then problem = "stream id must be letters/digits"
    elseif cfg.streams[id] then problem = "duplicate stream id " .. id
    elseif not addr or not is_multicast(addr) then problem = "address is not a multicast address (224-239.x.x.x)"
    elseif not in_range(port, 1024, 65535) then problem = "port must be 1024-65535"
    elseif not in_range(ctl, 1024, 65535) then problem = "control port must be 1024-65535"
    elseif not in_range(chan, 1, 254) then problem = "Polycom channel must be 1-254"
    elseif not in_range(ttl, 1, 255) then problem = "ttl must be 1-255"
    elseif seen_addr[addr .. ":" .. port] then problem = "address:port already used by stream " .. seen_addr[addr .. ":" .. port]
    elseif seen_ctl[ctl] then problem = "control port already used by stream " .. seen_ctl[ctl]
    elseif seen_chan[chan] then problem = "Polycom channel already used by stream " .. seen_chan[chan]
    end

    if problem then
      errors[#errors + 1] = string.format("stream row '%s': %s", raw, problem)
    else
      cfg.streams[id] = { id = id, addr = addr, port = port, ctl = ctl, chan = chan, ttl = ttl }
      cfg.stream_order[#cfg.stream_order + 1] = id
      seen_addr[addr .. ":" .. port] = id
      seen_ctl[ctl] = id
      seen_chan[chan] = id
    end
  end

  -- zones
  for _, raw in ipairs(rows("zone")) do
    local f = fields(raw)
    local num, name, stream_list, save, recips, transcribe = f[1], f[2], f[3], f[4], f[5], f[6]

    local problem
    local streams, emails, seen_s = {}, {}, {}

    if not num or not num:match("^%d+$") then problem = "zone number must be digits"
    elseif cfg.zones[num] then problem = "duplicate zone number " .. num
    elseif not name or name == "" then problem = "name is empty"
    elseif not stream_list or stream_list == "" then problem = "no streams listed"
    end

    if not problem then
      for sid in stream_list:gmatch("[^,%s]+") do
        if not cfg.streams[sid] then
          problem = "stream '" .. sid .. "' does not exist (or its row was rejected)"; break
        elseif seen_s[sid] then
          problem = "stream '" .. sid .. "' listed twice"; break
        end
        seen_s[sid] = true
        streams[#streams + 1] = cfg.streams[sid]
      end
    end

    if not problem then
      local s = (save or ""):lower()
      if s ~= "" and s ~= "true" and s ~= "false" then problem = "save must be true or false"
      else save = (s == "true") end
    end

    if not problem then
      local t = (transcribe or ""):lower()
      if t ~= "" and t ~= "true" and t ~= "false" then problem = "transcribe must be true or false"
      else transcribe = (t == "true") end
    end

    if not problem then
      for addr in (recips or ""):gmatch("[^;,%s]+") do
        if valid_email(addr) then emails[#emails + 1] = addr
        else problem = "recipient '" .. addr .. "' is not a valid address"; break end
      end
    end

    if problem then
      errors[#errors + 1] = string.format("zone row '%s': %s", raw, problem)
    else
      cfg.zones[num] = { num = num, name = name, streams = streams, save = save, emails = emails,
                         transcribe = transcribe }
      cfg.zone_order[#cfg.zone_order + 1] = num
    end
  end

  return cfg, errors
end

return M
