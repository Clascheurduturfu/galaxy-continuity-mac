# v1.0 Beta 3 (53)

- Clipboard Sync automatically joins nearby account phones/tablets through separate authenticated sessions, plus existing Galaxy Book LAN links. Removed the target picker, Home switch menu and per-device Clipboard buttons. A single master switch blocks new outgoing and incoming clipboard items and cancels pending image transfers. A network packet already submitted before switching off cannot be recalled. Connected command links remain available to Multi Control and hotspot when clipboard sharing is off.
- Extra device connections are discovery-driven, deduplicated by Bluetooth identity, and retried with capped backoff only while the peer is advertised. Clipboard content is neither logged nor uploaded. Feature actions reuse the matching authenticated peer session.
- Removed the normal Buds control-channel buttons. Take Audio handles connection and switching; Disconnect keeps pairing. Refresh, Bluetooth Settings and both audio actions have hover explanations.
- GitHub update checks try without authentication first. After the repository becomes public and anonymous access succeeds, the app deletes the updater token and hides the temporary access section. Saved private tokens are checked once on launch as well as manually; no periodic polling. Deleting the local token does not revoke the GitHub token.
- Added Create Read Token to open GitHub's official prefilled fine-grained token form. The owner must choose only this repository and generate/save the token. No broad GitHub CLI token is copied into the app.
- This preview includes the earlier Beta 2 UI, arrangement, Contacts, per-device hotspot and window lifecycle changes.

## Validation

Native arm64 regression build passed all 110 tests with zero failures; the final UI-only release build also passed. Window close/reopen smoke tests passed all five checks, and six synthetic demo images were regenerated and visibly labeled. Independent source review resolved the update redirect-origin finding and found no remaining confidentiality blocker in the reviewed source.

The interrupted installation was rolled back to Beta 2. On resumption through local SSH, the corrected installer took its credential baseline after shutdown and installed Beta 3 (53) successfully. Strict code signing and the previous designated requirement passed; all three private credential files were unchanged at replacement. Normal launch was verified. Native executable SHA-256: `5a52a51a666d5ca2c0041029bb23a0fa7c69920d37c6eda3120621273f04ed36`.

GitHub CI originally selected Xcode 15.4, whose Swift compiler cannot compile `@preconcurrency` conformances. Both workflows now select macOS 15 and installed Xcode 16.4; the build requirement is Swift 6.0+. Long ZIP byte-concatenation expressions were split into explicit append operations for older Swift 6 compilers. Four byte-equivalence cases passed against the previous serializer, and the native 110-test suite passed again. This preserves the image-transfer format. [GitHub build and test validation passed](https://github.com/Clascheurduturfu/galaxy-continuity-mac/actions/runs/40004486346) with the selected toolchain.

The normal Buds controls now have hover explanations. Filtering macOS system/UI sounds out of automatic Buds switching is a feasible follow-up using process audio activity, but is not implemented in this version. Browser media and notifications from the same process need separate treatment.

App/source archives are audited before preview release publication. Deployment records and cleanup checks are retained privately; source contains no live account profile or updater token. Prior Beta 2 edge switching was accepted by the owner. Simultaneous live phone/tablet text and image exchange needs a fresh copy test with both devices discoverable; unit tests are not a substitute.
