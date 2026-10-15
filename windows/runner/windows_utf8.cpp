#include "utils.h"

#include <windows.h>

std::string Utf8FromUtf16(const wchar_t* utf16_string) {
  if (utf16_string == nullptr) return {};

  // Both scanning and allocation are bounded before accepting a protocol URI.
  // Explicit input length excludes the NUL, so an API failure can never turn
  // a signed zero-minus-one result into a multi-gigabyte unsigned allocation.
  constexpr int kMaximumArgumentBytes = 64 * 1024;
  int input_length = 0;
  while (input_length <= kMaximumArgumentBytes && utf16_string[input_length] != L'\0') {
    ++input_length;
  }
  if (input_length == 0 || input_length > kMaximumArgumentBytes) return {};
  const int required = WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string, input_length,
      nullptr, 0, nullptr, nullptr);
  if (required <= 0 || required > kMaximumArgumentBytes) return {};

  std::string encoded(static_cast<size_t>(required), '\0');
  const int converted = WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string, input_length,
      encoded.data(), required, nullptr, nullptr);
  return converted == required ? encoded : std::string();
}
