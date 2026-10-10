# Ditch Creator Releases

This public repository contains only the two Windows launchers and published runtime release assets. The application source repository remains private.

Download `DitchCreator-Latest.cmd` and `DitchCreator-Latest.ps1` into the same folder, then run the CMD file. The launcher discovers the newest published normal release by semantic version, validates its ZIP and manifest, installs it under `%LOCALAPPDATA%\DitchCreator\Candidates`, and reuses a valid installation on subsequent runs.

The app requires the .NET 8 Windows Desktop Runtime. Live AutoCAD and E3D acceptance is not implied by publication.

## Future release contract

Publish a non-draft GitHub Release tagged `vX.Y.Z` with an asset named exactly `DitchCreator-vX.Y.Z-Release.zip`. The ZIP must contain `PACKAGE-MANIFEST.json` with `Version`, the validated private source `Commit`, and a `Files` array of relative paths and SHA-256 hashes. Keep customer data, drawings, spreadsheets, source archives, and debug symbols out of public assets. No launcher version-list edit is necessary.
