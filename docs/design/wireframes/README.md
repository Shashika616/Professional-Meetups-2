# TieHere wireframes

Every screen and every tap in the app, read off `frontend/lib/features/**`
on 2026-09-17.

- `TieHere-wireframes.excalidraw`: the board. Open at excalidraw.com
  (File > Open) or with the VS Code Excalidraw extension. One phone frame per
  screen, rows by area, arrows bound to the control they leave from and the
  screen they reach, labelled with the gate where one applies.
- `tiehere-flow.html`: the same screens as a clickable walkthrough plus a
  flow map. Published as a private artifact; the file is self-contained.
- `screens.py`: the single source both are generated from. Change a label
  or an arrow here, then run `python3 build_excalidraw.py` and
  `python3 build_html.py` in this folder.

Trust gates used throughout: L0 guest (view only), L2 (phone + personal
email + personal details) can join and use SOS, L3 (organisation + work
email) can host, L4 reserved for ride share and dating ("coming soon").
