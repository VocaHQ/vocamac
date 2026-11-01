# Troubleshooting

## Reset onboarding

To re-trigger the first-launch onboarding wizard (e.g., after an upgrade or for testing), reset the onboarding flag:

```bash
defaults delete com.vocamac.app vocamac.hasCompletedOnboarding
```

Then relaunch VocaMac. This only clears the onboarding state; all other preferences (hotkey, language, model) are preserved.

## Reset all preferences

To start completely fresh:

```bash
defaults delete com.vocamac.app
```

## Reset permissions

If permissions appear stuck or aren't being recognized after an update, you can reset them from **Settings → Permissions & Logs → Reset All Permissions**, or manually via Terminal:

```bash
tccutil reset All com.vocamac.app
```

This clears all permission entries (Microphone, Accessibility, Input Monitoring) for VocaMac. On next launch, macOS will prompt you to re-grant them. With Developer ID signing, permissions normally persist across updates — this reset is only needed for troubleshooting.

## "Update check failed (HTTP 403)" on a shared, corporate or VPN network

VocaMac checks for new releases by calling GitHub's public REST API, which is rate-limited to **60 unauthenticated requests per hour, per source IP**. When several people share the same egress IP (common on office VPNs, NAT'd networks, or busy CI runners), that quota is collectively exhausted and GitHub returns `HTTP 403` to every client from that IP — including VocaMac.

This is **not a bug in VocaMac** and there is nothing wrong with your install. To recover:

1. Disconnect from the VPN (or switch to a different network, e.g. your phone's hotspot).
2. Open VocaMac → **Settings → About → "Check for Updates…"** and wait for it to complete.
3. Reconnect to the VPN.

After one successful check, VocaMac caches the response's `ETag` and sends it as `If-None-Match` on every subsequent request. GitHub then replies with `304 Not Modified`, which **does not count against the rate limit**, so future checks succeed even from a rate-limited IP — until a new release ships and the ETag changes (at which point one fresh `200` response per machine is needed before `304`s resume).


## Silent Mode doesn't understand mouthed words

Mouthing with no sound needs the lip-reading model, which isn't bundled (its weights are for research and non-commercial use). Build it once on your Mac:

```bash
make lip-reading-model   # needs uv; about 10 minutes and 3 GB of downloads
```

It installs itself into `~/Library/Application Support/VocaMac/models/lip-reading/`. **Settings › Silent Mode** then shows the model as installed and "How you'll speak" set to **Mouth**. The first silent dictation after that loads the model for a few seconds.

Lip reading is English only and works best with your face square to the camera, lit from the front, at 25–30 frames a second. Mouth the words as clearly as if you were speaking: silent mouthing tends to be smaller than speech, and the model learned from people speaking aloud. Turn on **Start preview**: "What the lip reader sees" should show your mouth centred and level. Expect about one word in four to be wrong (26% WER on English TED talks with the beam search; models built before the decoder was added read greedily, at 33%: run `make lip-reading-model` again). Dark or flat lighting is lifted automatically.

To test on a recording of yourself, film a few seconds of mouthing a sentence (QuickTime Player › New Movie Recording) and run:

```bash
/Applications/VocaMac.app/Contents/MacOS/VocaMac --read-lips ~/Movies/clip.mov --json
```

## Silent Mode doesn't type anything

Silent Mode decodes only the stretches where the camera saw your lips move. If it says it "didn't see your lips move":

1. Open **Settings › Silent Mode** and press **Start preview**. Your lips' outline should appear and the bar should fill as you mouth words.
2. Face the camera with your mouth in view. A face turned more than about 35° away, a backlit window, or a very small face in the picture is not read.
3. Raise **Sensitivity** if you mouth words subtly.

With History on, the recording is kept there, so you can retry it from the menu bar. If the camera is unavailable, Silent Mode says so in the overlay and the recording is transcribed as an ordinary dictation. Camera access is under **System Settings › Privacy & Security › Camera**.

## Permissions keep resetting on source builds

Release builds of VocaMac are **Developer ID signed and notarized** by Apple. Accessibility and Input Monitoring permissions persist across updates — no manual re-granting required.

**For developers building from source:** If you don't have a Developer ID certificate, `build.sh` falls back to ad-hoc signing. With ad-hoc signing, macOS resets Accessibility and Input Monitoring permissions on every rebuild because the CDHash changes. This is standard macOS security behavior — all open-source apps with Accessibility (Rectangle, Maccy, AltTab, etc.) have the same limitation when ad-hoc signed.

**Workarounds for ad-hoc builds:**

| Approach | How | Permissions Persist |
|---|---|---|
| **Run from Terminal** | Grant permissions to Terminal.app once, then run `make run` | ✅ Always |
| **Re-grant manually** | System Settings → Privacy & Security after each rebuild | Per rebuild |

> **💡 Developer tip:** Add your Terminal app (Terminal.app or iTerm2) to both Accessibility and Input Monitoring in System Settings. Then run VocaMac directly from Terminal. Permissions are inherited and never reset.
