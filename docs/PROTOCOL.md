# Sony headphone control protocol ("MDR" / Tandem)

Reverse-engineered from **Sony Sound Connect 13.3.0** (`com.sony.songpal.mdr`, base.apk
SHA-256 `58837826f5f145cd0ad9689a298d2bfe9702f4d51d6d4e67d41440175ec0892c`) with REA/JADX.
Class names in brackets are the (partly obfuscated) classes in that build, so this can be re-checked
against newer versions.

Everything here is **static analysis** of the app. It has been verified against an in-process simulator
(`SimulatedSonyV1Device`), **not yet against real hardware**. The byte-exact test vectors in
`Tests/SonyMDRTests` are the executable form of this document. Port them first when moving to another language.

## 1. Transport

Classic Bluetooth **RFCOMM** (SPP-style). The app looks up one of two SDP service UUIDs
[`lm0.i`] and tries them in this order:

| Service UUID | Command table | Devices (generation) |
|---|---|---|
| `956C7B26-D49A-4BA8-B03F-B17D393CB6E2` | table set **2** | WH-1000XM5, XM6, WF-1000XM5 and newer |
| `96CC203E-5068-46AD-B32D-E316F5E069BA` | table set **1** | WH-1000XM4, WF-1000XM4 and older |

The service that answers decides the table set [`com.sony.songpal.mdr.platform.connection.connection.l1`].
The app also carries byte-reversed spellings (`E2B63C39-…`, `BA69E0F5-…`) of the same UUIDs.
(BLE GATT variants exist too, e.g. `5b833e20-…` "TANDEM_V2_HPC_SERVICE"; they are not used here.)

## 2. Framing [`qm0.a`, `qm0.b`, `cp0.b`, `cp0.f`, `qm0.e`]

```
3E | escape( type:u8  seq:u8  len:u32be  payload[len]  checksum:u8 ) | 3C
```

* `checksum` = sum of all bytes from `type` to the end of the payload, mod 256.
* Escaping inside the frame: `3C → 3D 2C`, `3D → 3D 2D`, `3E → 3D 2E`. Unescape: `3D x → x | 0x10`.

Data types [`com.sony.songpal.tandemfamily.message.DataType`]:

| byte | name | needs ACK |
|---|---|---|
| `00` | DATA | yes |
| `01` | ACK | no |
| `0C` | DATA_MDR (command table 1, both table sets) | yes |
| `0D` | DATA_COMMON | yes |
| `0E` | DATA_MDR_NO2 (command table 2: voice guidance, peripherals, …) | yes |
| `1C` / `1E` | SHOT_MDR / SHOT_MDR_NO2 | no |
| `2C` | LARGE_DATA_MDR | yes |

## 3. Sequencing and ACKs [`lm0.c`]

Stop-and-wait with a 1-bit sequence number:

* Send DATA with the current `seq` (starts at 0) and wait for an ACK. On timeout, resend the same frame
  (the app resends a fixed number of times, then drops the connection).
* The ACK carries the **next** sequence number. Adopt it. An ACK whose seq equals the current one is invalid.
* Every received DATA frame is ACKed with `seq' = 1 - seq` (`cp0.d.a`), e.g. received seq 0 →
  `3E 01 01 00 00 00 00 02 3C`.
* A received DATA frame with the same seq as the previous one is a duplicate. ACK it, then drop it.

## 4. Payloads

Byte 0 of every payload is the **command**. Most commands come in families:
`GET_CAPABILITY / RET_CAPABILITY / GET_PARAM / RET_PARAM / SET_PARAM / NTFY_PARAM` with byte 1 = an
"inquired type" that selects the sub-feature. `NTFY_*` arrive unsolicited when something changes on
the device, for example when you press the NC button.

### 4.1 Table set 1 (XM4) [`…mdr.v1.table1.Command`, payloads in `tm0.*`, bodies in `vm0.*`]

| Purpose | Request | Response / notify |
|---|---|---|
| Protocol info | `00 00` | `01 00 vv vv` |
| Model name | `04 01` | `05 01 len "WH-1000XM4"` |
| Firmware | `04 02` | `05 02 len "x.y.z"` |
| Supported functions | `06 00` | `07 00 n f1 … fn` (FunctionType list, see below) |
| Battery | `10 tt` (0 single, 1 L/R, 2 case) | `11`/`13 00 pct chg` · `11`/`13 01 L chg R chg` |
| Codec | `18 00` | `19`/`1B 00 codec` (01 SBC, 02 AAC, 10 LDAC, 20 aptX, 21 aptX HD) |
| NC/ASM capability | `60 02` | `61 02 ncSettingType ncSteps asmSettingType n (asmId steps)*` |
| NC/ASM get | `66 02` | `67`/`69 02 effect ncType ncValue asmType asmId asmLevel` |
| NC/ASM set | `68 02 effect ncType ncValue asmType asmId asmLevel` | |
| EQ capability | `50 01` | `51 01 bandCount levelSteps n (presetId nameLen name)*` |
| EQ band info | `5A 01` | `5B 01 n (kind u16be)*`, kind 01 Hz · 02 kHz×10 · 10 special (1 = Clear Bass) |
| EQ get | `56 01` | `57`/`59 01 presetId n band*` |
| EQ preset | `58 01 presetId 00` | |
| EQ bands | `58 01 FF n band*` (raw steps, centre = (levelSteps-1)/2) | |
| Speak-to-Chat | `F6 05` / set `F8 05 01 on` | `F7 05 00 on` · `F9 05 01 on` |
| Speak-to-Chat details | `FA 05` / set `FC 05 00 sens voiceFocus timeout` | `FB`/`FD 05 00 sens vf timeout` |
| Auto power off | caps `F0 04` → `F1 04 n id*`; get `F6 04`; set `F8 04 01 active selectTime` | `F7`/`F9 04 01 active selectTime` |
| DSEE | caps `E0 02` → `E1 02 type …`; get `E6 02`; set `E8 02 00 on` | `E7`/`E9 02 00 on` |
| Connection priority | get `E6 01`; set `E8 01 00 v` (0 sound, 1 connection) | `E7`/`E9 01 00 v` |
| General settings | caps `D0 id lang`; get `D6 id`; set `D8 id 01 on` | see below |

**NC/ASM fields:** `effect` `00` off · `01` on · `10` slider being dragged · `11` change completed.
Sound Connect sends `01` when a mode *button* is tapped (`NcAsmSendStatus.ON` in
`ModeNcAsm…DetailView.z()`). That is the variant where the headphones announce the mode. Slider and checkbox
changes use `10`/`11` and are silent. Table set 2 has no equivalent (`ValueChangeStatus` is only changing/changed).
`ncSettingType` `00` on/off · `02` dual/single/off, so `ncValue` `00` off · `01` single (wind) · `02` dual (full NC).
`asmSettingType` `00` on/off · `01` level (`asmLevel` 1…20). `asmId` `00` normal · `01` voice focus.
Sony's controllers (`v30.b/c/d/e`) always send inquired type 2 and pick the setting types from the
capability.

**General settings** (`D1`, `D2`, `D3`) describe themselves:
`D1 id format len title len subtitle settingType …`. If `format == 02` (ENUM_NAME), `title` is a key
such as `TOUCH_PANEL_SETTING`, `VOICE_GUIDANCE_SETTING` or `MULTIPOINT_SETTING` (`GsTitleTitle`).
`settingType` `01` = boolean. Values: `D7`/`D9 id 01 on`.

**Auto power off ids:** `00` 5 min · `01` 30 min · `02` 60 min · `03` 180 min · `10` when taken off · `11` disabled.

**Useful FunctionType codes:** `11` battery · `13` codec · `15` L/R battery · `18` case battery ·
`51` preset EQ · `53` non-customizable EQ · `61` NC · `62` NC+ASM · `63` ASM · `D1–D3` general settings ·
`E1` connection mode · `E2` DSEE · `F3` control by wearing · `F4` auto power off · `F5` speak-to-chat ·
`F6` assignable keys.

### 4.2 Table set 2 (XM5+) [`…mdr.v2.table1.*`]

Same command numbering, with these differences:

* Battery moved to **POWER**: `22 tt` → `23`/`25 tt pct chg …` (same body as table 1).
* Codec is a COMMON status: `12 02` → `13`/`15 02 codec` (adds `30` LC3).
* NC/ASM has new inquired types. The body is `type change on [fields]`, where `change` is `00` while dragging and `01` when done:
  * `17` (dual NC, seamless ASM, e.g. XM5): `68 17 change on mode(00 NC / 01 ASM) asmMode(00/01 voice) level`
  * `19` (same + noise-adaptive): adds `adaptiveOn sensitivity`
  * `22` (ASM only): `68 22 change on asmMode level`
* EQ uses inquired type `00` for preset EQ: `56 00` → `57 00 preset n band*`, set `58 00 …`.
  The capability `51 00 …` layout is the same as in table 1.
* **On/off values are inverted** (`OnOffSettingValue`: ON = `00`, OFF = `01`).
  Speak-to-chat: `F8 0C onOff 01`, `F7`/`F9 0C onOff …`.

Table set 2 support functions are typed per table, so this implementation probes features instead
(unsupported GETs are ACKed but never answered).

More table set 2 commands:

| Purpose | Request | Response / notify |
|---|---|---|
| Auto power off | caps `20 04` → `21 04 n id*`; get `26 04`; set `28 04 active sel` | `27`/`29 04 active sel` (no leading `01`) |
| | ids: `00` 5 min · `01` 30 min · `02` 60 min · `03` 180 min · `04` 15 min · `11` off (type `05`: also `10` when taken off) | |
| DSEE | get `E6 01`, set `E8 01 v` (`00` off, `01` auto, **not** inverted) | `E7`/`E9 01 v` |
| Connection mode | get `E6 00`, set `E8 00 p` (`00` sound, `01` connection, `02` low latency) | `E7`/`E9 00 p` |
| Pause when taken off | get `F6 01`, set `F8 01 v` (`00` = on) | `F7`/`F9 01 v` |
| Speak-to-Chat details | get `FA 0C`, set `FC 0C sens timeout` | `FB`/`FD 0C sens timeout` |
| General settings | caps `D0 id lang` → `D1 id settingType format len title len subtitle …`; get `D6 id`; set `D8 id 00 v` | `D7`/`D9 id 00 v` (`00` = on) |
| Voice guidance (table 2) | get `46 tt`, set `48 tt v` (type `02`: `48 02 v lang`) | `47`/`49 tt v …` (`00` = on) |

General settings in table set 2 differ from table set 1. Setting type is `00` bool / `01` list,
string format is `00` raw / `01` enum, and the setting type comes *before* the strings.

### 4.4 NC Optimizer (table set 1, FunctionType `81`)

`80 01` → capability · `82 01` → `83 01 common status` · start `84 01 00 01`, cancel `84 01 00 00` ·
progress arrives as `85 01 common status`. Status: `00` idle, `01` measuring fit, `02` measuring air pressure,
`10` optimizing, `11` done.

### 4.3 More table set 1 features

| Purpose | Request | Response / notify |
|---|---|---|
| Pause when taken off (FunctionType `F3`) | get `F6 03`, set `F8 03 00 v` (`01` on) | `F7`/`F9 03 00 v` |
| Button capability (FunctionType `F6`) | `F0 06` | `F1 06 nKeys { key keyType defaultPreset nPresets { preset nActions { action function } } }` |
| Button assignment | get `F6 06`, set `F8 06 n preset[n]` | `F7`/`F9 06 n preset[n]` |
| Playback capability (FunctionType `A1`) | `A0 01` | `A1 01 maxVolume ctrlType metaType` |
| Play status | `A2 01` | `A3`/`A5 01 common play` (common `00` = available; play `01` playing, `02` paused) |
| Play control | `A4 01 00 c` (`01` pause, `02` next, `03` previous, `07` play) | |
| Volume | get `A6 01 20`, set `A8 01 20 v` | `A7`/`A9 01 20 v` |
| Track / artist | `A6 01 00` / `A6 01 02` | `A7 01 tt status len utf8` (`A9 01 tt` = changed, ask again) |
| Voice guidance (table 2, data type `0E`, FunctionType `39`) | get `46 01 01`, set `48 01 01 v` | `47`/`49 01 01 v` |

Button sets carry one slot per key in capability order. `FE` means "leave unchanged".
Keys: `00` left, `01` right, `02` custom (the XM4's NC/AMB button), `03` C. Key type `00` touch, `01` button.
Presets: `00` ambient sound control, `10` volume, `20` playback, `30` phone voice assistant,
`31` Google Assistant, `32` Alexa, `33` Tencent Xiaowei, `FF` none.
"Pause when taken off" is not in the app's Java enums. It comes from the Kotlin `V1ControlByWearingRepository`.
Table-2 requests are length-checked by the device, so extra bytes are not tolerated.

Table 2 also has paired-device management (`30`–`3D 01 …`: device list, connect/disconnect/unpair, pairing mode).
It's documented in the research notes but not implemented yet.

## 5. Not implemented yet (known to exist in the app)

Paired-device management (table 2), voice-guidance language and volume, list-type general settings,
Adaptive Sound Control, the table set 2 NC optimizer, 360 Reality Audio and firmware updates.
