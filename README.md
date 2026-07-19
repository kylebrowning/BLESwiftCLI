# ble — a BLE command-line tool

A macOS CLI for scanning, connecting to, and pairing with Bluetooth Low Energy
peripherals, built on [BLESwift](https://github.com/kylebrowning/BLESwift) and
[swift-argument-parser](https://github.com/apple/swift-argument-parser).

## Install

### Homebrew

```sh
brew install kylebrowning/tap/ble
```

### Mint

```sh
mint install kylebrowning/BLESwiftCLI
```

### From source

```sh
swift build -c release
cp .build/release/ble /usr/local/bin/
```

For development builds:

```sh
swift build
.build/debug/ble --help
```

**Permissions:** the first run prompts for Bluetooth access. Grant it to your
terminal app (Terminal, iTerm, etc.) under
*System Settings → Privacy & Security → Bluetooth*.

## Commands

### `ble scan`

```sh
ble scan                          # everything nearby, 10 s
ble scan -s 180D --timeout 0      # heart-rate devices, until Ctrl-C
ble scan --allow-duplicates       # live RSSI updates (+ / ~ / - markers)
ble scan --min-rssi -70           # only strong signals
ble scan --json                   # JSON lines, for scripting
```

Output is a table, one row per sighting: name, RSSI colored by signal strength
(green/yellow/red), the peripheral UUID (what you pass to `connect`/`pair`,
dimmed), advertised services (standard ones labeled, e.g. `180F/Battery`), and
manufacturer data. Colors turn off automatically when stdout is piped, and
respect `NO_COLOR`.

### `ble connect`

```sh
ble connect 6E400001-B5A3-F393-E0A9-E50E24DCCA9E
ble connect "Kyle's Sensor"       # name substring — resolves by scanning
ble connect mydevice -s 180D --reconnect
```

Resolves the peripheral (system cache first, then scanning), connects, prints
the RSSI, and holds the link open — a BLE connection only lives as long as the
process holding it. Lifecycle events stream to the console; Ctrl-C disconnects
cleanly, and `--reconnect` re-establishes the link after unexpected drops.

### `ble pair`

```sh
ble pair mydevice -s <service-uuid> -c <protected-characteristic-uuid>
ble pair mydevice -s <service-uuid> -c <char-uuid> --write 0x01
```

CoreBluetooth has no explicit pairing API. Pairing is triggered by accessing a
characteristic that requires encryption: macOS raises the pairing dialog, and
approving it bonds the devices and lets the pending read/write complete. This
command connects and reads (or `--write`s) the characteristic you point it at.
Unpair via *System Settings → Bluetooth*.

### `ble inspect`

```sh
ble inspect mydevice              # full GATT tree: services, characteristics, descriptors
ble inspect mydevice --read       # also show each readable characteristic's value
ble inspect mydevice --json | jq  # machine-readable dump
```

Enumerates the whole GATT database with no UUIDs needed up front — each
characteristic shows its property flags, and standard SIG attributes are
labeled with their assigned names:

```
Service 180F — Battery
  2A19 — Battery Level  [read, notify] = 0x5A (1 byte, uint 90, "Z")
    Descriptor 2902 — Client Characteristic Configuration
```

`--read` can trigger the macOS pairing dialog if a characteristic is
protected, same as `ble pair`.

### `ble read`

```sh
ble read mydevice -s 180F -c 2A19             # one read: hex + interpretations
ble read mydevice -s 180F -c 2A19 --notify    # stream notifications until Ctrl-C
ble read mydevice -s 180F -c 2A19 --notify --count 5
ble read mydevice -s 180F -c 2A19 -d 2901     # read a descriptor (User Description)
```

Values print as hex with friendly interpretations (byte count, little-endian
unsigned integer, UTF-8 text). `--notify` verifies the characteristic supports
notify/indicate before subscribing and timestamps each value.

### `ble write`

```sh
ble write mydevice -p command.yaml            # structured payload from a file
ble write mydevice -s FFF0 -c FFF1 --hex 0x01FF
ble write mydevice -s FFF0 -c FFF1 --string "hello"
ble write mydevice -p command.yaml --expect-reply-on FFF2   # write, then await notification
ble write x -p command.yaml --dry-run         # just print the encoded bytes
ble write mydevice -s FFF0 -c FFF1 -d 2901 --string "label"   # write a descriptor
```

Before writing, the characteristic's advertised properties are checked: a
non-writable target fails with a clear message, and with/without-response is
chosen automatically from the characteristic's capabilities (`--without-response`
forces it). Payloads larger than the link's maximum write length produce a
warning.

#### Payload files

YAML or JSON (both parse through the same decoder). Fields are encoded in
order and concatenated. Integers are `u8`–`u64` / `i8`–`i64` with an optional
`le` (default) or `be` suffix. The file may carry its own target, which
`-s`/`-c` flags override — see [Examples/example-payload.yaml](Examples/example-payload.yaml):

```yaml
service: 180F
characteristic: 2A19
writeType: withResponse        # optional
fields:
  - { type: u8,     value: 1 }
  - { type: u16le,  value: 5000 }
  - { type: i32be,  value: -70 }
  - { type: string, value: "hello" }
  - { type: hex,    value: "DEADBEEF" }
  - { type: pad,    length: 2 }
```

### `ble l2cap`

```sh
ble l2cap mydevice --psm 0x0080                    # open channel, hex-dump incoming
ble l2cap mydevice --psm 128 --send-hex 0x01FF     # send once, then stream
ble l2cap mydevice --psm 128 --raw > capture.bin   # raw bytes for piping
```

Opens a connection-oriented L2CAP channel and streams it until Ctrl-C or the
peripheral closes it.

## Testing

```sh
swift test
```

No hardware needed. Pure logic (payload encoding, hex/UUID parsing, value
formatting) is tested directly; peripheral resolution and radio readiness run
against BLESwift's own `BLESwiftTestSupport` fakes (`FakeCentral` /
`FakePeripheral`) with scripted state changes and advertisement discoveries.

## Output conventions

Progress and status messages go to **stderr**; data (scan lines, values, JSON,
raw L2CAP bytes) goes to **stdout** — so `ble scan --json | jq` and
`ble inspect x --json > gatt.json` stay clean.
