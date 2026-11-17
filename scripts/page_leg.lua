-- page_leg.lua <stream id>
-- Runs on the loopback leg that zone_page.lua starts for each stream of the zone: looks the
-- stream up in Default Settings, then sends whatever the conference gives it to that stream.
-- this leg is plumbing, not a call anyone needs a record of: no CDR row for it
session:setVariable("process_cdr", "false")

local lib = require "page_lib"
local cfg, errors = lib.load()
local id = argv[1]
local s = cfg.streams[id]

if not s then
  freeswitch.consoleLog("err", "page_leg: stream '" .. tostring(id) .. "' is not configured or has a bad row; refusing\n")
  for _, e in ipairs(errors) do freeswitch.consoleLog("err", "page_leg: " .. e .. "\n") end
  session:hangup("UNALLOCATED_NUMBER")
  return
end

session:answer()
session:setVariable("esf_multicast_channel", s.chan)   -- Polycom: channel byte
local data = string.format("%s %s %s %s", s.addr, s.port, s.ctl, s.ttl)  -- plain RTP: address
freeswitch.consoleLog("notice", string.format("page_leg: stream %s -> esf_page_group %s, polycom channel %s\n",
  s.id, data, s.chan))
session:execute("esf_page_group", data)
