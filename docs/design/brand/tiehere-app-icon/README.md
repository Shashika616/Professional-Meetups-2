# TieHere icon — colourway variants

The mark is two interlocking figures. The original pairs brand green with
`#0075F6`; these drop that blue and pair the green with white or with the
app's own near-black instead.

Nothing about the geometry changed. Every file here carries the same two
traced paths as `../tiehere-app-icon.svg`, so the silhouette, the counters
and the overlap are identical across the set.

## Colours

| Token | Hex | Where it comes from |
| --- | --- | --- |
| Brand green | `#34C24C` | `AppPalette.brandGreen` — unchanged |
| Onyx | `#070D15` | `AppPalette.onyx`, the dark theme's ground |
| White | `#FFFFFF` | |

## Files

| File | Figures | Ground |
| --- | --- | --- |
| `tiehere-icon-green-white.svg` | green + white | transparent |
| `tiehere-icon-green-black.svg` | green + onyx | transparent |
| `tiehere-icon-green-white-on-black.svg` | green + white | onyx, 224r rounded square |
| `tiehere-icon-green-black-on-white.svg` | green + onyx | white, 224r rounded square |
| `tiehere-icon-green-white-on-black.png` | green + white | onyx — 1024×1024 RGBA |
| `tiehere-icon-green-black-on-white.png` | green + onyx | white — 1024×1024 RGBA |

The transparent pair is for placing the mark on something else. The two
with a ground are the icon proper: same 224pt corner radius as the
existing icon, so they drop into the same slots.

A white mark on a transparent ground is invisible against white — use
`-on-black` wherever the backdrop is not controlled.

## Not wired into the app

These are design assets. The shipping launcher icons are still generated
from the blue original; swapping them is a separate change to
`android/app/src/main/res/` and `ios/Runner/Assets.xcassets/`.
