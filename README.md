# Zoned multicast paging for FusionPBX

One call in, any set of zones out. A caller dials a number (or picks a zone from an IVR) and the PBX
sends the page as one multicast stream per target, using FreeSWITCH's `mod_esf` (`esf_page_group`).

Zones, streams, recording and email recipients are all edited in **FusionPBX > Advanced > Default
Settings**. No script editing is needed to add a zone.

> **Status: lab-proven on Poly phones only.** See [What is and isn't proven](#what-is-and-isnt-proven)
> before relying on this.

## How it works

```
caller ──> IVR / zone number ──> zone_page.lua
                                   │  answers, builds a conference (caller = moderator)
                                   ├─> loopback leg "pageleg-1" ──> page_leg.lua ──> esf_page_group  ──> stream 1
                                   └─> loopback leg "pageleg-2" ──> page_leg.lua ──> esf_page_group  ──> stream 2
```

- A **stream** is one multicast destination: address, port, control port, Polycom channel, TTL.
- A **zone** is a list of one or more streams, plus whether to record the page and who gets the recording.
- `esf_page_group` runs on one channel and blocks, so each stream needs its own channel. The conference
  with one muted loopback leg per stream is how a single call fans out.
- The caller is the only speaker. The legs only listen.

## Why Poly phones need special treatment

`mod_esf` sends **two** streams for every page:

| Stream | Goes to | Poly phones |
|---|---|---|
| Plain RTP (Cisco-style) | the address and port you pass to `esf_page_group` | ignored |
| Polycom-format | `224.0.1.116:5001`, hard-coded in the module | played |

So custom addresses never reach a Poly. Poly zoning is done with the **channel byte** in the Polycom
stream instead: set per call with the `esf_multicast_channel` variable, and each phone subscribes only to
its own paging group. Details and the exact provisioning parameters are in
[docs/poly-phones.md](docs/poly-phones.md).

The plain-RTP stream is what phones that listen on a per-zone multicast address would use (for example,
some Mitel models). **That part is untested here.**

## Requirements

- FusionPBX on a FreeSWITCH build that includes `mod_esf` (we used FreeSWITCH 1.10.12, Debian 12)
- Phones that can do multicast paging (tested: Poly VVX 450, UC software 6.4.7)
- A network where multicast reaches the phones. On one subnet with IGMP snooping, run an IGMP querier.

## Install

1. **Copy the scripts** from `scripts/` into your FreeSWITCH scripts directory
   (find it with `fs_cli -x "global_getvar script_dir"`; on Debian FusionPBX it is
   `/usr/share/freeswitch/scripts`). Do not rename them to `page.lua`: FusionPBX ships its own `page.lua`.
2. **Create a conference profile named `page`** (Advanced > Conference Profiles) with `rate` 8000,
   `interval` 20, `comfort-noise` false, and every `*-sound` parameter set to `silence_stream://50`.
   Without this, conference prompts leak into the page.
3. **Add the settings rows** from [settings/example_settings.md](settings/example_settings.md)
   (Advanced > Default Settings, category `paging`, type `array`).
4. **Add the dialplan entries** from [dialplan/paging.xml](dialplan/paging.xml)
   (Dialplan Manager, context = your domain).
5. **Provision the phones** as described in [docs/poly-phones.md](docs/poly-phones.md).
6. Optionally point an IVR at the zone numbers.

Then check what loaded, without placing a call:

```
fs_cli -x "lua page_check.lua"
```

## Using it

| You dial | Result |
|---|---|
| `7201` | page zone 1 (`^720([1-9])$` maps the last digit to the zone number) |
| `7202` | page zone 2 |
| a zone that lists several streams | one page, several streams |

`zone_page.lua <zone> [email[,email]] [save]` also accepts optional extra recipients and a `save` flag.

## Recording, email, CDR

If a zone has `save=true` or recipients, the caller's audio is recorded to FusionPBX's call-recording
archive layout and the call's CDR row gets `record_path` and `record_name`, so it plays from the CDR page.
Recipients are sent the recording through FusionPBX's own mail queue. The loopback legs set
`process_cdr=false`, so a page leaves one CDR row, not three to five. A per-zone `transcribe` flag is a
**placeholder** only: it records the page and logs the request. Nothing transcribes yet.

A recording of a page is a record. Check your retention and access rules before enabling it.

## What is and isn't proven

Proven on one flat subnet with two Poly VVX 450 phones:

- per-zone isolation (zone 1 page plays only on the zone 1 phone, zone 2 only on the zone 2 phone)
- one call fanning out to several streams
- IVR zone selection, attention beep, recording, email, CDR link
- editable stream and zone settings, with bad rows rejected

Not tested:

- Mitel (or any non-Poly) phones, and the plain-RTP-to-zone-address path
- zones on different VLANs or subnets (TTL, IGMP, multicast routing)
- simultaneous pages, and any zone-in-use check
- emergency preemption
- transcription (placeholder only)
- Poly channels above 27 (28 and later follow the `25 + N` rule but were not run)

## Security notes

- **Nothing here checks who may page.** Anyone who can dial `7201` in your domain's context can page that
  zone, and `pageleg-<id>` can be dialed directly. Restrict who can reach these entries (for example an
  IVR with a PIN, or limiting them to certain extensions). Do not route inbound trunk calls to them, and do
  not create the entries in the `public` context.
- **Caller ID and name are untrusted.** On a trunk call they can be set by the caller. `zone_page.lua`
  cleans both before using them in the originate command or the email. Keep that if you modify the script.
- **Pages are audio and possibly personal data.** Recordings and emailed copies need an access and
  retention policy.
- Report security problems privately to dddvoip@gmail.com, not in a public issue.

## More

- [docs/poly-phones.md](docs/poly-phones.md): the channel byte, provisioning, verification

## License

MIT, see [LICENSE](LICENSE).
