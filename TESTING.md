# Test checklist for a release

Run on a clean Windows 10/11 user account if possible, with the release zip unpacked to a new folder.
Tick every line before tagging a release. "Film" means a real file with film grain; "TV" an episode.

## Start and setup
- [ ] Double-click `RazAV1.cmd`: only the window opens, no empty console window.
- [ ] First start asks Tuned or Plain; Plain switches to Simple view and the stock profile.
- [ ] Setup and updates > Set up everything finishes; summary shows ffmpeg, VapourSynth, SVT-AV1.
- [ ] Build tools missing: the question appears before winget runs; Cancel leaves everything as it was.
- [ ] SVT-AV1-Essential: Build works; Official build works; Rollback restores the previous one.
- [ ] SVT-AV1-HDR: Build works; Official build works; Rollback works.
- [ ] Failed build: the log opens in Notepad; `_work` folder is gone afterwards.
- [ ] Less than 2 GB free (8 GB on C: for the build tools): setup stops and says why.

## Window
- [ ] Graphite at 90 / 100 / 110 / 125 %: nothing cut off, disabled lists stay dark, tabs readable.
- [ ] Tabs: change CRF -> "Video  *"; Reset this tab -> mark gone, CRF back. Same for Denoise and grain, Advanced.
- [ ] Simple view hides Denoise and grain and Advanced tabs; Video shows the quality choice.
- [ ] GPU strength x0.8 with calibration off: log shows the scaled fixed strengths. With calibration on: -KnlScale 0.8 in the log.
- [ ] Dark-scene tuning on a stock profile: --luminance-qp-bias 10 --enable-qm 1 in the SVT-AV1 line.
- [ ] Panel splitter and bottom splitter move; size and layout come back after a restart.
- [ ] Simple view: only file, quality level, encoder. Advanced view: every field. Choice is remembered.
- [ ] Warnings show for: HDR source on an SDR workflow, 1080p source on a 4K workflow, stock profile with denoiser, preset 1.
- [ ] "Detected as" is right for a film, a TV episode, a 4K SDR and a 4K HDR file.
- [ ] Up / Down reorder the queue, also with several files selected.
- [ ] Close with files queued, open again: same files with the same settings.
- [ ] About shows versions; Copy diagnostics puts text on the clipboard.

## Audio and defaults
- [ ] Opus auto on a 7.1 source: log says 8 ch [7.1] became 6 ch [5.1].
- [ ] Keep the channels on a 7.1 source: 8 ch out, 384k; plays in mpv/MPC with all channels.
- [ ] Stereo on a 5.1 source: 2 ch, 160k.
- [ ] Loudness off: log says "level untouched".
- [ ] Keep the original (copy) on TrueHD: file plays, audio is TrueHD, estimate includes its bitrate.
- [ ] Custom bitrate 320: used in the log.
- [ ] Settings > Defaults: audio copy + crop off; add a file with a stock profile -> Audio tab shows copy, crop off.
- [ ] RAZ Triangle file: Reset Audio tab follows the defaults too (the profile leaves audio blank).

## Pages, output, command, updates, languages
- [ ] Start an encode: the window switches to Encoding; the Files page shows the progress line; clicking it goes back.
- [ ] Output: a fixed folder on another drive: the file, log and plan folder go there; the folder is created.
- [ ] Name pattern `{name} [AV1 {crf}]`: the preview matches the real file name.
- [ ] Existing file + Add a number: `Name (2).mkv`. Skip: the file is listed as "Skipped: output exists". Replace: overwritten.
- [ ] Source tab on an HDR10 file: mastering and MaxCLL lines; on a Dolby Vision file: the profile.
- [ ] Command tab before and after an encode; Copy works; Copy diagnostics includes it.
- [ ] CRF list shows 26/30/34 for films and 22/26/30 for series; typing 28 selects Custom.
- [ ] Settings > Language with a test copy of en.txt [change a few lines]: those lines change after restart, the rest stays English.
- [ ] Update now [after the repository exists]: updates, restarts, bin/vs/tables/config/queue untouched, backup in _update_backup.

## Subtitles
- [ ] Keep 3 tracks, move the last one up twice: the output has them in that order (MediaInfo).
- [ ] On by default = a chosen track: only that one is default in the output; forced flags kept.
- [ ] On by default = None: no subtitle is default. As on the disc: flags unchanged.
- [ ] Double-click a track keeps or drops it.

## Size
- [ ] Settings > UI size Auto: the window scales while you resize it; 80 % and 150 % apply at once.
- [ ] Auto on a small window (about 900x620): everything visible, nothing overlapping.

## Layout
- [ ] Settings: queue right / progress above apply at once; restart keeps them.
- [ ] All three splitters drag; sizes come back after a restart.
- [ ] Queue columns resize by dragging the header edges; widths come back after a restart.
- [ ] Window at minimum size: stat tiles shrink, toolbar buttons wrap, nothing overlaps.

## Grain tables and scenes
- [ ] Setup > Make grain tables: about 400 files appear in `tables\photon`; pressing it again makes 0.
- [ ] Compare `tables\photon\1920x1080-SRGB-ISO400.tbl` with the same file from AV1 - The Super Doc: identical.
- [ ] Static ISO 1000 on a cropped film: the log says "made for this size" with the crop's size (e.g. 1920x800).
- [ ] Adaptive plan: the summary lists several ISO steps; plan editor shows the 14 steps; Save and encode work.
- [ ] HLG source on 4K HDR10 workflow: a `-HLG-` table is used.
- [ ] Keyframes on scene cuts: log says "Keyframes: on scene cuts"; `keyframes.txt` in the plan folder; the encode runs.
- [ ] Scene cuts: count in the analysis looks sensible on a dark film and on an action film.

## Encodes (one of each)
- [ ] Film, RAZ Triangle, adaptive grain: finishes, log next to output, quality score shown.
- [ ] TV episode, Simple view, Balanced.
- [ ] Each stock profile (SVT-AV1, Essential, HDR): runs with only the encoder defaults (see the log line "SVT-AV1:").
- [ ] Crop off, resize 720p, denoiser None, film grain 8, keyint 300, extra option `--enable-overlays 1`.
- [ ] An unknown extra option (`--does-not-exist 1`) is refused before the start.
- [ ] 4K HDR10 passthrough keeps HDR metadata (MediaInfo).
- [ ] Encoder not installed for a file: the file fails with "is not installed", the others continue.
- [ ] Preview / analyse only: reel plays, size and time estimate shown.
- [ ] Abort during an encode: stops, temporary files removed.
- [ ] Finished: "Saved X this run", Open folder and Play work, History lists the files.
- [ ] Drive nearly full: free-space question appears before the start.

## Package
- [ ] Zip contains no `bin`, `vs`, `logs`, `_work`, `queue.json`, `*.tbl` or config files.
- [ ] All text files have Windows line endings (CRLF).
