# Device floor (iOS 27 / iPadOS 27)

Research of 2026-11-25. Owner rule: the oldest supported devices are whatever iOS 27 supports.
Legend: unmarked = read on the source; **[UV]** = unverified (search snippet, third party or recollection).

## Bottom line

- **iPhone:** iOS 27 supports exactly the iPhones iOS 26 did. The oldest are the iPhone 11 family and the
  iPhone SE (2nd gen), all A13 (GPU family **Apple6**).
- **iPad:** iPadOS 27 dropped the A12/A12X iPads but kept the **A12Z iPad Pro** (11" 2nd gen, 12.9" 4th gen),
  GPU family **Apple5**. Apple5 is therefore the lowest Metal feature level the engine must run on.
- **No Metal 4 on the floor.** Metal 4 needs Apple7 (A14/M1) or later. The iPhone 11 family, SE 2, iPad
  (9th gen) and the A12Z iPad Pros cannot use it. The engine targets the Metal 3-era API.
- **Performance floor device:** iPad (9th gen): A13, 3 GB, about 3.5 MP at @2x, 60 Hz, no P3.

Sources: https://support.apple.com/en-us/128058 (iOS 27 iPhones),
https://support.apple.com/en-us/148850 (iPadOS 27 iPads),
https://www.macrumors.com/2026/09/14/ios-27-compatible-iphones/,
https://www.macrumors.com/2026/06/08/ipados-27-drops-support-for-a-wave-of-ipads/,
https://everymac.com/systems/apple/ipad/ipad-faq/ipados-27-supported-devices-ipad-system-requirements.html.
Press claims that "the floor is A13" or "A14/M1" are wrong because of the A12Z iPad Pros.

## Oldest supported models

| Device | Chip / GPU family | RAM | Native px, scale | Refresh | P3 |
|---|---|---|---|---|---|
| iPhone SE (2nd gen) | A13 / Apple6 | 3 GB | 750x1334 @2x | 60 Hz | yes |
| iPhone 11 | A13 / Apple6 | 4 GB | 828x1792 @2x | 60 Hz | yes [UV] |
| iPhone 11 Pro / Pro Max | A13 / Apple6 | 4 GB | 1125x2436 / 1242x2688 @3x | 60 Hz | yes [UV] |
| iPad (9th gen) | A13 / Apple6 | 3 GB | 1620x2160 @2x | 60 Hz | **no** |
| iPad Pro 11" (2nd gen) | A12Z / **Apple5** | 6 GB | 1668x2388 @2x | 120 Hz ProMotion | yes |
| iPad Pro 12.9" (4th gen) | A12Z / **Apple5** | 6 GB | 2048x2732 @2x | 120 Hz ProMotion | yes |
| iPad Air (4th gen) | A14 / Apple7 | 4 GB | 1640x2360 @2x | 60 Hz | yes [UV] |
| iPad mini (6th gen) | A15 / Apple8 | 4 GB | 1488x2266 @2x | 60 Hz | yes [UV] |

RAM: https://iosref.com/memory-processor (Apple does not publish RAM). Resolutions: https://iosref.com/res.
iPad 9: https://support.apple.com/us-en/111898. iPad Pro 12.9" 4th gen: https://support.apple.com/111977.
iPhone SE 2: https://support.apple.com/en-bh/111882.

ProMotion iPhones are only the 13 Pro to 16 Pro lines, iPhone 17, 17 Pro/Pro Max and Air
(https://support.apple.com/en-tm/guide/iphone/aside/iphfb8ca5aff/26/ios/26). Every non-Pro A13-A15 iPhone, both
SEs, 16/16 Plus, 16e and 17e [UV] run at 60 Hz.

## Metal features that matter (Metal Feature Set Tables, 2026-10-23)

https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf

Family membership: A12 (incl. A12Z) Apple5; A13 Apple6; A14/M1 Apple7; A15/A16/M2 Apple8; A17 Pro/A18/M3/M4
Apple9; A19/M5 Apple10; M6 Apple11. Metal 4 "is available as of Apple7".

| Feature | Lowest family | On the floor |
|---|---|---|
| Memoryless render targets | Apple2 | everywhere |
| Raster order groups, tile shaders, imageblocks | Apple4 | everywhere |
| ASTC LDR | Apple2 | everywhere |
| ASTC HDR | Apple6 | **not on A12Z** |
| Sparse textures, variable rasterization rate | Apple6 | not on A12Z |
| Lossy texture compression | Apple8 | A15 and later |
| Max 2D texture size | 16384 (Apple3-9), 32768 (Apple10+) | plan for 16384 |
| BC formats | Apple9 (some Apple7/8 iPads) | check at runtime; never on iPhone |
| Lossless framebuffer compression | automatic from Apple5 when conditions hold (see performance-and-power.md) | everywhere |

iOS 27 fixed clamp-to-edge samplers returning zero on some GPUs including Apple10
(https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes.md).

## SDK and platform notes

- Xcode 27 (Swift 6.4, macOS Tahoe 26.6+) accepts deployment targets iOS 15-27; on-device debugging needs
  iOS 17+ (https://developer.apple.com/support/xcode/).
- iOS 27 MetricKit: new Swift `MetricManager`; `MetalFrameRateMetric` per `CAMetalLayer`; `StateReporting`
  framework tags metrics by app state; `HitchTimeMetric` uses `HitchTimeRatio` and needs a rebuild with the
  iOS 27 SDK to avoid a launch crash.
- WWDC26 session 388 (https://developer.apple.com/videos/play/wwdc2026/388/): on-device lookback Performance
  Trace (Developer settings, Control Center), `metalperftrace` on macOS.
- Nothing new for Game Mode, `CAMetalDisplayLink`, `CADisplayLink` or Low Power Mode in iOS 27.
- Low Power Mode, critical thermal state and accessibility settings can lower the display link's rate
  (Apple's `preferredFramesPerSecond` docs). "ProMotion capped at 60 in Low Power Mode" is forum-only [UV].

## Test devices

| Role | Device | Why |
|---|---|---|
| Performance and battery floor | iPad (9th gen) | oldest chip, least RAM, most pixels per GPU, no P3 |
| Small screen, small battery | iPhone SE (2nd gen) | 375x667 pt, 3 GB |
| Feature floor and fill-rate worst case | iPad Pro 12.9" (4th gen, A12Z) | Apple5: no HDR ASTC, no Metal 4; about 5.6 MP at 120 Hz |
| Current flagship | newest iPhone Pro | ProMotion 120 Hz, Apple10+ |
