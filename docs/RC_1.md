# v1.0 RC 1 (54)

## Changes

- Added **Exclude macOS system sounds** to Galaxy Buds Auto Switch. Enabled by default on macOS 14.2 and later; older supported macOS versions retain the original playback watcher and show the unsupported switch disabled.
- Automatic takeover considers CoreAudio output-process activity on the current output device. Recognized macOS alert/UI processes do not trigger takeover. The sound still plays normally. An app or browser notification may still count as app audio; this is not semantic audio classification.
- Reads process metadata only, in memory. No audio tap, microphone capture, audio history, process-identity log or network upload is added. Observation uses CoreAudio property listeners only while needed, with no polling. Missing process information prevents automatic takeover while filtering is on; Take Audio remains available.
- Aligned the Buds, startup and update switches; improved disabled-button styling and light-mode sidebar icons. Renamed the connection Pause action and added an explanation distinguishing it from the all-device Clipboard Sync switch. Clipboard preview now explicitly says Last Received and explains resend behavior.
- Detailed independent UI review covered all eight pages, plus light, narrow and tall variants (18 fictional, visibly labeled renders). Fresh renders now include Clipboard and Settings.

## Validation and delivery boundary

The native Apple Silicon regression run passed **112 tests, zero failures**. Release compilation passed, and a passive probe confirmed CoreAudio process metadata can be read on the build Mac without playing or recording audio. Policy tests cover system-only sound, simultaneous real app playback, default-output routing, unknown metadata and lookalike process identifiers.

Live alert-versus-media Buds takeover has **not** been tested yet. App notifications, reconnect timing, sleep/wake and older macOS acceptance remain useful checks. This release does not change clipboard transport or calling audio.

RC 1 is prepared as a preview release. It was **not installed** on the owner's Mac; the installed app remains **Beta 3 (53)**. Temporary native builds and screenshot renders used an isolated directory and did not replace the app or its credentials.

## Remaining interface polish

The review found no stop-ship issue from the supplied static images. It recommends distinguishing navigation tiles from instant toggles, moving Multi Control's operational controls above its arrangement canvas, and placing account repair actions under a disclosure for healthy signed-in accounts. Static renders do not establish live focus order, keyboard navigation, menu behavior or accessibility acceptance. These recommendations do not require changes to the working transport implementation.

Private updater access remains temporary: anonymous access is tried first; when the repository becomes public and anonymous access succeeds, the app removes the locally saved token and hides the access section. That does not revoke a token at GitHub. No GitHub credential is bundled in RC 1.
