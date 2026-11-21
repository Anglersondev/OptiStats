OptiStats 1.2.1 fixes intermittent temperature gaps in the menu bar on Apple Silicon.

### Fixes and improvements

- Stacked CPU and GPU temperature indicators request sensor data even when the secondary indicator is disabled on its own. Temperature updates redraw the menu bar directly.
- If a temperature reading briefly drops out, the menu bar shows the last real reading for up to 60 seconds after it was measured. An asterisk marks the held value, and no extra points are added to temperature history.
- Temperature-only widgets stop polling CPU or GPU utilization in the background. Opening the detailed panels still requests utilization on demand.

### Update

Open **OptiStats-1.2.1.dmg** and replace the app in Applications. The build targets Apple Silicon on macOS 13 or later. The app has an ad-hoc signature and the DMG is distributed without Apple notarization. The release includes a SHA-256 checksum.

The fan helper remains at build 5. App and fan preferences are retained when replacing the application.
