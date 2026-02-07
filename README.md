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
- `gesturePushing.lua` – Gesture based pushing/shoving, do a push gesture with both hands to activate the ingame push/kick action.
- `Melee rate scale.lua` – Modified version of Vinion's original script, to prevent accidental attack action after a push/shove gesture.
- `gestureBlocking.lua` – Gesture based blocking system, hold left or both hands up in front of your face with the palm facing outward to block. Can be configured.
- `counterAimFix.lua` – Controls aiming method after a block, to prevent character turning around while swinging on a counter attack.

## Credits

- **Vinionsinho** – Dead Island 2 VR profile
- **Praydog** – UEVR
