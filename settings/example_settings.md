# Settings rows

Add these in **FusionPBX > Advanced > Default Settings**. Category `paging`, Type `array`, Enabled true.
One row per item. `page_check.lua` reports any row it rejects.

## Streams

Subcategory `stream`, value:

```
id|address|port|control_port|poly_channel[|ttl]
```

| Field | Rule |
|---|---|
| id | letters and digits; unique |
| address | multicast, 224.x.x.x to 239.x.x.x |
| port, control_port | 1024 to 65535 |
| poly_channel | 1 to 254 (Poly paging group N is channel 25 + N) |
| ttl | 1 to 255, default 4 |

`address:port`, `control_port` and `poly_channel` must each be unique across streams.

## Zones

Subcategory `zone`, value:

```
number|name|stream ids|save|recipients[|transcribe]
```

| Field | Rule |
|---|---|
| number | digits; unique. `7201` pages zone 1, `7202` zone 2 |
| name | any text |
| stream ids | comma separated; every id must exist |
| save | `true` or `false` (record the page and link it to the CDR) |
| recipients | email addresses separated by `;` or `,`; may be empty |
| transcribe | `true` or `false`, default false. **Placeholder only** (records and logs) |

## Example: two zones and an all-zones zone

| Subcategory | Value |
|---|---|
| `stream` | `1\|239.1.1.11\|5001\|6061\|26\|4` |
| `stream` | `2\|239.1.1.12\|5001\|6062\|27\|4` |
| `zone` | `1\|Zone 1\|1\|true\|` |
| `zone` | `2\|Zone 2\|2\|true\|` |
| `zone` | `3\|All Zones\|1,2\|true\|office@example.org` |

Paging a single stream still takes a stream row and a zone row. An "all zones" zone is just a zone that
lists every stream.

## Check

```
fs_cli -x "lua page_check.lua"
```

## Inserting by SQL instead of the GUI (optional)

```sql
insert into v_default_settings
  (default_setting_uuid, default_setting_category, default_setting_subcategory, default_setting_name,
   default_setting_value, default_setting_order, default_setting_enabled, insert_date)
values
  (gen_random_uuid(), 'paging', 'stream', 'array', '1|239.1.1.11|5001|6061|26|4', 1, 'true', now()),
  (gen_random_uuid(), 'paging', 'zone',   'array', '1|Zone 1|1|true|',            1, 'true', now());
```

Back up the table before you change it by hand.
