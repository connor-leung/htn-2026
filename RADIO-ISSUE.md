# `badge.radio.enable()` always fails — evidence for the badge team

**Firmware:** `v0.1.2-392-gd3089c4`

**Summary:** `badge.radio.enable()` returns false in every Lua app we have
tried, down to a 1.2 KB app that does nothing else. The built-in **Share** app
uses Bluetooth successfully on the same badge, so the radio hardware works.

## Console output

```
E BLE_INIT: nimble host init failed
E hal_radio: nimble_port_init: ESP_FAIL
I app_reg: heap after enter Goose Ping: free=36380 largest=21504
I app_reg: launched Goose Ping
```

The app keeps running; only the radio is unavailable.

## What was tried

| Variable | Tested | Result |
| --- | --- | --- |
| App size | 17 KB app → 1.2 KB app (`radio_min`, ~5 KB compiled) | fails either way |
| Allocation order | `enable()` as the first statement of `on_enter`, before any widget | free heap at the call rose ~5 KB; still fails |
| Garbage | 12 × `badge.sys.gc_step()` immediately before the call | no change |
| `heap_kb` | 48 | BLE memory is system heap, not the Lua quota |
| `wake_lock=1` in the manifest | copied from the guide's own `demo_radio` example, applied after a Reboot | still fails |
| Power | USB and battery, battery charged | fails on both |
| Built-in Share (Bluetooth) | same badge | **works** |

Reported free heap at the moment of the call was 41,052 bytes in the larger
app, with the largest contiguous block at 21,504.

## Battery-specific note (resolved separately)

Before the badge was charged, the same `enable()` call **crashed** the badge on
battery — screen freeze followed by a restart — while failing cleanly on USB.
After charging it fails cleanly on both. That is consistent with a current
spike during BLE init browning out a low cell, and may be worth knowing
independently of the init failure itself.

## Question for the team

Is `badge.radio` expected to work on `v0.1.2-392-gd3089c4`, or does it need a
newer firmware? The guide's Share troubleshooting notes that "older firmware
can exhaust Bluetooth's advertising memory even for a small app", which matches
this exactly — but we would rather confirm than assume.

## Reproduce

`apps/radio_min/` in this repo — 1,197 bytes including the manifest header.
Import it, Reboot, open it. It prints `RADIO OK` or `RADIO FAILED` plus the
free heap either side of the call.
