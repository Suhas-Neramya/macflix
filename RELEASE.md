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
