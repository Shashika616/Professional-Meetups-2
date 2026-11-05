# TieHere icon — colourways

Eighteen colourways of the app icon. Every file carries the same two traced
paths as `../../tiehere-app-icon.svg` (via `frontend/assets/images/brand/`),
so only the colours change — never the shape. Each is a 1024×1024 SVG plus a
1024×1024 PNG on the 224-radius rounded square the shipping icon uses.
`_contact-sheet.png` shows them all side by side.

File names read `<left figure>-<right figure>-on-<ground>`; `mono` means both
figures share one colour.

## Colours (all from `AppPalette`)

| Name | Hex | Token |
| --- | --- | --- |
| green | `#34C24C` | `brandGreen` |
| blue | `#0075F6` | `brandBlue` |
| onyx (black) | `#070D15` | dark theme `onyx` |
| white | `#FFFFFF` | |
| mist | `#F0F4F8` | light theme `onyx` (the light ground) |
| deep green | `#17803D` | light theme `solid` — used on mist, where brand green is too pale |
| navy | `#101B29` | dark theme `surface` — top of the navy gradient |

## Set

| Ground | Variants |
| --- | --- |
| Onyx | white-green (current dark icon), blue-green, white-blue, green mono, white mono |
| White | onyx-green (current light icon), blue-green, onyx-blue, onyx mono |
| Mist | onyx + deep green |
| Green | white-onyx, white mono, onyx mono |
| Blue | white-onyx, white mono |
| Gradients | white-green on navy→onyx, white mono on blue→green, onyx mono on green→blue |

Green-on-blue pairings are left out on purpose: the two brand colours are too
close in brightness (about 2:1 contrast) for one to read on the other.

## In the app

The app ships `tiehere-icon-blue-green-on-onyx` as its default icon and
`tiehere-icon-blue-green-on-white` as the light-theme icon. The home screen
icon follows the in-app theme. The rest here are design assets.
