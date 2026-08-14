---
name: coreaudio-debug
description: Diagnose CoreAudio process tap errors, permission issues (TCC/System Audio Recording), and routing state in MySound.
---

# CoreAudio Debugging Skill

This skill guides diagnostic and debugging procedures for CoreAudio process taps (`CATapDescription`), aggregate devices, and macOS TCC privacy permissions.

## Common Issues & Diagnostics

### 1. Process Tap Creation Failures (`OSStatus` Errors)
When `AudioHardwareCreateProcessTap` returns a non-zero OSStatus code:
- Check `~/Library/Logs/MySound.log` for runtime status codes:
  ```bash
  tail -n 100 ~/Library/Logs/MySound.log
  ```
- **Error `-50` (paramErr):** Invalid `CATapDescription` or targeting a PID that no longer produces audio.
- **Error `560227702` / `!obj` (kAudioHardwareBadObjectError):** The target `AudioObjectID` or device is invalid.
- **Error `1701737535` / `nope` (kAudioHardwareNotRunningError):** Audio hardware service or device stream is inactive.

### 2. TCC / Permission Verification
MySound requires macOS System Audio Recording / Microphone permission:
- Check entitlements embedded in the running app:
  ```bash
  codesign -d --entitlements :- build/MySound.app
  ```
  Ensure `com.apple.security.system-audio-capture` and `com.apple.security.device.audio-input` are `true`.
- Reset TCC permissions if testing clean onboarding state:
  ```bash
  tccutil reset All com.xuanmn.mysound
  ```

### 3. Real-Time Audio Safety Checklist
When modifying [AudioTapManager.swift](file:///Users/xuanmn/Developer/MySound/Sources/AudioTapManager.swift):
- [ ] No allocations (`malloc`, Swift `Array`/`String` copies) inside the IO render callback.
- [ ] No Obj-C messaging, Swift actor hops, or `DispatchQueue.sync`.
- [ ] Only use `VolumeStore` (`os_unfair_lock`) for fast scalar lookups.
- [ ] Vector gain adjustments use Accelerate (`vDSP_vsmul`).
