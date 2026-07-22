// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: MIT

import 'dart:ffi' as ffi;

import 'native_library.dart';

/// Base for every native handle the library hands out.
///
/// Each handle owns one reference. Collecting the Dart object releases it, so
/// forgetting to dispose leaks nothing; [dispose] only makes the release
/// prompt, which matters for the objects that own threads or devices. Using a
/// handle after [dispose] throws rather than reaching into freed memory.
///
/// No `ffi.Pointer` escapes this class: subclasses reach the raw pointer
/// through [pointer], which is library-private.
abstract class RtcHandle implements ffi.Finalizable {
  RtcHandle(this._pointer, this._library) {
    if (_pointer == ffi.nullptr) {
      throw StateError('$runtimeType constructed from a null handle');
    }
    _finalizer.attach(this, _pointer.cast<ffi.Void>(), detach: this);
  }

  ffi.Pointer<ffi.Void> _pointer;
  final NativeLibrary _library;
  bool _disposed = false;

  static final Map<ffi.Pointer<ffi.NativeFinalizerFunction>,
      ffi.NativeFinalizer> _finalizers = {};

  ffi.NativeFinalizer get _finalizer => _finalizers.putIfAbsent(
        _library.releasePointer,
        () => ffi.NativeFinalizer(_library.releasePointer),
      );

  /// The library this handle came from, for subclasses issuing further calls.
  NativeLibrary get library => _library;

  /// Whether [dispose] has been called.
  bool get isDisposed => _disposed;

  /// The raw handle. Library-private: nothing outside this package should hold
  /// a pointer, and it must not outlive the handle.
  ffi.Pointer<ffi.Void> get pointer {
    if (_disposed) {
      throw StateError('$runtimeType used after dispose');
    }
    return _pointer;
  }

  /// Releases the reference now instead of at collection. Idempotent.
  ///
  /// Subclasses that must quiesce something first -- closing a peer
  /// connection, unbinding a sink -- override [beforeRelease].
  void dispose() {
    if (_disposed) {
      return;
    }
    beforeRelease();
    _disposed = true;
    _finalizer.detach(this);
    _library.bindings.lw_release(_pointer);
    _pointer = ffi.nullptr;
  }

  /// Hook for teardown that must happen while the handle is still valid.
  void beforeRelease() {}
}
