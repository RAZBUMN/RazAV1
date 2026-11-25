# RAZ Triangle - the balance of size, time and look.
# Your v4.3 settings plus KNLMeansCL on the GPU and the dark-scene options of SVT-AV1 4.x.
# 1.0: fixed KNLMeansCL strengths per denoise level; the adaptive plan still picks the level for every scene.
# Edit any value in Notepad. Lines starting with # are ignored.
description=v4.3 settings plus GPU denoising [KNLMeansCL, a level per scene] and more bits for dark scenes.
preset=5
crf=30
crf_tv=26
# mode: 1 = static, 2 = adaptive      grain: static 1-4 = none/ISO200/ISO400/ISO800, adaptive 2-4 = light/medium/heavy
mode=2
grain=3
# denoiser: knlm [GPU, needs VapourSynth] or hqdn3d [CPU]
denoiser=knlm
# KNLMeansCL strength for denoise levels 1-5:
#   auto = measured on each film so every level removes as much grain as hqdn3d does [cached in the plan folder]
#   or five fixed numbers, for example 0.70,1.00,1.30,1.70,2.20
knlm_h=0.70,1.00,1.30,1.70,2.20
# auto only: multiply the measured strengths [1.15 = 15% stronger, 0.9 = gentler]
knlm_scale=1.0
# temporal radius [1 = previous and next frame; 2 is stronger on grain but about half the GPU speed]
knlm_d=1
# search radius [2 is the usual; 3 finds more matches, slower]
knlm_a=2
# chroma strength = luma strength x this
knlm_chroma=1.0
# Dark scenes: more bits for dark frames, quantisation matrices for smoother gradients
luma_bias=10
enable_qm=1
qm_min=2
sharpness=0
vb_strength=2
audio_51_kbps=256
# subs: 1 = keep all subtitle tracks, 0 = drop [the GUI lets you pick per file]
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
