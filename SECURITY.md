# Security Policy

RazAV1 is a personal project, maintained in my free time. Security fixes are handled on a best-effort basis.

## Supported Versions

Only the latest release gets fixes. If you're on an older version, update first (About > Update now) and check whether the problem is still there.

| Version | Supported |
| ------- | --------- |
| Latest release | :white_check_mark: |
| Older releases and test builds (rc) | :x: |

## What counts as a security issue

RazAV1 runs locally and doesn't open network ports. The parts that touch the internet are:

- **Setup** (`setup.cmd`), which downloads ffmpeg, VapourSynth, its plugins and the SVT-AV1 source from their official GitHub releases;
- **the update check and Update now**, which download RazAV1's own releases from this repository.

Examples of security issues: a way to make setup or the updater download and run something other than the official files, files written outside the RazAV1 folder or the chosen output folder, or settings or profile files that can make RazAV1 run commands.

Bugs in ffmpeg, SVT-AV1, VapourSynth or other downloaded tools belong to those projects. Please report them there.

## Reporting a Vulnerability

Please **don't open a public issue** for a security problem. Use **[Report a vulnerability](../../security/advisories/new)** in this repository's Security tab instead; only you and I can see that report.

Include what you found, how to reproduce it, and your RazAV1 version (shown in About). I'll reply when I can, usually within a week or two. If it's confirmed, I'll fix it in the next release and credit you in the changelog if you want. If I decide it isn't a security issue, I'll explain why.
