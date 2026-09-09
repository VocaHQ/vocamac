---
layout: "enterprise"
title: "VocaMac for Managed Macs"
description: "How IT teams deploy VocaMac across managed Macs: pre-approving Accessibility and Input Monitoring with an MDM privacy profile, and what still needs a click from the person at the keyboard."
keywords: "VocaMac MDM, PPPC profile macOS, deploy dictation app enterprise, Jamf Kandji Mosyle accessibility permission, TCC configuration profile, managed Mac voice typing"
---

VocaMac needs three macOS permissions to work: **Microphone** to hear you, and **Accessibility** plus **Input Monitoring** so the menu-bar app can notice its shortcut and type the result where your cursor is.

On a personal Mac you grant those in System Settings and never think about them again. On a managed Mac the Accessibility pane needs an administrator to unlock it — and the person using the machine usually isn't one. That's what this page is for.

## Pre-approving permissions with MDM

Every major MDM — Jamf, Kandji, Mosyle, Intune, and others — can push a **Privacy Preferences Policy Control** payload (`com.apple.TCC.configuration-profile-policy`). It writes the grant straight into macOS's privacy database, so VocaMac arrives already approved and nobody has to hunt for an admin password.

| Permission | Service key | Why VocaMac asks | Can MDM pre-approve it? |
|---|---|---|---|
| Accessibility | `kTCCServiceAccessibility` | Global hotkeys, inserting text into the app you're working in | Yes |
| Input Monitoring | `kTCCServiceListenEvent` | Noticing the shortcut anywhere in the system | Yes |
| Microphone | `kTCCServiceMicrophone` | Capturing the audio to transcribe | No — see below |

### The microphone always needs a click

Apple lets a privacy profile **deny** microphone access but never **grant** it. No MDM can approve a microphone on someone's behalf; that consent has to come from the person at the keyboard, by design.

In practice this is the easy half. The microphone prompt is an ordinary dialog any standard user can accept without administrator rights — it's Accessibility and Input Monitoring that need an admin, and those are exactly the two the profile handles. So a managed rollout looks like: profile lands, user launches VocaMac, clicks **Allow** once for the microphone, and starts dictating.

Granting Accessibility also covers synthesising keystrokes, so a separate `kTCCServicePostEvent` entry isn't needed.

## What to put in the payload

| Field | Value |
|---|---|
| Identifier | `com.vocamac.app` |
| Identifier type | `bundleID` |
| Authorization | `Allow` |
| Code requirement | Read it from the signed app |

Don't hand-write the code requirement — read the real designated requirement off a release build and paste it in verbatim:

```
codesign -d -r- /Applications/VocaMac.app
codesign -dv --verbose=4 /Applications/VocaMac.app 2>&1 | grep TeamIdentifier
```

The result looks like this, with VocaMac's Apple Developer team in place of `TEAMID`:

```
identifier "com.vocamac.app" and anchor apple generic
  and certificate 1[field.1.2.840.113635.100.6.2.6]
  and certificate leaf[field.1.2.840.113635.100.6.1.13]
  and certificate leaf[subject.OU] = "TEAMID"
```

The services block that goes with it:

```
<key>Services</key>
<dict>
  <key>Accessibility</key>
  <array>
    <dict>
      <key>Identifier</key><string>com.vocamac.app</string>
      <key>IdentifierType</key><string>bundleID</string>
      <key>CodeRequirement</key><string>...</string>
      <key>Authorization</key><string>Allow</string>
    </dict>
  </array>
  <key>ListenEvent</key>
  <array>
    <dict>
      <key>Identifier</key><string>com.vocamac.app</string>
      <key>IdentifierType</key><string>bundleID</string>
      <key>CodeRequirement</key><string>...</string>
      <key>Authorization</key><string>Allow</string>
    </dict>
  </array>
</dict>
```

`Authorization` is the current key. Older MDM consoles emit `<key>Allowed</key><true/>` instead, which still works.

## Two things that quietly go wrong

**A profile installed by hand does nothing.** macOS only honours privacy payloads that arrive through a user-approved MDM enrolment. A `.mobileconfig` someone downloads and double-clicks will report a successful install and grant precisely nothing.

**Only the signed release builds match.** The payload is bound to VocaMac's code signature, not to a path on disk. The DMG and the Homebrew cask are Developer ID signed and notarised by Apple, so they match. A build compiled from source without a Developer ID certificate is ad-hoc signed, matches no code requirement, and the profile passes it by — deploy the notarised build.

## Deploying the app itself

VocaMac is a normal notarised app bundle. Package the DMG contents for your management tool, or point managed machines at the [Homebrew cask](/#install) if `brew` is already part of your fleet setup. There's no licence server, no account, and no enrolment step inside the app — after the permissions are in place it simply runs.

Transcription happens on the device with a model stored on that Mac. Dictation audio isn't sent to a Voca service, which is usually the part a security review wants in writing. Whisper and Parakeet models download from Hugging Face, specialized ONNX models from sherpa-onnx GitHub releases, and update checks hit the GitHub Releases API on launch when the last check is older than 24 hours. Launch-time update checking cannot be turned off.

Something missing here that your rollout needs? [Open an issue](https://github.com/VocaHQ/vocamac/issues) — deployment questions are welcome.
