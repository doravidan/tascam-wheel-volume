# Tascam Wheel Volume

A free macOS menu-bar utility that lets a Logitech MX Master 3S thumb wheel adjust playback through a TASCAM US-1x2HR. macOS does not expose a native volume slider for this interface. The utility attenuates the playback signal in software instead of changing the interface’s analog gain.

## Build and launch

Requires macOS 15 or later and Apple’s Xcode Command Line Tools or Xcode. The first release was tested on an Intel Mac running macOS 26 with a US-1x2HR at 192 kHz. The build targets your Mac’s architecture; Apple silicon and older macOS versions have not been tested.

```sh
zsh build.sh
open -a "$PWD/build/Tascam Wheel Volume.app" --args --test-window
```

The build verifies a local signature and runs a synthetic stereo gain, mute, clamping, and underrun test. The project is distributed as source, not as a notarized installer. No third-party dependencies or paid tools are required to build.

## Set up the wheel

1. In macOS Sound settings, choose **US-1x2HR** as the output.
2. **Turn down the physical LINE OUT or PHONES knob before testing.** Stopping the utility removes software attenuation and restores the interface’s normal playback level.
3. Play something quietly. Click **Start Test** and allow **System Audio Recording** if macOS asks. Try **Quieter** before setting up the wheel. The visible test panel stops control after one minute or when closed.
4. In the existing **Logi Options+** app, open **MX Master 3S → Thumb wheel** and assign custom keystrokes: **Control–Option–Shift–↑** for louder, **Control–Option–Shift–↓** for quieter. See [Logitech’s setup guide](https://support.logi.com/hc/en-sg/articles/5218056588311-Getting-Started-MX-Master-3S). Test both directions while the app is controlling playback.
5. For normal use, close the test window and use **TASCAM → Start volume control** from the macOS menu bar. This mode has no one-minute timeout. Use **Stop and restore direct audio** or **Quit** to switch off software volume. To undo the Logitech change, restore the wheel’s previous action in Logi Options+.

The shortcuts are active only while the utility controls playback. Mapping the wheel to custom keystrokes replaces its former native volume action in that Logitech profile. If the test starts but audio is silent or distorted, stop it and use the hardware knob.

## How it works

An output-scoped [Core Audio process tap](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps) forwards the TASCAM playback stream through a small in-memory stereo buffer. The app does not read microphone audio, write recordings, or send anything over the network. Registered global shortcuts do not require Accessibility permission. No virtual audio driver or login item is installed, and the hardware sample rate is not changed. Hardware direct monitoring remains outside software volume control.

Only the US-1x2HR is supported in this release. The utility accepts matching native Float32 stereo formats and stops if the default output changes. It is an independent project, not affiliated with TASCAM or Logitech.

[MIT license](LICENSE).
