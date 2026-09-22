---
name: Bug report
about: Report a problem with a GlassEQ build
title: ""
labels: bug
assignees: ""
---

## Support report

In GlassEQ, open **About GlassEQ** (the info button in the menu bar popover, or Settings → Output → About GlassEQ) and click **Support Report…**. Read it, then paste it below or attach the saved file. It contains the app and macOS versions, the audio route, the engine state, and recent app events. It can include profile names, output names, imported filenames, and error details. It excludes EQ settings, impulse-response samples, and license keys. Review those names and details before sharing.

```text

```

## What happened

Describe the issue.

## Steps to reproduce

1.
2.
3.

## Expected behavior

Describe what you expected.

## If the report is missing or the app never showed anything

- GlassEQ version:
- macOS version and Mac model:
- Output device and connection type (built-in, USB, HDMI, Bluetooth, AirPods, other):
- Did macOS show the system audio capture prompt, and was it granted?
- If GlassEQ launched but nothing appeared, run it from Terminal and paste the output:

```sh
/Applications/GlassEQ.app/Contents/MacOS/GlassEQ --debug
```

## Crash reports

If GlassEQ crashed, attach the newest `GlassEQ-*.ips` file from `~/Library/Logs/DiagnosticReports` (Console → Crash Reports). It contains no audio or profile data.
