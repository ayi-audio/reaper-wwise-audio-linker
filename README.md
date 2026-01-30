# Reaper-Wwise Audio Linker

A tool for bidirectional audio workflow between REAPER and Wwise.

## Features
- Import audio sources from Wwise selected objects into REAPER
- Render REAPER items back to overwrite Wwise original audio files
- Automatic P4 checkout before rendering
- Real-time progress display and logging

## Requirements
- ReaImGui (install via ReaPack: Extensions > ReaImGui)
- ReaWwise (download from Audiokinetic: https://www.audiokinetic.com/library/edge/?source=ReaWwise)
- Wwise with WAAPI enabled (default port 8080)

## Usage
1. Open Wwise project with WAAPI enabled
2. Select objects containing audio sources in Wwise
3. Click "Import from Wwise" to import audio files
4. Edit audio in REAPER
5. Select items and click "Render to Wwise" to overwrite original files