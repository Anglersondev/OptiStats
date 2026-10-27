# OptiStats — macOS System Monitor

**A native, lightweight menu bar monitor for Apple Silicon, with RAM guidance, fan controls and optional Debloat.** Built by [Anglerson](https://github.com/Anglersondev) in Swift and AppKit.

[Download 1.0](https://github.com/Anglersondev/OptiStats/releases/tag/v1.0) · [Website](https://anglersondev.github.io/OptiStats/) · [Português brasileiro](README.pt-BR.md) · [Report a bug](https://github.com/Anglersondev/OptiStats/issues)

## What it does

- Monitor CPU, GPU, RAM, temperatures, power, fans, disk, network and battery from customizable menu bar indicators.
- Open history charts, sensor readings and processes grouped by application.
- Choose Economy, Balanced, Real-time or Custom sampling. Hidden sources stop sampling; collectors share one scheduler.
- Analyze memory pressure and review app recommendations before choosing what to close. No guaranteed RAM savings or forced app termination.
- Read fan speeds by default. Optional Automatic, Manual, **100%** and Smart Boost controls require installing the helper, allowing control and passing a validation test on the current Mac.
- Manage disk/cache maintenance and selected macOS services with optional Debloat tools.
- Switch between English and Brazilian Portuguese at runtime. Find the version, credits and donation link in **Preferences → About**.

## Download and requirements

[Download OptiStats 1.0 for macOS](https://github.com/Anglersondev/OptiStats/releases/download/v1.0/OptiStats-1.0.dmg). Open the DMG and drag OptiStats to Applications.

Requires **macOS 13 or later and Apple Silicon**. Sensor availability and fan control depend on the Mac. The release is ad-hoc signed, not Apple notarized; macOS may require approval in System Settings → Privacy & Security. Install the optional fan helper only if you want write control.

## Inspired by Stats, with additional tools

OptiStats is an independent app inspired by [Stats by exelban](https://github.com/exelban/stats). Selected SMC, sensor, IOReport and fan-control approaches were studied or adapted with MIT attribution. OptiStats uses its own sampling architecture and adds RAM guidance, disk/cache maintenance and a Debloat interface. It is not affiliated with Stats.

The focus is low overhead: demand-driven collection, shared reads, bounded history and background work away from the interface thread. **Lower CPU or RAM use than Stats has not been established in a controlled comparison.** See [performance measurement](#measure-performance) and [the implementation audit](docs/AUDITORIA-STATS.md).

## Debloat: source and behavior

The service catalog, comments and presets are based on **[mac-os-debloat by Oleksandr Krupko](https://github.com/OleksandrKrupko/mac-os-debloat)**, licensed under MIT. OptiStats bundles a copy of its `EMBEDDED_LABELS` catalog and implements its own interface and application logic; it does not execute the upstream Python script.

Open Debloat to inspect services present on your Mac, review Telemetry/Balanced/All presets, and confirm selected launchd changes. Snapshots let the app restore supported changes it made. Disabling services can affect features such as iCloud, App Store and macOS updates; the available services vary by macOS version and SIP restrictions still apply. Debloat is optional and does not run continuously.

Catalog updates are **manual**: the button fetches the catalog from the original repository over HTTPS. Monitoring stays local and there is no telemetry. See [third-party notices](THIRD_PARTY_NOTICES.md) for the preserved MIT licenses.

## Build and validation

Use macOS with Xcode 15 or later:

```sh
python3 scripts/generate_xcodeproj.py
xcodebuild -project OptiStats.xcodeproj -scheme OptiStats -configuration Release build CODE_SIGNING_ALLOWED=NO
swift test --package-path Packages/OptiStatsCore
python3 scripts/check_localization.py
```

The pure Swift core is tested on Linux and macOS in CI; CI also builds the macOS app and DMG. Automated checks do not validate physical fan response. Fan behavior and resource usage must be checked on the target Mac. The app is not sandboxed because its monitoring and optional control use macOS system interfaces.

## Measure performance

With the app open and the Mac idle, run `scripts/benchmark.sh 300 OptiStats`. Compare identical enabled features and sampling profiles when measuring another monitor. CPU and memory figures are measurements for that configuration, not universal guarantees.

## Credits and support

Created by **Anglerson**. [Support development ☕](https://pixgg.com/Anglerson).

Third-party MIT notices are preserved in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). An overall license for OptiStats has not yet been declared; the third-party licenses apply to their respective material.
