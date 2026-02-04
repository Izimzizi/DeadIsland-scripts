# Dead Island 2 – UEVR Scripts

This repository contains **Lua scripts for Dead Island 2** designed to be used in conjunction **Vinion’s Dead Island 2 VR profile** with UEVR.

These scripts are aiming to enhance the VR experience in Dead Island 2.

## Requirements

- Dead Island 2 (PC)
- UEVR
- Vinion’s Dead Island 2 VR profile  
  https://github.com/vinionsinho/DeadIsland2VR

## Installation

1. Import Vinion’s Dead Island 2 VR profile.
2. Copy the scripts from this repository into:`~\UnrealVRMod\DeadIsland-Win64-Shipping\scripts`

## Scripts

- `audioSpatialFix.lua` – Forces the audio listener to follow the HMD correctly.
- `disableShakes.lua` – Disables camera shake effects and camera animations to reduce VR motion discomfort.
- `gestureBlocking.lua` – Gesture-based blocking system.
  Hold left hand in front of your face with the palm facing outward to block (default).
  Supports left hand, right hand, or two-handed blocking.
  Palm-facing requirement can be disabled or loosened.
  Includes a tight and a loose preset for customizing block activation tresholds.


## Credits

- **Vinionsinho** – Dead Island 2 VR profile
- **Praydog** – UEVR
