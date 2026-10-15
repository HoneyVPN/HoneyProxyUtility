#include "windows_latency_process.h"

#include "windows_session_path.h"

#include <filesystem>
#include <limits>
#include <vector>

namespace {
struct Handle {
  HANDLE value = nullptr;
  explicit Handle(HANDLE handle = nullptr) : value(handle) {}
  ~Handle() { if (value != nullptr && value != INVALID_HANDLE_VALUE) CloseHandle(value); }
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;
  bool valid() const { return value != nullptr && value != INVALID_HANDLE_VALUE; }
};

std::wstring Wide(const std::string& value) {
  if (value.empty() || value.find('\0') != std::string::npos ||
      value.size() > static_cast<size_t>(std::numeric_limits<int>::max())) return {};
  const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0);
  if (count <= 0) return {};
  std::wstring result(count, L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), result.data(), count) != count) return {};
  return result;
}

std::wstring BundledBinary() {
  std::vector<wchar_t> module(32768);
  const DWORD length = GetModuleFileNameW(nullptr, module.data(),
      static_cast<DWORD>(module.size()));
  if (length == 0 || length >= module.size()) return {};
  return (std::filesystem::path(std::wstring(module.data(), length)).parent_path() /
      L"sing-box.exe").wstring();
}

bool EqualPath(const std::filesystem::path& a, const std::filesystem::path& b) {
  auto clean = [](const std::filesystem::path& path) {
    auto result = path.lexically_normal();
    while (result.filename().empty() && result.parent_path() != result) {
      result = result.parent_path();
    }
    return result.wstring();
  };
  const auto left = clean(a);
  const auto right = clean(b);
  return CompareStringOrdinal(left.c_str(), -1, right.c_str(), -1, TRUE) == CSTR_EQUAL;
}

HANDLE LockDirectory(const std::filesystem::path& path) {
  // Omit FILE_SHARE_DELETE so the checked path cannot be renamed/replaced with
  // a junction between validation and core startup or while the child owns it.
  HANDLE handle = CreateFileW(path.c_str(), FILE_READ_ATTRIBUTES,
      FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
  if (handle == INVALID_HANDLE_VALUE) return nullptr;
  FILE_ATTRIBUTE_TAG_INFO attributes{};
  if (!GetFileInformationByHandleEx(handle, FileAttributeTagInfo, &attributes,
          sizeof(attributes)) ||
      (attributes.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0 ||
      (attributes.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
    CloseHandle(handle);
    return nullptr;
  }
  return handle;
}
}  // namespace

struct WindowsLatencyProcessManager::Child {
  Handle process;
  Handle job;
  Handle directory;
  Handle parent_directory;
  Handle config;
  Child(HANDLE process_handle, HANDLE job_handle, HANDLE directory_handle,
      HANDLE parent_handle, HANDLE config_handle)
      : process(process_handle), job(job_handle), directory(directory_handle),
        parent_directory(parent_handle), config(config_handle) {}
  ~Child() {
    // Kill-on-close precedes releasing checked directory/config handles.
    if (job.valid()) {
      CloseHandle(job.value);
      job.value = nullptr;
    }
    if (process.valid()) WaitForSingleObject(process.value, 1000);
  }
};

WindowsLatencyProcessManager::WindowsLatencyProcessManager()
    : binary_(BundledBinary()) {}
WindowsLatencyProcessManager::WindowsLatencyProcessManager(const std::wstring& fixture_binary)
    : binary_(fixture_binary) {}
WindowsLatencyProcessManager::~WindowsLatencyProcessManager() = default;

uint64_t WindowsLatencyProcessManager::Start(const std::string& config_utf8,
    const std::string& directory_utf8) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (children_.size() >= 4 || binary_.empty() ||
      !IsPlainWindowsSessionPath(config_utf8) ||
      !IsPlainWindowsSessionPath(directory_utf8)) return 0;
  try {
    const std::filesystem::path directory(Wide(directory_utf8));
    const std::filesystem::path config(Wide(config_utf8));
    std::vector<wchar_t> temp_buffer(32768);
    const DWORD temp_length = GetTempPathW(static_cast<DWORD>(temp_buffer.size()),
        temp_buffer.data());
    if (temp_length == 0 || temp_length >= temp_buffer.size()) return 0;
    const std::filesystem::path temporary(std::wstring(temp_buffer.data(), temp_length));
    if (!directory.is_absolute() || !config.is_absolute() ||
        !EqualPath(directory.parent_path(), temporary) ||
        directory.filename().wstring().rfind(L"honey-latency-", 0) != 0 ||
        !EqualPath(config, directory / L"config.json")) return 0;
    const DWORD binary_attributes = GetFileAttributesW(binary_.c_str());
    if (binary_attributes == INVALID_FILE_ATTRIBUTES ||
        (binary_attributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) != 0)
      return 0;
    Handle parent_lock(LockDirectory(directory.parent_path()));
    Handle directory_lock(LockDirectory(directory));
    Handle config_lock(CreateFileW(config.c_str(), GENERIC_READ, FILE_SHARE_READ,
        nullptr, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
    FILE_ATTRIBUTE_TAG_INFO attributes{};
    if (!parent_lock.valid() || !directory_lock.valid() || !config_lock.valid() ||
        !GetFileInformationByHandleEx(config_lock.value, FileAttributeTagInfo,
            &attributes, sizeof(attributes)) ||
        (attributes.FileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) != 0)
      return 0;
    Handle job(CreateJobObjectW(nullptr, nullptr));
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limit{};
    limit.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!job.valid() || !SetInformationJobObject(job.value,
        JobObjectExtendedLimitInformation, &limit, sizeof(limit))) return 0;
    SECURITY_ATTRIBUTES security{sizeof(security), nullptr, TRUE};
    Handle null_io(CreateFileW(L"NUL", GENERIC_READ | GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE, &security, OPEN_EXISTING, 0, nullptr));
    if (!null_io.valid()) return 0;
    STARTUPINFOEXW startup{};
    startup.StartupInfo.cb = sizeof(startup);
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    startup.StartupInfo.hStdInput = null_io.value;
    startup.StartupInfo.hStdOutput = null_io.value;
    startup.StartupInfo.hStdError = null_io.value;
    SIZE_T list_size = 0;
    InitializeProcThreadAttributeList(nullptr, 1, 0, &list_size);
    if (list_size == 0) return 0;
    std::vector<BYTE> storage(list_size);
    startup.lpAttributeList = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(storage.data());
    if (!InitializeProcThreadAttributeList(startup.lpAttributeList, 1, 0, &list_size)) return 0;
    const bool attributes_set = UpdateProcThreadAttribute(startup.lpAttributeList, 0,
        PROC_THREAD_ATTRIBUTE_HANDLE_LIST, &null_io.value, sizeof(HANDLE), nullptr, nullptr) != 0;
    PROCESS_INFORMATION info{};
    std::wstring command = L"\"" + binary_ + L"\" run -c \"" + config.wstring() + L"\"";
    const BOOL created = attributes_set && CreateProcessW(binary_.c_str(), command.data(),
        nullptr, nullptr, TRUE,
        CREATE_NO_WINDOW | CREATE_SUSPENDED | EXTENDED_STARTUPINFO_PRESENT,
        nullptr, directory.c_str(), &startup.StartupInfo, &info);
    DeleteProcThreadAttributeList(startup.lpAttributeList);
    if (!created) return 0;
    Handle process(info.hProcess);
    Handle thread(info.hThread);
    if (!AssignProcessToJobObject(job.value, process.value) ||
        ResumeThread(thread.value) == static_cast<DWORD>(-1)) {
      TerminateProcess(process.value, ERROR_CANCELLED);
      WaitForSingleObject(process.value, 1000);
      return 0;
    }
    const uint64_t id = ++next_id_;
    children_[id] = std::make_unique<Child>(process.value, job.value,
        directory_lock.value, parent_lock.value, config_lock.value);
    process.value = nullptr;
    job.value = nullptr;
    directory_lock.value = nullptr;
    parent_lock.value = nullptr;
    config_lock.value = nullptr;
    return id;
  } catch (...) {
    return 0;
  }
}

WindowsLatencyStatus WindowsLatencyProcessManager::Status(uint64_t id) {
  std::lock_guard<std::mutex> lock(mutex_);
  const auto found = children_.find(id);
  if (found == children_.end()) return {};
  WindowsLatencyStatus status;
  status.known = true;
  const DWORD waited = WaitForSingleObject(found->second->process.value, 0);
  if (waited != WAIT_OBJECT_0 && waited != WAIT_TIMEOUT) return {};
  status.exited = waited == WAIT_OBJECT_0;
  if (status.exited && !GetExitCodeProcess(found->second->process.value, &status.exit_code)) {
    status.known = false;
  }
  return status;
}

bool WindowsLatencyProcessManager::Stop(uint64_t id) {
  std::lock_guard<std::mutex> lock(mutex_);
  const auto found = children_.find(id);
  if (found == children_.end()) return false;
  const HANDLE process = found->second->process.value;
  if (WaitForSingleObject(process, 0) != WAIT_OBJECT_0 &&
      !TerminateJobObject(found->second->job.value, ERROR_CANCELLED)) return false;
  if (WaitForSingleObject(process, 1000) != WAIT_OBJECT_0) return false;
  // Close the job too, retiring any descendants even after the original child
  // exits. The retained process handle remains bound to that child throughout.
  children_.erase(found);
  return true;
}
