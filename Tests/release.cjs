const {spawnSync} = require('node:child_process');
const assert = require('node:assert/strict');
const path = require('node:path');

const root = path.join(__dirname, '..');
const script = path.join(root, 'bin/release.sh');
const versionResult = spawnSync('/usr/libexec/PlistBuddy', ['-c', 'Print :CFBundleShortVersionString', path.join(root, 'Resources/Info.plist')], {encoding: 'utf8'});
assert.equal(versionResult.status, 0);
const version = versionResult.stdout.trim();
function check(tag) {
  return spawnSync('bash', [script, '--check-tag', tag], {cwd: root, encoding: 'utf8'});
}

assert.equal(check(`v${version}`).status, 0);
for (const tag of [version, `v${version.split('.').slice(0, 2).join('.')}`, `v${version}.1`, `v${version};touch /tmp/release-injection`]) {
  assert.notEqual(check(tag).status, 0, `accepted invalid release tag: ${tag}`);
}
console.log('Passed: release tags are strict semantic versions matching Info.plist.');
