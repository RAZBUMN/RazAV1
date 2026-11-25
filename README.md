# RazAV1

A Windows app for encoding films to AV1 with SVT-AV1, built for one job: turning grainy Blu-ray
films into small AV1 files that still look like film.

Use it as a plain AV1 encoder with the encoders' own defaults, or with the tuned **RAZ Triangle**
pipeline: crop scan, GPU denoising chosen scene by scene, generated film-grain tables, and a preview
with a size estimate and quality scores before you commit to the full encode.

> **Status:** 1.0 is feature complete. Updates from here are bug fixes.
> RazAV1 is a specialised tool for films and series, not a general video converter.

<!-- Screenshot: the Files page with a film in the queue -->

Windows 10 1803 or newer, 64-bit. Nothing to install by hand: the app downloads and builds
everything it needs into its own folder.

## Your first encode

1. Download `RazAV1_1.0.0.zip` from [Releases](../../releases) and unpack it anywhere
   (a folder of its own, not Program Files).
2. Open **RazAV1.cmd**. On the first start, choose **Tuned [RAZ Triangle]** or **Plain AV1**.
3. Press **Setup and updates > Set up everything**. This downloads ffmpeg and VapourSynth, installs
   the Visual Studio Build Tools with winget if they are missing (a few GB, once) and compiles
   SVT-AV1. Plan about 15 minutes the first time.
4. Drag a film into the queue and press **Start**.
5. The app scans the film, encodes short probes and shows a **preview reel**, the predicted size,
   time and VMAF score. Press **Encode** (or let it start by itself after 60 s).
6. When it's done, **Play** or **Open folder** shows the result, and **History** shows the space saved.

<!-- Screenshot: the Encoding page during an encode -->

## Profiles

| Profile | What it does |
|---|---|
| **RAZ Triangle** | The tuned pipeline: crop scan, adaptive grain plan, KNLMeansCL denoising on the GPU, timed grain tables, extra bits for dark scenes. |
| **RAZ Triangle Classic** | The same with the CPU denoiser hqdn3d, for PCs without a usable GPU. |
| **SVT-AV1 stock**, **SVT-AV1-Essential stock**, **SVT-AV1-HDR stock** | The encoder exactly as its authors ship it. Only what you set in the window is passed on. |

Profiles are plain text files in `profiles\`. **Save as...** turns the settings of a file into a new
profile, or copy one and edit it in Notepad. Your file handling (audio, crop, output folder and
name) comes from **Settings > Defaults** for every profile that leaves those blank, so the stock
profiles get your habits but not the picture tuning.

## Encoders

| Encoder | What it is |
|---|---|
| **SVT-AV1** | The official encoder from the Alliance for Open Media, compiled on your PC from the official source. |
| **SVT-AV1-Essential** | Fork by nekotrix with sensible defaults and extra options. Optional. |
| **SVT-AV1-HDR** | Fork by juliobbv, the continuation of SVT-AV1-PSY, tuned for HDR and film grain. Optional. |

Each one is built, updated and rolled back on its own from **Setup and updates**.

## How the tuned pipeline works

- **Crop**: short clips from the whole film are scanned for black bars. Films with changing aspect
  ratios (IMAX scenes) keep their full picture.
- **Adaptive plan**: the film is split at its scene cuts into segments. Each segment gets a
  denoise level (1-5) and a grain ISO (100-6400) from the grain measured in it. Neighbouring
  segments change gradually, and the plan can be edited on a timeline before the encode.
- **Denoising**: KNLMeansCL on any OpenCL GPU through VapourSynth (or hqdn3d on the CPU) removes the
  grain at the level the plan sets for each scene, so the encoder doesn't spend bits on noise.
- **Grain synthesis**: the removed grain is added back at playback by the AV1 decoder from a
  photon-noise grain table, made for the exact output size and switched scene by scene.
- **Preview first**: probes spread over the film give a playable preview reel, a size and time
  estimate and a VMAF score per probe, before the hours of the full encode.

### Why its own grain tables instead of SVT-AV1's built-in film grain

SVT-AV1's `--film-grain` estimates the grain itself: it denoises internally and models the grain
of the whole encode with one setting. That works, but on films whose grain changes from scene to
scene it can't follow the changes, and its internal denoiser isn't controllable per scene.

RazAV1 splits the two jobs: it denoises each scene by the amount that scene needs, then adds the
grain back from photon-noise tables with an ISO matched to that scene. Size and look are then both
predictable, and the preview shows the result before the full encode.

SVT-AV1's own grain is still available: the **Synthetic grain** field in the Advanced tab (used when
no grain table is chosen), which is how the stock profiles can use it.

> Tip: some players skip film grain when they decode AV1 on the GPU (for example MPC with hardware
> decoding). If an encode looks too clean, turn hardware decoding for AV1 off and compare again.

## Features

- Queue with drag and drop, per-file settings, a remembered queue and a choice of what happens when
  it's done (nothing, sleep or shut down).
- Movies, TV episodes, 4K and HDR sources are recognised and get a matching workflow: 1080p film,
  TV episode, 4K to 1080p, 4K HDR to 1080p SDR (tonemapped), anime, 4K SDR, 4K HDR10/HLG passthrough.
- **Files** and **Encoding** pages; settings in tabs: Video, Denoise and grain, Audio, Subtitles,
  Output, Source, Advanced, Command. A tab that differs from its profile is marked with `*` and can
  be reset.
- **Simple view** for people who just want smaller files, **Advanced view** for every setting.
- Every tuned feature is a switch, so any encoder can use it: adaptive grain, denoise strength,
  dark-scene tuning, crop, grain ISO, keyframes on scene cuts.
- **Audio**: Opus (7.1 to 5.1, keep 7.1, or stereo; automatic or custom bitrate; optional EBU R128
  loudness) or the original track copied as it is. Encoded while the video encodes.
- **Subtitles**: choose which tracks to keep, their order and which one is on by default. Fonts are kept.
- **Output**: folder, file name pattern (`{name} {res} {grain} {encoder} {crf}`) and what to do when
  the file exists.
- **Source** tab with every stream and HDR10 / Dolby Vision data; **Command** tab with exactly what
  the engine runs.
- Live engine output with final size estimate, time left, speed and bitrate.
- History of every encode with the space saved, free-space check, Copy diagnostics for bug reports.
- Graphite dark theme, a UI size that follows the window, update check and one-click updates.
- Language files for translations (see below).

## Updates

**About** checks this repository for a new release once a day. **Update now** installs it in one
click: your encoders, settings, grain tables, queue and own profiles stay, and the old version is
backed up in `_update_backup`.

## Translating

The window's texts are in `lang\en.txt`. Copy it to, for example, `lang\ro.txt`, translate the text
after each `=`, and choose the language in **Settings > Appearance > Language**. Lines you leave out
stay English. `lang\README.txt` explains the details. Translations are welcome as pull requests.

## Folder layout

```
RazAV1.cmd            opens the window
master_encode.bat     the encode engine (also usable on its own: drop files on it)
av1_helper.ps1        the window and the helper tools
setup.cmd             downloads and builds
profiles\             encode recipes
lang\                 window texts and translations
tables\               grain tables (the app makes them in tables\photon)
bin\  vs\             created by setup: ffmpeg, the encoders, VapourSynth
logs\                 setup and engine logs, history
```

## Antivirus

Some antivirus programs (Kaspersky in particular) watch scripts that download and run programs. All
downloads happen in `setup.cmd` with Windows' own `curl` and `tar`, in a window you can see. If a
file's settings can't be read, the engine stops that file with a message instead of encoding it
with the wrong settings.

## Reporting a problem

Press **Copy diagnostics** above the engine output, paste it into a
[GitHub issue](../../issues) and describe what happened. The text contains your settings and folder
paths, so look it over before posting.

## Credits and licence

MIT, see [LICENSE](LICENSE). The programs this app downloads are separate projects under their own
licences, credited in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

The grain table generator is a port of libaom's photon noise generator and makes the same tables as
the ones in [AV1 - The Super Doc](https://github.com/BlueSwordM/AV1-The-Super-Doc) by BlueSwordM,
which was the starting point for the grain work in this app.
