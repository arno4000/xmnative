# Bose headphone control protocol ("BMAP")

Reverse-engineered from the **Bose app 13.4.2** for Android (`com.bose.bosemusic`, base.apk SHA-256
`0468688c21ac7f3377e705c52541c040e51fcd018209eb903f329f7603c61342`) with JADX. The BMAP library in the app
is not obfuscated (`com.bose.bmap.*`), so the class names below can be looked up directly.

Everything here comes from **static analysis** of the app and has been tested on a QuietComfort Ultra
Headphones (2nd Gen). `Tests/BoseBMAPTests` holds the byte-exact vectors and an in-process simulator
(`SimulatedBoseDevice`).

Target device: QuietComfort Ultra Headphones (2nd Gen), codename "Wolverine", product ID `0x4082`.

## 1. Transport

Classic Bluetooth RFCOMM on the standard **Serial Port Profile** UUID `00001101-0000-1000-8000-00805F9B34FB`
(`SppConnectionManager`). The app also has BLE and LE CoC transports, which this app doesn't use.

SPP is generic, so the app only uses it on devices that look like Bose: they advertise one of Bose's 16-bit
service UUIDs `0xFEBE` / `0xFDD2` or a UUID starting `F4C93A79-D04F-4565` (`BluetoothService.isBoseDevice`),
or have a Bose-like name.

## 2. Packets [`BmapPacket`]

```
fblock:u8  function:u8  (deviceID << 6 | port << 4 | operator):u8  length:u8  payload[length]
```

There is no framing, checksum, sequence number or ACK. A read can carry several packets back to back, and
the app splits them by the length byte. Device ID and port are 0 for everything here.

| operator | | |
|---|---|---|
| 0 Set | 1 Get | 2 SetGet |
| 3 Status | 4 Error | 5 Start |
| 6 Result | 7 Processing | |

* Get → one Status.
* SetGet → one Status with the new value. The app uses SetGet for every setting, never plain Set.
* Start → optional Processing, any number of Status packets, then a Result.
* Error payload: `[code]` or `[FF][block-specific code]`. Codes (`BmapPacketError`): 3 block not supported,
  4 function not supported, 5 operator not supported, 6 invalid data, 7 data unavailable, 10 invalid state,
  12 busy, 20 insecure transport.

Function blocks: 0 ProductInfo, 1 Settings, 2 Status, 4 DeviceManagement, 5 AudioManagement, 7 Control,
9 Notification, 18 Authentication, 31 AudioModes.

Bitsets (`BitSetUtil`) are big-endian byte arrays: bit *i* is bit `i % 8` of byte `len - 1 - i / 8`.

## 3. Connecting

Same order as the app:

1. `00 01 01 00` ProductInfo.BmapVersion Get → UTF-8 string ("1.4.0").
2. `00 02 01 00` ProductInfo.AllFblocks Get → bitset of the supported function blocks.
3. ProductInfo.ProductIdVariants (fn 3) → `[pid hi][pid lo][variant]`. FirmwareVersion (fn 5) → UTF-8.
4. If block 9 is supported: `09 02 02 len 01 <bitset of blocks>` Notification.ByFblock SetGet, `01` = enable.
   After this the headphones send Status packets on their own when something changes on them.
5. Read the settings below. Unsupported functions answer with Error 4 quickly.

The app also has a cloud "activation" / challenge flow in block 18. It isn't needed for the settings here
(nothing in the app gates them on it), and the QC Ultra Headphones (2nd Gen) work without it.

## 4. Audio modes (block 31) — noise cancelling on the QC Ultra family

| fn | name | |
|---|---|---|
| 2 | Capabilities | Status `[bose modes][user modes][..][..][..][flags][min favorites]` |
| 3 | CurrentMode | Get → Status `[mode]`. Switch: Start `[mode][play voice prompt 0/1]` |
| 6 | ModeConfig | Start (no payload) → one Status per mode, then Result. Get `[mode]` → one Status |
| 8 | Favorites | Status / SetGet `[number of modes][bitset]` — the modes the headphones' mode button cycles through |
| 9 | Reset | Start `[mode]` → Result. Clears a user mode |
| 10 | SettingsConfig | Status / SetGet `[cnc][auto cnc][spatial][wind block][anc]` — noise control outside of modes |
| 11 | NamesSupported | Status: bitset of prompt ids a user mode may use |

**Capabilities Status** (`AudioModesCapabilitiesResponse`): `[0]` Bose modes, `[1]` user mode slots, `[5]` flags
(bit0 CNC, bit1 auto CNC, bit2 spatial audio, bit3 wind block, bit4 favorites, bit5 ANC toggle), `[6]` minimum
number of favorites. The number of modes used in the Favorites payload is `[0] + [1]`.

**ModeConfig Status** (`AudioModesModeConfigResponse`), 44–48 bytes:

| offset | |
|---|---|
| 0 | mode index |
| 1–2 | prompt (`AudioModesPrompt`): `00 01` Quiet, `00 02` Aware, `00 22` Immersion, `00 23` Stereo, `00 24` Cinema, … |
| 3 | user configurable (a user mode slot) |
| 4 | user configured (slot in use) |
| 5 | favorite |
| 6–37 | name, 32 bytes UTF-8, NUL-terminated |
| 41 | mutable flags: bit0 CNC level, bit1 auto CNC, bit2 spatial audio, bit3 wind block, bit4 ANC toggle |
| 42 | CNC level |
| 43 | auto CNC |
| 44 | spatial audio: 0 off, 1 fixed to room ("still"), 2 fixed to head ("motion") |
| 46 | wind block |
| 47 | ANC toggle |

Bose's own modes show the prompt's name. User modes show the stored name.

**CNC level: 0 is the most cancelling.** The app shows "Noise Cancellation" = `steps − 1 − level`
(`BmapCncLevelConfig.mapBetweenCncLevelAndWorldVolume`), and labels 8–10 on that scale "blocks most outside
sounds" (`C4559Np1.O`). The number of steps comes from Settings.Cnc (`[steps][level][flags]`), otherwise 11.
Noise control outside of modes always uses 11 steps in the app.

**Bitsets:** Favorites counts from the last byte (mode 0 = last byte bit 0), NamesSupported from the first
(prompt 0 = first byte bit 0; only 5 bytes, last byte bits 0–4).

**ModeConfig SetGet** (`FBlockAudioModesKt.createAudioModesConfigSetGetPayload`), the request layout differs
from the Status:

```
[mode][prompt 2][name 32, NUL-padded][cnc level][auto cnc][spatial][wind block][anc toggle]
```

The last three bytes are optional (they're only sent if the device reported them). Only fields whose mutable
flag is set may change; Bose's own modes keep their prompt and name.

**Managing user modes** (as the Bose app does it):

* A user slot is **free** when its prompt is `00 00` (`C24296zT4.j2`).
* **Create:** ModeConfig SetGet on the first free slot with the chosen prompt, the prompt's name, CNC level 5,
  and auto CNC / spatial / wind / ANC from the slot (`UR4.F`). If favorites are supported, the new mode is
  added to them.
* **Delete:** Reset Start `[mode]`; if that fails, ModeConfig SetGet with prompt `00 00`, empty name and level 5
  (`YQ4.c2` / `YQ4.n2`). Then remove it from the favorites and, if it was active, switch to the first favorite.

**SettingsConfig** is what the app's "Noise Control" screen uses (on/off + strength, and Immersive Audio when
spatial audio is supported). The app offers it whenever the device answers the Get (`C10989el0`, capability
31508).

## 5. Settings (block 1)

| fn | name | Status | SetGet |
|---|---|---|---|
| 2 | ProductName | `[is default][UTF-8 name]` | `[UTF-8 name]` |
| 3 | VoicePrompts | `[lang bits 0-4 \| on << 5 \| …][languages u32]…` | `[lang \| on << 5]` |
| 4 | StandbyTimer | `[minutes][flags: bit0 = not configurable]` (≥3 bytes: minutes = `p[2] << 8 \| p[0]`) | `[minutes]` or `[lo][hi]` |
| 5 | Cnc | `[steps][level][flags]` | — |
| 7 | RangeControl (EQ) | per band `[min][max][value][band]`, signed; band 0 bass, 1 mid, 2 treble | `[value][band]` |
| 9 | Buttons | `[button][event][mode][supported modes ×4]…` | `[button][event][mode]` |
| 10 | Multipoint | `bit0 on, bit1 supported` | `[0/1]` |
| 11 | Sidetone | `[persisted][mode][supported bitset]`; 0 off, 1 high, 2 medium, 3 low | `[1][mode]` |
| 16 | OnHeadDetection | `[bit0 on, bit1-3 supported: auto play, auto answer, auto aware][bit0-2 those on]` | `[on][bits]` |

Standby timer 0 is taken to mean "never" (not confirmed).

## 6. Status (block 2)

* fn 2 BatteryLevel: `[percent][minutes left hi][lo][component]` (repeated for multi-part products).
* fn 5 ChargerDetect: `[1 = charging]`.

## 7. Audio management (block 5)

* fn 3 Control: Start `[value]` → Result. 1 play, 2 pause, 3 next, 4 previous.
* fn 4 Status: `[0 stopped, 1 playing, 2 paused, …]…`.
* fn 5 Volume: Status `[max][current]`, SetGet `[level]`.
* fn 6 NowPlaying: Start → Status `[attribute][UTF-8]` per attribute (0 title, 1 artist, 2 album), then Result.
* fn 15 SpatialAudioMode: Status / SetGet `[0 off, 1 room, 2 head]`. Used only when the current mode doesn't
  carry its own spatial setting.
