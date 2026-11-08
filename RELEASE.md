# GitHub release

1. Set `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist` for the release. The short version is the single source for artifact names and the `vMAJOR.MINOR.PATCH` tag.
2. Commit the release changes, then tag and push that commit:

   ```sh
   version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
   git tag "v$version"
   git push origin "v$version"
   ```

3. The tag workflow fetches Apple’s public parser fixtures, runs the checks, builds and verifies the DMG and source archive, writes `SHA256SUMS`, and creates a draft GitHub Release. Publish the draft after reviewing its notes and assets.

The workflow uses GitHub’s `GITHUB_TOKEN` with repository contents write permission. The default app signature is ad hoc; the DMG is not notarized. A Developer ID identity can be configured as `MACFLIX_SIGNING_IDENTITY` in the workflow environment when one is available. Do not add signing secrets to the repository or commit local fixtures.

## Sparkle automatic updates

The updater is intentionally dormant until a maintainer configures both the matching `SUPublicEDKey` in `Resources/Info.plist` and the `SPARKLE_PRIVATE_KEY` GitHub Actions secret. The user installs the next updater-enabled release manually once; Sparkle then verifies its signed appcast and installer before offering later updates. Until both values are configured, startup checks and the Check for Updates menu item stay hidden, and release drafts omit `appcast.xml`. The release script rejects half-configured or mismatched keys. Keep the private key in the maintainer's secure keychain and GitHub encrypted secrets only; never commit it or include it in release artifacts. See [Sparkle's signing and publishing guide](https://sparkle-project.org/documentation/publishing/).
