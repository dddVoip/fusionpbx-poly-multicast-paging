-- page_check.lua: run from fs_cli, no call needed:   fs_cli -x "lua page_check.lua"
-- Lists the streams and zones Default Settings defines, and any rows that were rejected.
local lib = require "page_lib"
local cfg, errors = lib.load()

stream:write(string.format("%d valid stream(s)\n", #cfg.stream_order))
for _, id in ipairs(cfg.stream_order) do
  local s = cfg.streams[id]
  stream:write(string.format("  stream %-6s %s:%s  control %s  poly channel %s  ttl %s\n",
    s.id, s.addr, s.port, s.ctl, s.chan, s.ttl))
end

stream:write(string.format("%d valid zone(s)\n", #cfg.zone_order))
for _, n in ipairs(cfg.zone_order) do
  local z = cfg.zones[n]
  local ids = {}
  for _, s in ipairs(z.streams) do ids[#ids + 1] = s.id end
  stream:write(string.format("  zone %-3s %-16s streams: %-12s save=%-5s transcribe=%-5s (placeholder) recipients: %s\n",
    z.num, z.name, table.concat(ids, ","), tostring(z.save), tostring(z.transcribe),
    #z.emails > 0 and table.concat(z.emails, ", ") or "none"))
end

if #errors > 0 then
  stream:write(string.format("%d REJECTED row(s):\n", #errors))
  for _, e in ipairs(errors) do stream:write("  " .. e .. "\n") end
else
  stream:write("no rejected rows\n")
end
