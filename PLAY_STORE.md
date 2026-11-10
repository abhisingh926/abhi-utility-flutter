# Publishing on Google Play

The app has two Android flavors:

| Flavor | Command | What it is |
|---|---|---|
| `full` (default) | `flutter run` / `flutter build apk --flavor full` | Every feature, for sideloading. **Never upload to Play.** |
| `play` | `flutter build appbundle --flavor play` | Google Play policy-compliant build. |

What the `play` build changes (see `android/app/src/play/AndroidManifest.xml`, `lib/store_build.dart`):

| Removed / changed | Why (Play policy) |
|---|---|
| VPN tab, OpenVPN service | VpnService: only apps whose core purpose is VPN |
| Uninstall protection (device admin + Settings guard) | Accessibility / device admin may not block uninstalling outside parental-control apps |
| `READ_CALL_LOG`: SOS treats a call of 60 s+ as answered, otherwise waits 8 s (tap Stop) before the next contact | SMS & Call Log policy: call log only for default dialer apps |
| `MANAGE_EXTERNAL_STORAGE`: Excel "all files" list hidden, Status Saver uses the folder picker | All files access policy |
| `WRITE_SECURE_SETTINGS`, `PACKAGE_USAGE_STATS`, `BankingPauseService`: banking pause uses the "tap to resume" notification | Changing settings without the user |
| Downloader refuses Instagram, Facebook, TikTok, X, Snapchat, Vimeo, streaming sites (YouTube is refused in both builds) | Intellectual property: downloading against a site's terms |

## Build

```bash
# once: upload key (keep the .jks and passwords backed up)
keytool -genkey -v -keystore ~/upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
# android/key.properties (never commit): storeFile, storePassword, keyAlias, keyPassword

# each release: bump `version:` in pubspec.yaml (the +number must always increase)
flutter build appbundle --flavor play --release \
  --dart-define=API_URL=https://palegreen-whale-996077.hostingersite.com
# -> build/app/outputs/bundle/playRelease/app-play-release.aab
```

## Store listing

- Privacy policy URL: `https://<server>/privacy` (also linked in the app: Home footer, login/register, Profile, subscription screen).
- Account deletion URL (Data safety → "Delete account URL"): `https://<server>/delete-account`.
- Set `SUPPORT_EMAIL` on the server and use the same address as the Play developer email.
- Do not use WhatsApp, Instagram, YouTube or other brands' names or logos in the title, icon or screenshots.
  Don't show downloads from social sites in screenshots.

## App content → declarations

**Accessibility API** (`ReelCounterService`, `isAccessibilityTool` not set). Purpose: digital wellbeing
(reel counter, App Lock time limits), SOS lock-screen gesture, download button. Upload a short video showing
the in-app disclosure (`lib/applock/accessibility_disclosure.dart`) → "Agree" → Android Accessibility settings
→ the feature working. The disclosure text, `src/play/res/values/strings.xml` and the declaration must match.

**SMS permission (`SEND_SMS`)**. Exception: *physical safety / emergency alerts*. SOS texts the user's chosen
contacts their location / the recording link when no one answers. Video: set up SOS → trigger → SMS sent.
If Google refuses it, remove `SEND_SMS` in `src/play/AndroidManifest.xml` and hide the two
"If no one answers" switches in `lib/sos/sos_page.dart` when `kPlayStore`.

**Foreground service** `specialUse` (`ShakeService`): shake gesture toggles the flashlight while the app is
closed; user-started, with an ongoing notification. Add a video.

**Location** (foreground only, no background permission): SOS location message.

**Data safety** (answer "Data is encrypted in transit: yes", "Users can request deletion: yes"):

| Data type | Collected | Shared | Optional | Purpose |
|---|---|---|---|---|
| Email address, Name | Yes | No | Yes (account) | Account management |
| Photos (profile photo, diary photos in backups) | Yes | No | Yes | App functionality |
| Videos, Audio (SOS recording) | Yes | Yes (SOS contacts via link) | Yes | App functionality |
| Approximate + precise location (SOS) | Yes | Yes (SOS contacts) | Yes | App functionality |
| Other user-generated content (tasks, diary) | Yes | No | Yes | App functionality |
| App interactions (daily reel counts) | Yes | No | Yes | App functionality |
| Purchase history | Yes | No | Yes | App functionality |
| Crash logs / diagnostics (Google ML Kit document scanner) | Yes | No | No | Analytics (by Google) |

Also: content rating questionnaire, target audience 13+ (not designed for children), no ads,
government app: no, financial features: no.

## Before going live

- Personal developer accounts: closed test with 12+ testers for 14 days before production access.
- Test the `play` build on a phone: SOS with a real contact, Status Saver folder picker, Excel open/pick,
  App Lock + reel counter with the accessibility disclosure, a Play subscription in a test track.
