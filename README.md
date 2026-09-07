# mpv-dlss5

Enable NVIDIA DLSS 5 Neural Rendering (DLAA mode) in [mpv](https://mpv.io/) by bundling a pre-configured ReShade add-on setup alongside the player.

This repository contains the build scripts that package all required components — ReShade (add-on build), DLSS5-Feeder, LumeniteFX (motion vectors), the renodx-dlss5 add-on, and NVIDIA DLSS runtime DLLs — into a ready-to-use download.

## Requirements

- A PC with an NVIDIA RTX GPU (Neural Rendering requires an RTX card)
- Windows
- [mpv](https://mpv.io/) (the standard Windows build)

## Installation

1. Download one of the nightly builds:
   - `mpv-dlss5.zip`: https://github.com/ahaoboy/mpv-dlss5/releases/download/nightly/mpv-dlss5.zip
   - `mpv-dlss5.tar.xz`: https://github.com/ahaoboy/mpv-dlss5/releases/download/nightly/mpv-dlss5.tar.xz
2. Extract the archive into the folder that contains `mpv.exe`.
3. Launch mpv as usual.

## Usage

1. Start playing a video and press **Home** to open the ReShade menu.
2. In the ReShade menu:
   - **Add-ons** tab → enable **"DLSS 5 Neural Rendering"**.
   - **Effects** list → make sure `Lumenite_Kernel` is listed **above** `DLSS5_Feed`.
3. Check `dlss5-feed.log` for `feature ready ... DLAA` to confirm it is active.

### Hotkeys (default)

| Key | Action |
| --- | --- |
| `Home` | Toggle the ReShade overlay |
| `F6` | Toggle Neural Rendering (add-on hotkey) |
| `F5` | Save a screenshot (add-on hotkey) |

## Notes

- All components (ReShade, shaders, add-ons, NVIDIA runtime DLLs) are downloaded from the internet and are the property of their respective authors. This project does not modify or host them — it only bundles and distributes them for convenience.
- The prebuilt release is a nightly build and may not always be up to date.
- Reinstall by deleting `dxgi.dll`, the `reshade-shaders` folder, the `.addon64` files, and the NVIDIA DLLs from your mpv folder, then repeating the steps above.

## Disclaimer

This project is not affiliated with NVIDIA, ReShade, or the mpv project. Use at your own risk.
