#ifndef TAMAYURA_TEST_SUPPORT_H_
#define TAMAYURA_TEST_SUPPORT_H_

#include <fcntl.h>
#include <glib.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <iostream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include "storage_core.h"

namespace tamayura_test {

inline void Expect(bool result, const std::string& message) {
  if (!result) throw std::runtime_error(message);
}

// Expects a StorageError with `code`; an empty code accepts any StorageError.
inline void Reject(const std::string& code, const std::function<void()>& body) {
  try {
    body();
  } catch (const tamayura::StorageError& error) {
    Expect(code.empty() || error.code == code,
           "Unexpected error " + error.code + ": " + error.what() +
               " (expected " + code + ")");
    return;
  }
  throw std::runtime_error("Expected the operation to fail with " + code);
}

// A private directory removed recursively when the test ends.
class TempDirectory {
 public:
  TempDirectory() {
    gchar* path = g_dir_make_tmp("tamayura-test-XXXXXX", nullptr);
    if (!path) throw std::runtime_error("Cannot create a test directory");
    char* resolved = realpath(path, nullptr);
    g_free(path);
    if (!resolved) throw std::runtime_error("Cannot resolve a test directory");
    path_ = resolved;
    free(resolved);
  }
  ~TempDirectory() { Remove(path_); }
  TempDirectory(const TempDirectory&) = delete;
  TempDirectory& operator=(const TempDirectory&) = delete;
  const std::string& path() const { return path_; }
  std::string operator/(const std::string& name) const { return path_ + "/" + name; }

  static void Remove(const std::string& path) {
    struct stat info {};
    if (lstat(path.c_str(), &info) != 0) return;
    if (S_ISDIR(info.st_mode)) {
      // Restore permissions changed by a test so cleanup can proceed.
      chmod(path.c_str(), 0700);
      if (GDir* directory = g_dir_open(path.c_str(), 0, nullptr)) {
        std::vector<std::string> names;
        while (const gchar* name = g_dir_read_name(directory)) names.emplace_back(name);
        g_dir_close(directory);
        for (const auto& name : names) Remove(path + "/" + name);
      }
      rmdir(path.c_str());
    } else {
      unlink(path.c_str());
    }
  }

 private:
  std::string path_;
};

inline void MakeDirectory(const std::string& path, mode_t mode = 0755) {
  Expect(g_mkdir_with_parents(path.c_str(), mode) == 0, "Cannot create " + path);
}

inline void WriteFile(const std::string& path, const tamayura::Bytes& bytes) {
  const int fd = open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
  Expect(fd >= 0, "Cannot write fixture " + path);
  size_t written = 0;
  while (written < bytes.size()) {
    const ssize_t amount = write(fd, bytes.data() + written, bytes.size() - written);
    if (amount <= 0) {
      close(fd);
      throw std::runtime_error("Cannot write fixture bytes " + path);
    }
    written += static_cast<size_t>(amount);
  }
  close(fd);
}

inline void WriteText(const std::string& path, const std::string& text) {
  WriteFile(path, tamayura::Bytes(text.begin(), text.end()));
}

inline tamayura::Bytes ReadFile(const std::string& path) {
  gchar* contents = nullptr;
  gsize length = 0;
  Expect(g_file_get_contents(path.c_str(), &contents, &length, nullptr),
         "Cannot read " + path);
  tamayura::Bytes bytes(reinterpret_cast<uint8_t*>(contents),
                        reinterpret_cast<uint8_t*>(contents) + length);
  g_free(contents);
  return bytes;
}

inline bool Exists(const std::string& path) {
  struct stat info {};
  return lstat(path.c_str(), &info) == 0;
}

inline tamayura::Bytes Pattern(size_t size, uint8_t seed = 1) {
  tamayura::Bytes bytes(size);
  for (size_t index = 0; index < size; ++index) {
    bytes[index] = static_cast<uint8_t>(seed + index * 131 + (index >> 9));
  }
  return bytes;
}

struct TestCase {
  const char* name;
  std::function<void()> body;
};

// Runs every case, reports each failure and returns the process status.
inline int RunTests(const char* suite, const std::vector<TestCase>& cases) {
  int failures = 0;
  for (const auto& test : cases) {
    try {
      test.body();
      std::cout << "[pass] " << suite << ": " << test.name << '\n';
    } catch (const std::exception& error) {
      ++failures;
      std::cerr << "[FAIL] " << suite << ": " << test.name << ": " << error.what() << '\n';
    }
  }
  std::cout << suite << ": " << (cases.size() - failures) << "/" << cases.size()
            << " passed\n";
  return failures == 0 ? 0 : 1;
}

}  // namespace tamayura_test

#endif  // TAMAYURA_TEST_SUPPORT_H_
