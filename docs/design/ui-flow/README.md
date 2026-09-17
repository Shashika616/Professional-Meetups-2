# TieHere UI flow (real screens)

The actual app, captured screen by screen from the debug build on a Pixel 8
emulator (1080x2400) against the local stack on 2026-09-17, for UI/UX
review. Light mode throughout, plus a dark-mode set (ids 9x). Accounts used:
Test L3 Alpha (hosting), Test L2 Bravo (verified member, requester), two
brand-new email sign-ups (L1) and a guest (L0).

- `TieHere-UI-flow.excalidraw`: every capture as an image on one board, rows
  by area, with an arrow from each control's real position to the screen it
  opens, labelled with the control and its gate. Open at excalidraw.com
  (File > Open) or with the VS Code Excalidraw extension. 11 MB; the images
  are embedded.
- `tiehere-ui-flow.html` + `img/`: the same captures as a clickable
  walkthrough (each control is a hotspot at its real bounds) and a map.
  Published as a private artifact.
- `shots/`: the full-size PNG captures (113). Drag these into Figma to get
  the frames there.
- `dumps/`: the accessibility tree (uiautomator) of each screen, which is
  where the hotspot rectangles come from.
- `flow.py`: the screen list and every link; `build_excalidraw.py` and
  `build_html.py` regenerate both outputs from it.

Regenerate after a UI change: recapture the affected shots (see
TESTING-NOTES for the emulator recipe), re-run `python3 flow.py` to check
every link still resolves, then the two build scripts.
