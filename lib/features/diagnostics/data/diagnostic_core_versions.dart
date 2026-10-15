/// Build manifest versions, not a claim that a stopped core was executed.
/// The regression test binds this table to core-lock.json.
Map<String, Object> diagnosticCoreVersions(String platform) => {
  'source': 'packaged-manifest',
  'singBox': switch (platform) {
    'android' || 'windows' => '1.14.1-extended-2.7.2',
    'iOS' || 'macOS' || 'linux' => '1.13.12-extended-2.1.2',
    _ => 'none',
  },
  'tun2socks': platform == 'android' ? '2.7.0' : 'none',
};
