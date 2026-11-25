# Third-party software and credits

RazAV1 is a front end. It does not contain or ship any of the programs below.
When you press **Set up everything** or **Build latest**, it downloads each one on your PC from
its official source, and compiles the encoders from their official source code. Each program
stays under its own licence, and the credit for it goes to its authors.

| Component | Used for | Authors / source | Licence |
|---|---|---|---|
| **SVT-AV1** | the AV1 encoder (compiled on your PC) | Alliance for Open Media — github.com/AOMediaCodec/SVT-AV1 | BSD 3-Clause Clear + Alliance for Open Media Patent License 1.0 |
| **SVT-AV1-Essential** | optional encoder (fork) | nekotrix — github.com/nekotrix/SVT-AV1-Essential | same as SVT-AV1 (BSD + AOM Patent License 1.0) |
| **SVT-AV1-HDR** | optional encoder (fork, successor of SVT-AV1-PSY) | juliobbv — github.com/juliobbv-p/svt-av1-hdr | same as SVT-AV1 (BSD + AOM Patent License 1.0) |
| **FFmpeg** (ffmpeg, ffprobe) | decoding, filters, audio, muxing, quality scores | FFmpeg developers — ffmpeg.org; Windows builds by BtbN — github.com/BtbN/FFmpeg-Builds | the GPL builds used here are GPL (FFmpeg itself is LGPL 2.1+ / GPL 2+; libvmaf inside is Apache 2.0) |
| **VapourSynth** | runs the GPU denoiser | Fredrik Mellbin and contributors — github.com/vapoursynth/vapoursynth | LGPL 2.1 |
| **Python** (embeddable) | needed by VapourSynth | Python Software Foundation — python.org | PSF License |
| **KNLMeansCL** | GPU denoiser (non-local means, OpenCL) | Khanattila; VapourSynth package by Jaded Encoding Thaumaturgy — github.com/Khanattila/KNLMeansCL, pypi.org/project/vapoursynth-knlmeanscl | GPL v3 (original); see the package's LICENSE |
| **L-SMASH Works** | reads the source in VapourSynth | HomeOfAviSynthPlusEvolution and contributors — github.com/HomeOfAviSynthPlusEvolution/L-SMASH-Works | see the project's licence |
| **VMAF** (inside FFmpeg) | quality scores | Netflix — github.com/Netflix/vmaf | Apache 2.0 |
| **Visual Studio Build Tools, CMake, NASM** | compiling the encoders (installed with winget, only if missing) | Microsoft; Kitware; the NASM team | Microsoft licence terms (accepted during install); BSD 3-Clause; BSD 2-Clause |
| **curl, tar** | downloading and unpacking | built into Windows 10 1803 and newer | curl licence; BSD |

No grain tables (`.tbl`) are shipped: RazAV1 makes the ones it needs itself (see Film grain tables below).
You can still add your own to the `tables` folder.

## If you share a ready-made folder

This project is MIT licensed, and the downloaded programs are not part of it. If you give someone a
"portable pack" (a zip that already contains `bin`, `vs` and their programs), you are
redistributing those programs yourself. Then their licences apply to you. In particular, the GPL ones
(FFmpeg GPL builds, KNLMeansCL) require that you include their licence texts and say where their
source code can be obtained. The SVT-AV1 family requires that the AOM Patent License travels with
the binaries. The simplest way to stay clear of all of that is to share the project itself, and let
**Set up everything** fetch the programs on the other PC.

## Not affiliated

This project is not affiliated with or endorsed by the Alliance for Open Media, the FFmpeg project,
VapourSynth, Netflix, Microsoft, or the authors of the encoder forks. All names belong to their owners
and are used only to say which software is used.

## Film grain tables

The grain table generator in `av1_helper.ps1` is a port of `generate_photon_noise()` from libaom's
`examples/photon_noise_table.c`:

    Copyright (c) 2021, Alliance for Open Media. All rights reserved.
    BSD 2-Clause License, with the Alliance for Open Media Patent License 1.0.
    https://aomedia.googlesource.com/aom/

    Redistribution and use in source and binary forms, with or without modification, are
    permitted provided that the following conditions are met:
    1. Redistributions of source code must retain the above copyright notice, this list of
       conditions and the following disclaimer.
    2. Redistributions in binary form must reproduce the above copyright notice, this list of
       conditions and the following disclaimer in the documentation and/or other materials
       provided with the distribution.
    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS
    OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
    MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
    COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
    EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
    SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
    HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR
    TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
    SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

Thanks to **BlueSwordM** and **AV1 - The Super Doc**
(https://github.com/BlueSwordM/AV1-The-Super-Doc, folder `Photon-Noise-Tables-aomenc`): those
tables are what this program was tuned with, and its ISO steps are the ones used here. No files
from that repository are included; the generator makes the same tables.
