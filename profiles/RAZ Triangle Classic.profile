# RAZ Triangle Classic - exactly the v4.3 encode, for side-by-side comparisons.
description=Exactly v4.3: hqdn3d on the CPU, no dark-scene options.
preset=5
crf=30
crf_tv=26
mode=2
grain=3
denoiser=hqdn3d
knlm_h=0.40,0.60,0.80,1.10,1.45
knlm_chroma=1.0
luma_bias=0
enable_qm=0
qm_min=8
sharpness=0
vb_strength=2
audio_51_kbps=256
subs=0
# v1: encoder and crop [the window can change both per file]
encoder=mainline
crop=auto
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
