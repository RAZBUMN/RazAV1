# SVT-AV1: the encoder exactly as its authors ship it.
# Nothing is tuned: no denoising, no grain tables, no crop, no extra options.
# Preset and CRF are blank, so the encoder uses its own defaults; set them in the window if you like.
description=Stock SVT-AV1 with its own defaults. Only what you set in the window is passed on.
encoder=mainline
stock=1
preset=
crf=
crf_tv=
mode=1
grain=1
denoiser=none
crop=
keyint=
svt_params=
audio_51_kbps=256
subs=0
# v1: grain ISO [blank = from the grain choice; 100, 200, 260, 320, 400, 500, 600, 800, 1000, 1200, 1400, 1600, 3200 or 6400]
grain_iso=
# v1: keyframes on scene cuts [1 = on, experimental]
scene_kf=0
# v1: audio [blank = Settings > Defaults]: audio_format opus or copy, audio_channels auto, keep or stereo,
# audio_kbps a number or blank for automatic, audio_norm 1 = even loudness, 0 = untouched
audio_format=
audio_channels=
audio_kbps=
audio_norm=
# v1: output [blank = Settings > Defaults]: out_dir a folder, out_name e.g. {name}_AV1_{res}_{grain}, out_exists number, skip or replace
out_dir=
out_name=
out_exists=
