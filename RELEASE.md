# Making a release

1. Set `$AppVersion` in `av1_helper.ps1` and `VER` in `master_encode.bat` to the new number.
2. Set `$AppRepo` in `av1_helper.ps1` to `RAZBUMN/RazAV1` (owner/name of the GitHub
   repository). The About window and the update check use it; left empty, they skip the check.
3. Check the name in `LICENSE` (Copyright line).
4. Add the release to `CHANGELOG.md`.
5. Go through `TESTING.md`.
6. Make the zip from the project files only:
   `RazAV1.cmd, master_encode.bat, av1_helper.ps1, setup.cmd, profiles\, tables\README.txt,
   README.md, CHANGELOG.md, LICENSE, THIRD_PARTY_NOTICES.md, lang\`.
   Never include `bin\` or `vs\`: those hold ffmpeg, the encoders and VapourSynth, and shipping them
   would make you a distributor with GPL duties (source offers for ffmpeg and KNLMeansCL).
7. On GitHub: Releases > Draft a new release, tag `v1.0.0` (same as `$AppVersion` with a `v`),
   attach the zip, paste the changelog section.
8. The update check compares `$AppVersion` with the newest release tag, so tag every release.
9. **Update now** downloads the first `.zip` attached to the newest release and needs
   `av1_helper.ps1`, `master_encode.bat` and `RazAV1.cmd` in it (at the top or in one folder).
   Include `lang\` and `profiles\`. The release text is shown to the user as "What is new", so paste the
   changelog section there.
