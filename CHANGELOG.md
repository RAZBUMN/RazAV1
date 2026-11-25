# Changelog

## 1.0.0 (first public release)

The first public version of RazAV1 (developed privately as "AV1 Master Encoder").

**Encoders and profiles**
- SVT-AV1, SVT-AV1-Essential and SVT-AV1-HDR, each compiled from its own source with its own update
  check and rollback (official Windows builds as a fallback for the forks).
- Profiles: RAZ Triangle (tuned, GPU denoise), RAZ Triangle Classic (CPU denoise) and a stock profile
  for every encoder. **Save as...** makes your own.
- First start asks for tuned or plain AV1 as the default.

**Picture**
- Crop scan over the whole film that keeps changing aspect ratios.
- Adaptive plan: a denoise level and a grain ISO per scene, gradual changes between scenes, editable
  on a timeline.
- Denoising with KNLMeansCL on the GPU (fixed strength per level, or measured on each film) or hqdn3d.
- Grain tables made by the app: a port of libaom's photon noise generator, any output size, 14 ISO
  steps from 100 to 6400, SDR, HDR10 and HLG. Your own `.tbl` files still come first.
- Scene cut detection that adapts to motion and ignores flashes; optional keyframes on scene cuts.
- Workflows for 1080p films, TV episodes, 4K to 1080p, HDR to SDR tonemapping, anime and 4K passthrough.

**Preview and encoding**
- Probes over the whole film: preview reel, size and time estimate, VMAF per probe, before the full encode.
- Audio in parallel: Opus (5.1, 7.1 or stereo, automatic or custom bitrate, EBU R128 loudness) or copy.
- Subtitles: choose tracks, order and the default track; fonts are kept.
- Output folder, file name pattern and existing-file rule.
- The engine refuses to encode a file whose settings it cannot read, instead of using blank settings.

**Window**
- Files and Encoding pages, settings in tabs (Video, Denoise and grain, Audio, Subtitles, Output,
  Source, Advanced, Command), tabs marked when they differ from the profile, reset per tab.
- Simple and Advanced views, warnings for choices that make little sense.
- Live engine output with size, time left, speed and bitrate; History with the space saved.
- Graphite dark theme, a UI size that follows the window, resizable panels and columns.
- Settings > Defaults for audio, crop and output across all profiles.
- Update check and one-click **Update now**, Copy diagnostics, language files for translations.

## Before 1.0 (private versions)

- v7: KNLMeansCL calibration, VMAF scores for the probes, engine output inside the window, grain plan editor.
- v6: portable folder with automatic setup (ffmpeg, VapourSynth, SVT-AV1 compiled locally).
- v5: the window, profiles, KNLMeansCL on the GPU.
- v4.x: batch engine with adaptive grain plans, scene-cut probes, preview reel, audio in parallel.
