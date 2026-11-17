# Poly phones: setting the group bit

Tested on Poly VVX 450 phones, UC software 6.4.7, provisioned from FusionPBX. Parameter names below are
as they appeared in our provisioned files. Check them against the admin guide for your firmware.

## The model

Every Polycom-format paging packet carries a **channel byte**. A phone plays a page only if the channel
matches a paging group it is subscribed to.

| Paging group | Channel |
|---|---|
| 1 | 26 |
| 2 | 27 |
| any group N | 25 + N |
| 24 (priority) | 49 |
| 25 (emergency) | 50 |

We saw channels 26, 27, 49 and 50 directly (phone PTT syslog and tests). Channels 28 and later follow from
the `25 + N` rule but were not run.

All phones listen on the same multicast group and port: **`224.0.1.116:5001`**. That is where `mod_esf`
always sends its Polycom-format stream, and it cannot be changed from the dialplan. The switch therefore
cannot isolate zones in this mode: each phone receives every page and drops the ones it isn't subscribed to.

## PBX side: set the channel per call

```xml
<action application="set" data="esf_multicast_channel=27"/>
<action application="esf_page_group" data="239.1.1.12 5001 6062 4"/>
```

In this project that is done for you: the stream row's Polycom channel field is applied by `page_leg.lua`.

- The variable name must be exact. A misspelling is **silently ignored** and the page goes out on the
  default channel, 26.
- Allowed range for the variable is 1 to 254 (from the `mod_esf` source).

## Phone side: subscribe each phone to its own group

Provision these (here, a phone in zone 2, which is group 2, channel 27):

```
ptt.pageMode.enable="1"
ptt.address="224.0.1.116"
ptt.port="5001"
ptt.pageMode.group.1.label="Page All"
ptt.pageMode.group.2.label="Zone 2"
ptt.pageMode.group.1.subscribed="0"
ptt.pageMode.group.2.subscribed="1"
```

- Turn the other groups off explicitly instead of relying on defaults. Group 1 (channel 26) showed as
  receiving at boot on our phones, so a phone you meant to restrict to group 2 may still play group 1 pages.
- Provision the settings. On our phones, opening and saving the paging page in the phone's own web
  interface **switched group paging off again**. The fix that worked was to factory-reset, set it once
  through provisioning, and not revisit that web page.
- In FusionPBX, per-phone values go in the polycom template (`polycom/6.x/{$mac}.cfg`).

## Verify

1. **Phone syslog.** Enable syslog from provisioning (`device.syslog.*`, and
   `log.level.change.ptt` for the PTT module) and reboot. For the zone 2 phone, look for a line like
   `configuring Channel <27> ... allowReceive 1`. Our phones also showed channels 49 and 50
   (priority and emergency) enabled by default at boot.
2. **On the PBX**, confirm the channel byte on the wire. The audio packets start with opcode `10` and then
   the channel; alert packets start with `0f`:

   ```
   tcpdump -nn -X 'dst 224.0.1.116 and udp port 5001 and greater 300'
   ```

   Look at the end of the `0x0010` row. `101b` is audio on channel 27 (`1b` hex = 27); `101a` is channel 26.
   Do not filter on a custom multicast destination, or you will miss this stream.
3. **Call test.** A page to zone 1 plays only on the zone 1 phone; a page to zone 2 only on the zone 2 phone.

## Network notes

- On one subnet with IGMP snooping, run an IGMP querier. Without one the switch's group table ages out.
- Unregistered multicast is flooded to every port by default on many switches. A page can then "work" for
  the wrong reason, so confirm with the switch's group table and a port capture before trusting a test.
- Our phones sent IGMPv3 membership reports. Some routers and IGMP proxies only understand v1/v2.
