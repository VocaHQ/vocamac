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


## Permissions keep resetting on source builds

Release builds of VocaMac are **Developer ID signed and notarized** by Apple. Accessibility and Input Monitoring permissions persist across updates — no manual re-granting required.

**For developers building from source:** If you don't have a Developer ID certificate, `build.sh` falls back to ad-hoc signing. With ad-hoc signing, macOS resets Accessibility and Input Monitoring permissions on every rebuild because the CDHash changes. This is standard macOS security behavior — all open-source apps with Accessibility (Rectangle, Maccy, AltTab, etc.) have the same limitation when ad-hoc signed.

**Workarounds for ad-hoc builds:**

| Approach | How | Permissions Persist |
|---|---|---|
| **Run from Terminal** | Grant permissions to Terminal.app once, then run `make run` | ✅ Always |
| **Re-grant manually** | System Settings → Privacy & Security after each rebuild | Per rebuild |

> **💡 Developer tip:** Add your Terminal app (Terminal.app or iTerm2) to both Accessibility and Input Monitoring in System Settings. Then run VocaMac directly from Terminal. Permissions are inherited and never reset.

## Dictation doesn't appear in an app, or the wrong text is pasted

Some apps ignore ⌘V or paste something else: remote desktop clients, some games and terminals, and web apps that block pasting. When an app never reads what VocaMac put on the clipboard, VocaMac types the text key by key instead. If an app reads the clipboard but still drops the text, choose **Settings › System › Putting text in apps › Always type in** and add it, or set **Insert text by** to **Type**.

Typing is never used while a password field or another secure input is active, and dictations longer than 4,000 characters are not typed; they stay in History and the menu bar to copy.

