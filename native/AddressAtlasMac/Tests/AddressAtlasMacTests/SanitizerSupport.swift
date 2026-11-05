import Foundation

/// Runtime checks for sanitizer builds, shared by the tests that assert a
/// wall-clock budget.
enum TestSanitizer {
  /// True when the test process runs under Thread Sanitizer
  /// (`swift test --sanitize=thread`). It instruments every memory access, so a
  /// debug build runs several times slower and wall-clock budgets do not hold.
  /// The check looks for the runtime's `__tsan_init` symbol; RTLD_DEFAULT is
  /// `(void *)-2` on Darwin and is not imported into Swift.
  static let isThreadSanitizerActive: Bool =
    dlsym(UnsafeMutableRawPointer(bitPattern: -2), "__tsan_init") != nil
}
