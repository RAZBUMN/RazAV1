Film grain tables (.tbl).

The program makes the tables it needs by itself and keeps them in the photon folder:
<width>x<height>-SRGB-ISO400.tbl for SDR, -PQ- for HDR10 and -HLG- for HLG, ISO 100 to 6400.
Setup > Make grain tables makes the common 1080p, 720p and 4K sizes ahead of time.

Your own tables can go here too and are used first when size, HDR/SDR and ISO match.
Older names keep working: 1920x800_ISO400.tbl [SDR], 3840x1600_ISO400_HDR.tbl [HDR10].

The generator is a port of libaom's photon_noise_table [BSD 2-Clause] and makes the same
tables as the photon noise sets in AV1 - The Super Doc by BlueSwordM:
https://github.com/BlueSwordM/AV1-The-Super-Doc
