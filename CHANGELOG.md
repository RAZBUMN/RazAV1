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

## Before 1.0 (private versions, as "AV1 Master Encoder")

**v7** - KNLMeansCL calibrated per film against the hqdn3d levels, VMAF scores for the probes, engine
output, live size/time/speed and abort inside the window, grain plan editor.

**v6** - Portable folder with automatic setup: ffmpeg, VapourSynth and SVT-AV1 compiled locally.

**v5** - The window, profiles, KNLMeansCL denoising on the GPU.

**v4.3** - From one file to a queue.
- Drop several files or whole folders; each gets its own crop, plan and audio pick, with no
  questions in between. "Send To" menu entry.
- Presets file and last settings, a start screen and a ready screen that carry on by themselves.
- Source detection (SDR, HDR10, HLG, Dolby Vision) with a suggested workflow, and warnings when the
  chosen workflow doesn't fit the file.
- New workflows: 4K SDR kept at 4K, and 4K HDR10/HLG passthrough with the mastering display and
  light levels kept. HDR grain tables.
- Audio track picked automatically (preferred language, no commentary, most channels).
- Resume after a crash: a finished video stream is reused, only audio and mux are redone.
- Smart probe placement: no intro or end credits, probes start on scene cuts, every denoise level
  covered. Encode time estimate next to the size estimate.
- A log file per encode, optional subtitles and fonts (with a retry without them if the mux fails).
- CPU mode (max, normal, low), sleep or shutdown when the queue is done, a notification at the end.

**v4.2** - Adaptive mode: the film is split into scenes, each gets a denoise level (1-5) and a grain
tier, applied with timed hqdn3d commands and a timed grain table. The plan can be reused or edited
in Notepad, and the probes use the settings of the scene they land in.

**v4.1** - Analysis pass that measures brightness and scene cuts across the film (report only), the
groundwork for the adaptive mode.

**v4.0** - ISO 200 grain table. The audio's real channel layout is read: 7.1 and 6.1 become 5.1,
5.0, stereo and mono keep their shape, with the downmix before loudness normalisation and a channel
check after the encode. Audio progress in percent. Grain tables picked by the output size.

**v3.4.2** - Crop scan over the whole film (40 short clips per hour) that keeps every aspect ratio,
so mixed-ratio films keep their full picture.

**v3.4.1** - Checks before starting (encoder, ffmpeg, the tonemap filter), audio track choice, crop
detection, the source frame rate kept, a denoise strength per grain profile, audio encoded in
parallel with the video, a confirmation after the preview, the real size and time at the end, and
the temporary streams kept when something fails.

**v2.5.4** - The first version: a script to drop a film on. Five workflows (1080p film, TV episode,
4K to 1080p, 4K HDR/Dolby Vision to 1080p SDR with tonemapping, anime), hqdn3d denoising, ISO 400
and ISO 800 grain tables, CRF 30 or 26, SVT-AV1 preset 5, six probes per hour with a size estimate
and a playable preview reel, Opus 5.1 audio with loudness normalisation.
