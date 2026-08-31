# Superseded prototype setup

Use [cc-quarry-setup.md](cc-quarry-setup.md) for the current three-turtle
wireless quarry system.

# ATM10 Wireless Mining Station Setup

## Hardware layout (your computer)

From the photo, peripherals attach like this:

| Side   | Peripheral        |
|--------|-------------------|
| Top    | 3x5 Monitor       |
| Left   | Speaker           |
| Any free side | Wireless Modem |

The advanced computer auto-detects adjacent peripherals — no manual "attach" call is needed. The scripts use `peripheral.find()` and scan sides automatically.

## Install

1. On the **advanced computer**, save `cc-mining-station.lua` as `mining_station` (no extension).
2. On the **wireless mining turtle**, save `cc-mining-turtle.lua` as `mining_turtle`.
3. Start the **base station first**, then the turtle.

```text
> mining_station
> mining_turtle
```

## Pairing (fully wireless)

- Both scripts use rednet protocol `atm10_mining`.
- The turtle broadcasts `hello` until the station replies with `ack`.
- No cables required — only wireless modems in range (64 blocks default in CC:Tweaked).

If auto-pair fails, set IDs manually:

- Run `id` on each device.
- On the turtle script, set `BASE_ID = <station id>`.
- On the station script, set `TURTLE_ID = <turtle id>`.

## What you'll see / hear

| Event              | Monitor                    | Speaker                          |
|--------------------|----------------------------|----------------------------------|
| Block mined        | Counts update, top list    | —                                |
| Ore detected       | "Ore found!" + last ore    | Experience orb + pling chime     |
| Fuel low           | Fuel line turns warning    | 3 low bass notes                 |
| Out of fuel        | "NEEDS FUEL"               | Alert repeats when fuel updates  |

Ore detection matches names containing `ore`, plus a few extras (ancient debris, glowstone, etc.).

## Excavation size

The turtle runs a **32×32 quarry** (same pattern as the built-in `excavate 32` program).

1. Place the turtle at the **start corner** of the area on the surface.
2. Optional: place a **chest behind** the turtle's starting direction — it dumps there when inventory is full.
3. Fill several slots with **coal/charcoal** — a 32×32 quarry uses a lot of fuel.

Change size at the top of `cc-mining-turtle.lua`:

```lua
local EXCAVATE_SIZE = 32
```

## Fuel

Put coal/charcoal/logs in turtle slots. Auto-refuels when below 200. If it runs out, it stops and pings the station until refueled.

## Tips

- Keep the station computer running — it's the dashboard.
- Stay within ~64 blocks for wireless range.
- Monitor shows depth updates every 5 layers during excavation.
