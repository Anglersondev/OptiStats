# Final review — OptiStats 1.0

Local review on 2026-10-27, Apple M4 Pro, macOS 27.2.

## Changes

- UI capability reads use a separate lock from helper socket exchanges, avoiding waits behind a control request (up to 40 seconds).
- Preferences compare the installed and bundled helper on the I/O queue, once per status refresh, instead of during view reconstruction.
- History updates mutate dictionary values in place, avoiding a full circular-buffer copy on every sample while preserving snapshot value semantics.
- System command output pipes are drained concurrently, avoiding a blocked child when stderr fills before stdout closes.
- A generation counter ignores late control responses after restore, sleep or shutdown. Restoration remains busy until it completes; failed manual requests also restore previously controlled fans.
- Missing SMC reads no longer count as successful restoration. Pending restoration is retried. New control requests are rejected in a critical thermal state.
- About is present in the Preferences sidebar with donation and credit details. Public app version remains 1.0; internal helper build is 3.

## Local evidence

The current pure Swift core, helper and app compiled in Release mode for arm64 with deployment target macOS 13 using Command Line Tools. English/PT-BR localization and static website checks passed.

A test using the actual `SMCFanDriver` with a fake SMC transport confirmed that a missing mode read leaves restoration pending and that a successful retry clears it. A history regression confirmed retained snapshots remain unchanged and capacity stays bounded. A child writing 256 KiB to each output pipe completed and retained its exit status.

Isolated optimized benchmark, same compiler and machine, 50,000 network publications with two series:

| Buffer capacity | Before | After |
| --- | ---: | ---: |
| 900 points | 0.0574 s | 0.0126 s |
| 36,000 points | 1.0211 s | 0.0113 s |

These timings measure history publication only, not whole-app CPU/RAM use or performance relative to Stats. Before source: commit 9d93b64; after source: commit bd086ba. Both ran with `swiftc -O` and identical inputs.

## Remaining validation

The preceding complete CI build passed for 9d93b64. The first run with the new regression test failed because its class name duplicated an existing class; bd086ba fixes the name. GitHub then returned HTTP 403, `Your account was suspended`, and the final complete XCTest/CI status could not be retrieved or rerun. This is not recorded as a passing CI result.

The local DMG uses freshly compiled app/helper executables and unchanged icon resources from the prior successful CI bundle. Source localizations, catalog and third-party notices are refreshed. It is ad-hoc signed and not Apple notarized.

Physical fan behavior and idle CPU/RAM consumption have not been validated on the target Mac. Do not interpret this review as a guarantee that the code is free of bugs.
