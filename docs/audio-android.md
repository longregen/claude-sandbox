# Android Emulator Audio in the Sandbox

Running the Android emulator inside `claude-sandbox` with working audio
requires some workarounds. This documents what works, what doesn't, and why.

## Quick Start

```bash
claude-sandbox --kvm --audio --env QEMU_AUDIO_DRV=wav
```

Or in `~/.config/claude-sandbox.json`:

```json
{
  "kvm": true,
  "audio": true,
  "extraEnvs": ["QEMU_AUDIO_DRV=wav"]
}
```

Then inside the sandbox:

```bash
# Place your test audio where QEMU will read it
cp test-voice.wav /path/to/project/qemu_in.wav

# Start the emulator (from your android nix shell or SDK)
QEMU_AUDIO_DRV=wav \
QEMU_WAV_PATH=/path/to/project/qemu_in.wav \
  emulator -avd <name> -no-window -no-snapshot -allow-host-audio &

# Wait for boot
adb wait-for-device
adb shell getprop sys.boot_completed  # returns "1" when ready
```

The WAV audio driver feeds `qemu_in.wav` directly into the virtual
microphone. No gRPC `injectAudio` needed.

## Sandbox Flags

### `--audio`

Mounts audio devices and sockets without requiring a full display (`--gui`):

- PulseAudio socket (`$XDG_RUNTIME_DIR/pulse`)
- PipeWire socket (`$XDG_RUNTIME_DIR/pipewire-0`)
- ALSA devices (`/dev/snd`)
- D-Bus session bus (`$XDG_RUNTIME_DIR/bus`)

Forwards env vars: `XDG_RUNTIME_DIR`, `PULSE_SERVER`, `DBUS_SESSION_BUS_ADDRESS`.

### `--env KEY=VALUE`

Pass arbitrary environment variables into the sandbox. Repeat for multiple:

```bash
claude-sandbox --kvm --audio \
  --env QEMU_AUDIO_DRV=wav \
  --env QEMU_WAV_PATH=/path/to/input.wav
```

Also available via config as `"extraEnvs": ["KEY=VALUE", ...]`.

## Why PulseAudio Doesn't Work

The Nix-packaged emulator (36.5.2) has PulseAudio client code **statically
compiled** into the QEMU binary (`qemu-system-x86_64-headless`). It does not
dynamically link `libpulse.so` — adding it to `LD_LIBRARY_PATH` has no effect.

The statically-linked PA client calls `pa_context_connect()` which fails in
headless environments because:

1. The Nix emulator wrapper force-sets `QT_QPA_PLATFORM=xcb`
2. Without a real X display, the Qt xcb platform plugin can't fully initialize
3. The PA context creation fails at an early stage, before even attempting to
   connect to the PulseAudio socket (confirmed via strace: zero `connect()`
   syscalls to unix sockets)
4. Setting `QT_QPA_PLATFORM=offscreen` and calling `.emulator-wrapped` directly
   causes a segfault (the offscreen Qt plugin isn't bundled)

Running Xvfb doesn't help either — PA still fails even with a virtual X display.

### What we confirmed

- PipeWire with PulseAudio compat layer runs fine on the host
- `pactl info` works from a nix-shell with the same `XDG_RUNTIME_DIR`
- The PA socket exists and is accessible (`/run/user/1000/pulse/native`)
- The PA auth cookie is present (`~/.config/pulse/cookie`)
- `LD_LIBRARY_PATH` with libpulseaudio *does* reach the QEMU process (verified
  via `/proc/<pid>/environ`) — it just doesn't matter because PA is statically linked

## The WAV Audio Driver (What Works)

QEMU's WAV audio driver reads from a file and feeds it as microphone input.
No network sockets, no display, no D-Bus required.

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `QEMU_AUDIO_DRV` | `pa` | Set to `wav` to use the WAV file driver |
| `QEMU_WAV_PATH` | `qemu_in.wav` | Path to the input WAV file |
| `QEMU_WAV_FREQUENCY` | `44100` | Sample rate |

The input file should be a standard WAV (PCM, 16-bit, mono or stereo).

### How it feeds the virtual mic

When `QEMU_AUDIO_DRV=wav`:
- QEMU's `wav_init_in` opens the WAV file as the audio input source
- The emulator log shows `Warning: Allowing host microphone input.` confirming
  the virtual mic HAL is active
- The Android guest's `AudioRecord` API receives data from this virtual mic
- No gRPC `injectAudio` or host audio daemon is involved

### Dynamic audio injection

To change what the mic "hears" during a test run, replace the WAV file between
recording sessions. The WAV driver re-reads on each audio capture start.

For more sophisticated injection (streaming TTS output in real-time), consider:
- Writing a FIFO/named pipe as the WAV path (if the driver supports seeking,
  this won't work — test first)
- Using the emulator console's audio commands (port 5554, requires auth token
  from `~/.emulator_console_auth_token`)

## Common Pitfalls

### Stale lock files

If the emulator crashes, it leaves lock files that prevent restart:

```
Running multiple emulators with the same AVD is an experimental feature.
```

Fix:

```bash
rm -f ~/.android/avd/<name>.avd/*.lock
adb kill-server
```

### Emulator dies when shell exits

The emulator process is a child of the shell. Use `setsid` to fully detach:

```bash
setsid emulator -avd <name> -no-window -no-snapshot \
  -allow-host-audio </dev/null >/tmp/emulator.log 2>&1 &
disown
```

### Empty WAV file

If `qemu_in.wav` is 0 bytes (e.g., failed copy), the audio driver initializes
but feeds silence. Verify with `ls -la qemu_in.wav`.

### `-no-audio` kills everything

Do NOT use `-no-audio`. It disables the entire audio subsystem including the
virtual microphone HAL. The Android guest will have no audio input device at
all. Use `QEMU_AUDIO_DRV=wav` or `QEMU_AUDIO_DRV=none` for output-only silence
with `QEMU_AUDIO_IN_DRV=wav` for input.

### gRPC `injectAudio` with WAV driver

With the WAV driver active, gRPC unary RPCs (like `getStatus`) work fine but
streaming `injectAudio` may still fail with `UNAVAILABLE` / connection reset.
This is expected — the WAV driver owns the mic input, so gRPC audio injection
has nothing to write to. Use the WAV file approach instead.

## Approaches That Don't Work

| Approach | Result |
|---|---|
| PipeWire + PulseAudio compat | PA context fails before socket connect |
| Real PulseAudio daemon + null sink | Same — static PA code fails at Qt init |
| `PULSE_SERVER` env var | Emulator wrapper doesn't forward to QEMU |
| `LD_LIBRARY_PATH` with libpulse | PA is statically linked, ignores dynamic lib |
| `QT_QPA_PLATFORM=offscreen` | Segfault — offscreen plugin not bundled |
| Xvfb + xcb | PA still fails, gRPC also fails |
| `QEMU_AUDIO_DRV=alsa` | libasound not linked into QEMU binary |
| gRPC `injectAudio` (when PA broken) | `UNAVAILABLE` — no mic HAL backend |
