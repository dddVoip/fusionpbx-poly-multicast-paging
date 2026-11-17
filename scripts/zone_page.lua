-- zone_page.lua <zone number> [email[,email...]] [save]
--   the zone (its streams, save flag and recipients) comes from Default Settings, see page_lib.lua
--   arguments are optional extras: an address containing "@" is one more recipient,
--   and the word "save" forces recording
-- If the zone saves and/or has recipients, the page is recorded into the domain's archive folder
-- (FusionPBX convention) and the call's CDR gets record_path and record_name.
-- Each stream of the zone is fed by a muted loopback leg (page_leg.lua) listening to a conference.
local lib         = require "page_lib"
local api         = freeswitch.API()
local uuid        = session:getVariable("uuid")
local domain      = session:getVariable("domain_name")
local domain_uuid = session:getVariable("domain_uuid")
-- Caller ID and name come from the network (a trunk caller can set them to anything), so they are
-- cleaned before they go into the originate command or the email. Never use the raw values.
local function clean_cid(s)
  s = (tostring(s or ""):gsub("[^%d%+%*#]", "")):sub(1, 32)
  if s == "" then s = "unknown" end
  return s
end
local function clean_name(s)
  return (tostring(s or ""):gsub("[^%w ._%-]", "")):sub(1, 40)
end
local cid         = clean_cid(session:getVariable("caller_id_number"))
local cname       = clean_name(session:getVariable("caller_id_name"))
local conf        = "page-" .. uuid

local cfg, load_errors = lib.load()
for _, e in ipairs(load_errors) do freeswitch.consoleLog("err", "zone_page: " .. e .. "\n") end

-- arguments: the zone number, plus optional extra recipients and the save flag
local zone_num, emails, save = nil, {}, false
local have = {}
for i = 1, #argv do
  local a = argv[i]
  if a:lower() == "save" then
    save = true
  elseif a:find("@", 1, true) then
    for addr in a:gmatch("[^,;]+") do
      if not have[addr:lower()] then emails[#emails + 1] = addr; have[addr:lower()] = true end
    end
  elseif not zone_num then
    zone_num = a
  end
end

local zone = zone_num and cfg.zones[zone_num]
session:answer()

if not zone then
  freeswitch.consoleLog("err", "zone_page: zone '" .. tostring(zone_num) .. "' is not configured or has a bad row; refusing\n")
  session:streamFile("tone_stream://%(500,500,480,620);loops=3")   -- re-order tone
  session:hangup("INVALID_NUMBER_FORMAT")
  return
end

local targets = zone.streams
if zone.save then save = true end
for _, a in ipairs(zone.emails) do
  if not have[a:lower()] then emails[#emails + 1] = a; have[a:lower()] = true end
end
freeswitch.consoleLog("notice", string.format("zone_page: zone %s (%s), %d stream(s), record=%s, recipients=%d\n",
  zone.num, zone.name, #targets, tostring(save or #emails > 0), #emails))

for _, s in ipairs(targets) do
  local cmd = string.format(
    -- process_cdr=false: the legs are plumbing; only the caller's call should get a CDR row
    "bgapi originate {origination_caller_id_name=Page,origination_caller_id_number=%s,ignore_early_media=true,process_cdr=false}loopback/pageleg-%s/%s &conference(%s@page+flags{mute})",
    cid, s.id, domain, conf)
  freeswitch.consoleLog("notice", "zone_page: " .. cmd .. "\n")
  api:executeString(cmd)
end

-- wait up to 5 s for all legs to join before the caller does
local ready = false
for i = 1, 50 do
  local out = api:executeString("conference " .. conf .. " count") or ""
  local n = tonumber(out:match("^%s*(%d+)%s*$"))
  if n and n >= #targets then ready = true; break end
  session:sleep(100)
end
freeswitch.consoleLog("notice", "zone_page: legs ready=" .. tostring(ready) .. "\n")

-- one short attention beep: into the conference (the streams) and locally to the caller.
-- The zone phones need a moment to open their page channel, so wait first or the start of
-- the tone is swallowed. Tune these two numbers if a phone still misses it.
local BEEP_DELAY_MS, BEEP_MS = 600, 500
session:sleep(BEEP_DELAY_MS)
local tone = string.format("tone_stream://%%(%d,0,880)", BEEP_MS)
local res = api:executeString("conference " .. conf .. " play " .. tone .. " async")
freeswitch.consoleLog("notice", "zone_page: beep (" .. BEEP_MS .. " ms after " .. BEEP_DELAY_MS .. " ms) -> " .. tostring(res) .. "\n")
session:streamFile(tone)

-- record the caller's audio if it will be saved and/or emailed
local rec_path
if save or #emails > 0 or zone.transcribe then
  -- same layout FusionPBX's own call recording uses, so the CDR page can play it
  local rec_dir  = string.format("/var/lib/freeswitch/recordings/%s/archive/%s/%s/%s",
    domain, os.date("%Y"), os.date("%b"), os.date("%d"))
  local rec_name = uuid .. ".wav"
  rec_path = rec_dir .. "/" .. rec_name
  session:execute("mkdir", rec_dir)
  session:setVariable("record_path", rec_dir)   -- the CDR importer reads these two
  session:setVariable("record_name", rec_name)
  session:execute("record_session", rec_path)
  freeswitch.consoleLog("notice", "zone_page: recording to " .. rec_path .. "\n")
end

local started = os.time()
session:execute("conference", conf .. "@page+flags{moderator|endconf}")
local duration = os.time() - started

-- page is over: close the recording, then email it
-- (failures here are only logged and never affect paging)
if rec_path then
  pcall(function() session:execute("stop_record_session", rec_path) end)
end

-- TRANSCRIPTION PLACEHOLDER: nothing transcribes yet. When the zone asks for it we only log the
-- request. The plan is to hand rec_path to a speech-to-text job (for example a local Whisper
-- service) and write the text into the call's CDR column v_xml_cdr.record_transcription. The CDR
-- row is created after hangup, so that job must be keyed on this call's uuid and run afterwards,
-- not from here. The text could then also be added to the email body above.
if rec_path and zone.transcribe then
  freeswitch.consoleLog("notice", string.format(
    "zone_page: TRANSCRIBE requested for call %s, file %s (not implemented yet)\n", uuid, rec_path))
end

if rec_path and #emails > 0 then
  local ok, err = pcall(function()
    -- FusionPBX's helpers expect these globals, as the voicemail scripts set them
    domain_name = domain
    if not domain_uuid or domain_uuid == "" then
      local Database = require "resources.functions.database"
      local db = Database.new("system")
      db:query("select domain_uuid from v_domains where domain_name = :d", { d = domain },
        function(row) domain_uuid = row.domain_uuid end)
    end
    local send_mail = require "resources.functions.send_mail"

    local headers = {
      ["X-FusionPBX-Domain-UUID"] = domain_uuid,
      ["X-FusionPBX-Domain-Name"] = domain,
      ["X-FusionPBX-Email-Type"]  = "page",
    }
    local subject = string.format("Page from %s (%s) to %s", cname, cid, zone.name)
    local body = string.format("Page recording.\nFrom: %s <%s>\nZone: %s\nTime: %s\nLength: about %d seconds\n",
      cname, cid, zone.name, os.date("%Y-%m-%d %H:%M:%S"), duration)

    local f = io.open(rec_path, "rb")
    local attach = nil
    if f then f:close(); attach = rec_path end
    if not attach then
      freeswitch.consoleLog("warning", "zone_page: recording file missing, sending without attachment\n")
    end

    for i = 1, #emails do
      send_mail(headers, nil, emails[i], { subject, body }, attach)
      freeswitch.consoleLog("notice", "zone_page: queued email to " .. emails[i] .. "\n")
    end
  end)
  if not ok then
    freeswitch.consoleLog("err", "zone_page: email failed: " .. tostring(err) .. "\n")
  end
end
