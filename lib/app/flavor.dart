/// Build flavor injected at compile time via --dart-define=FLAVOR=play|direct
/// Defaults to 'direct' so debug/test builds behave like the APK distribution.
const kFlavor = String.fromEnvironment('FLAVOR', defaultValue: 'direct');

bool get isPlayFlavor => kFlavor == 'play';
