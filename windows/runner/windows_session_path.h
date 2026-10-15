#ifndef RUNNER_WINDOWS_SESSION_PATH_H_
#define RUNNER_WINDOWS_SESSION_PATH_H_

#include <string>

// Read-only native equivalent of the supervisor's Assert-PlainPath. False
// includes any inspection error other than an ordinary not-yet-created path.
bool IsPlainWindowsSessionPath(const std::string& utf8_path);
// False also covers a failed token query: an unconfirmed token cannot launch
// the VPN supervisor under the application's required-administrator policy.
bool IsWindowsSessionProcessElevated();
// HKCU system-proxy writes are valid only for the account owning this desktop.
// Credential elevation under another account is rejected instead of claiming
// that the original user's browser is using the elevated account's proxy.
bool OwnsInteractiveWindowsProxySettings();

#endif
