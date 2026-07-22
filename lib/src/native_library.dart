// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: MIT

import 'dart:ffi' as ffi;

import 'ffi/lw_bindings.dart' show LwBindings;

/// The ABI this package's generated bindings were produced from. Checked
/// against the loaded library so a mismatched pair fails at load rather than
/// at some later call with a shifted struct.
const int kExpectedAbiVersion = 4;

/// Default shared-object name, resolved through the dynamic linker.
const String kLibwebrtcName = 'libwebrtc.so';

/// Thrown when the native library cannot be opened, or reports an ABI this
/// package was not generated against.
class RtcNativeException implements Exception {
  RtcNativeException(this.message);

  final String message;

  @override
  String toString() => 'RtcNativeException: $message';
}

/// The loaded library: its generated bindings plus the pieces the idiomatic
/// layer needs that bindings alone do not expose, notably a function pointer
/// to `lw_release` for [ffi.NativeFinalizer].
///
/// The library is process-global -- the sink registry is a process-wide
/// singleton -- so [load] returns the same instance for repeated calls.
class NativeLibrary {
  NativeLibrary._(this.bindings, this.releasePointer);

  final LwBindings bindings;

  /// `void lw_release(void*)`, which matches the shape a native finalizer
  /// requires, so every handle can be reclaimed without the caller's help.
  final ffi.Pointer<ffi.NativeFinalizerFunction> releasePointer;

  static NativeLibrary? _instance;

  /// Opens the library (once per process) and verifies its ABI.
  static NativeLibrary load({String? path}) {
    final existing = _instance;
    if (existing != null) {
      return existing;
    }
    final ffi.DynamicLibrary library;
    try {
      library = ffi.DynamicLibrary.open(path ?? kLibwebrtcName);
    } on ArgumentError catch (e) {
      throw RtcNativeException('cannot open ${path ?? kLibwebrtcName}: $e');
    }
    final bindings = LwBindings(library);
    final abi = bindings.lw_abi_version();
    if (abi != kExpectedAbiVersion) {
      throw RtcNativeException(
        'ABI mismatch: bindings expect $kExpectedAbiVersion, library reports $abi',
      );
    }
    final release = library.lookup<ffi.NativeFinalizerFunction>('lw_release');
    final instance = NativeLibrary._(bindings, release);
    _instance = instance;
    return instance;
  }

  /// The already-loaded library.
  ///
  /// Throws when nothing has loaded it yet, which is the caller forgetting
  /// `Rtc.initialize()` rather than anything native going wrong.
  static NativeLibrary get instance {
    final loaded = _instance;
    if (loaded == null) {
      throw StateError('Rtc.initialize() has not been called');
    }
    return loaded;
  }

  /// Visible for testing: forget the cached instance so a later [load] reopens.
  static void resetForTesting() => _instance = null;
}
