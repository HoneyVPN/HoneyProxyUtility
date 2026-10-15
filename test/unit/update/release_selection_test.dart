import 'package:flutter_test/flutter_test.dart';
import 'package:honeyproxyutility/features/update/release_selection.dart';

Map<String, dynamic> asset(String name) => {
  'name': name,
  'browser_download_url':
      'https://github.com/HoneyVPN/HoneyProxyUtility/releases/download/v1.2.0/$name',
};

void main() {
  final assets = [asset('client-arm64-v8a.apk'), asset('client-x86_64.apk')];
  test('selects an APK compatible with the device, not the first asset', () {
    expect(
      selectAndroidReleaseUrl(assets, ['x86_64', 'x86']),
      endsWith('x86_64.apk'),
    );
    expect(
      selectAndroidReleaseUrl(assets, ['arm64-v8a', 'armeabi-v7a']),
      endsWith('arm64-v8a.apk'),
    );
    expect(selectAndroidReleaseUrl(assets, ['armeabi-v7a']), isEmpty);
    expect(selectAndroidReleaseUrl(assets, ['x86']), isEmpty);
  });
  test('prefers the compatible universal migration asset over split APKs', () {
    final release = [...assets, asset('HoneyProxyUtility-v1.2.0-universal.apk')];
    for (final abis in [
      ['armeabi-v7a'],
      ['arm64-v8a', 'armeabi-v7a'],
      ['x86_64', 'x86'],
    ]) {
      expect(selectAndroidReleaseUrl(release, abis), endsWith('-universal.apk'));
    }
  });
  test('universal release does not advertise support for unknown-only ABI', () {
    expect(
      selectAndroidReleaseUrl([asset('client-universal.apk')], ['riscv64']),
      isEmpty,
    );
  });
  test('only a universal APK can be used as fallback', () {
    expect(
      selectAndroidReleaseUrl(
        [...assets, asset('HoneyProxyUtility.apk')],
        ['armeabi-v7a'],
      ),
      endsWith('HoneyProxyUtility.apk'),
    );
  });
  test('rejects executable downloads outside the release repository', () {
    final untrusted = {
      'name': 'client-arm64-v8a.apk',
      'browser_download_url': 'http://example.com/client.apk',
    };
    expect(selectAndroidReleaseUrl([untrusted], ['arm64-v8a']), isEmpty);
    expect(
      selectWindowsReleaseUrl([asset('HoneyProxyUtility-Setup.exe')]),
      endsWith('.exe'),
    );
  });
  test('compares tags, stable releases, prereleases and build metadata', () {
    expect(compareReleaseVersions('v1.2.0', '1.1.21'), greaterThan(0));
    expect(compareReleaseVersions('1.2.0', '1.2.0-rc.1'), greaterThan(0));
    expect(compareReleaseVersions('1.2.0-rc.10', '1.2.0-rc.2'), greaterThan(0));
    expect(compareReleaseVersions('1.2.0+120', '1.2.0+121'), 0);
    expect(compareReleaseVersions('1.2.0-rc.1', '1.2.0'), lessThan(0));
    expect(compareReleaseVersions('main', '1.2.0'), isNull);
    expect(compareReleaseVersions('1.2.0-01', '1.2.0'), isNull);
  });
}
