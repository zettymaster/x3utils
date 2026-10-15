// Derived from swdart, MIT licensed. See third_party/swdart/LICENSE.
// Native libusb transport for the desktop swdart backend. libusb runs in a
// worker isolate; see [_UsbWorker].
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'transport.dart';
import 'util.dart';

const _stlinkPids = <int>[
  0x3748,
  0x374b,
  0x3752,
  0x374d,
  0x374e,
  0x374f,
  0x3753,
  0x3754,
  0x3755,
  0x3757,
];

const _outEp01Pids = <int>{
  0x374b,
  0x3752,
  0x374d,
  0x374e,
  0x374f,
  0x3753,
  0x3754,
  0x3755,
  0x3757,
};

const _epIn = 0x81;
const _interface = 0;
const _timeout = 2000;

int _outEndpoint(int pid) => _outEp01Pids.contains(pid) ? 0x01 : 0x02;

typedef _InitNative = Int32 Function(Pointer<Pointer<Void>>);
typedef _InitDart = int Function(Pointer<Pointer<Void>>);
typedef _ExitNative = Void Function(Pointer<Void>);
typedef _ExitDart = void Function(Pointer<Void>);
typedef _OpenVidPidNative =
    Pointer<Void> Function(Pointer<Void>, Uint16, Uint16);
typedef _OpenVidPidDart = Pointer<Void> Function(Pointer<Void>, int, int);
typedef _CloseNative = Void Function(Pointer<Void>);
typedef _CloseDart = void Function(Pointer<Void>);
typedef _ClaimNative = Int32 Function(Pointer<Void>, Int32);
typedef _ClaimDart = int Function(Pointer<Void>, int);
typedef _AutoDetachNative = Int32 Function(Pointer<Void>, Int32);
typedef _AutoDetachDart = int Function(Pointer<Void>, int);
typedef _BulkNative =
    Int32 Function(
      Pointer<Void>,
      Uint8,
      Pointer<Uint8>,
      Int32,
      Pointer<Int32>,
      Uint32,
    );
typedef _BulkDart =
    int Function(Pointer<Void>, int, Pointer<Uint8>, int, Pointer<Int32>, int);

class _Libusb {
  _Libusb(DynamicLibrary library)
    : init = library.lookupFunction<_InitNative, _InitDart>('libusb_init'),
      exit = library.lookupFunction<_ExitNative, _ExitDart>('libusb_exit'),
      openVidPid = library.lookupFunction<_OpenVidPidNative, _OpenVidPidDart>(
        'libusb_open_device_with_vid_pid',
      ),
      closeHandle = library.lookupFunction<_CloseNative, _CloseDart>(
        'libusb_close',
      ),
      claim = library.lookupFunction<_ClaimNative, _ClaimDart>(
        'libusb_claim_interface',
      ),
      release = library.lookupFunction<_ClaimNative, _ClaimDart>(
        'libusb_release_interface',
      ),
      autoDetach = library.lookupFunction<_AutoDetachNative, _AutoDetachDart>(
        'libusb_set_auto_detach_kernel_driver',
      ),
      bulk = library.lookupFunction<_BulkNative, _BulkDart>(
        'libusb_bulk_transfer',
      );

  final _InitDart init;
  final _ExitDart exit;
  final _OpenVidPidDart openVidPid;
  final _CloseDart closeHandle;
  final _ClaimDart claim;
  final _ClaimDart release;
  final _AutoDetachDart autoDetach;
  final _BulkDart bulk;

  static _Libusb open() {
    final executableDirectory = File(Platform.resolvedExecutable).parent.path;
    final candidates = <String>[];
    if (Platform.isWindows) {
      candidates.addAll([
        'libusb-1.0.dll',
        '$executableDirectory\\libusb-1.0.dll',
      ]);
    } else if (Platform.isMacOS) {
      candidates.addAll([
        '$executableDirectory/native/macos/oocd/libexec/'
            'libusb-1.0.0.dylib',
        'libusb-1.0.0.dylib',
        'libusb-1.0.dylib',
        '$executableDirectory/../Frameworks/libusb-1.0.0.dylib',
        '$executableDirectory/../Frameworks/libusb-1.0.dylib',
        '/opt/homebrew/lib/libusb-1.0.0.dylib',
        '/usr/local/lib/libusb-1.0.0.dylib',
      ]);
    } else {
      candidates.addAll([
        'libusb-1.0.so.0',
        'libusb-1.0.so',
        '$executableDirectory/lib/libusb-1.0.so.0',
        '$executableDirectory/lib/libusb-1.0.so',
        '/usr/lib/x86_64-linux-gnu/libusb-1.0.so.0',
        '/lib/x86_64-linux-gnu/libusb-1.0.so.0',
      ]);
    }
    for (final name in candidates) {
      try {
        return _Libusb(DynamicLibrary.open(name));
      } catch (_) {}
    }
    throw SwdException(
      'libusb-1.0 could not be loaded. Bundle it beside the application or '
      'install it system-wide.',
    );
  }
}

/// One open ST-Link inside the worker isolate. Every libusb call is
/// synchronous FFI, so it only ever runs there.
class _WorkerDevice {
  _WorkerDevice(this._library, this._context, this._handle, this.pid);

  final _Libusb _library;
  final Pointer<Void> _context;
  final Pointer<Void> _handle;
  final int pid;

  void _bulkOut(int endpoint, Uint8List data) {
    final buffer = malloc<Uint8>(data.length);
    final transferred = malloc<Int32>();
    try {
      buffer.asTypedList(data.length).setAll(0, data);
      final result = _library.bulk(
        _handle,
        endpoint,
        buffer,
        data.length,
        transferred,
        _timeout,
      );
      if (result != 0) {
        throw SwdException('libusb bulk OUT failed: $result');
      }
    } finally {
      malloc.free(buffer);
      malloc.free(transferred);
    }
  }

  Uint8List _bulkIn(int endpoint, int length) {
    final buffer = malloc<Uint8>(length);
    final transferred = malloc<Int32>();
    try {
      final result = _library.bulk(
        _handle,
        endpoint,
        buffer,
        length,
        transferred,
        _timeout,
      );
      if (result != 0) {
        throw SwdException('libusb bulk IN failed: $result');
      }
      return Uint8List.fromList(buffer.asTypedList(transferred.value));
    } finally {
      malloc.free(buffer);
      malloc.free(transferred);
    }
  }

  Uint8List xfer(Uint8List packet, Uint8List? data, int rxLen) {
    final endpointOut = _outEndpoint(pid);
    _bulkOut(endpointOut, packet);
    if (data != null && data.isNotEmpty) _bulkOut(endpointOut, data);
    if (rxLen > 0) return _bulkIn(_epIn, rxLen);
    return Uint8List(0);
  }

  void close() {
    try {
      _library.release(_handle, _interface);
    } catch (_) {}
    _library.closeHandle(_handle);
    _library.exit(_context);
  }
}

_WorkerDevice? _workerOpen(_Libusb library) {
  final contextPointer = malloc<Pointer<Void>>();
  try {
    if (library.init(contextPointer) != 0) {
      throw SwdException('libusb_init failed');
    }
    final context = contextPointer.value;
    for (final pid in _stlinkPids) {
      final handle = library.openVidPid(context, stlinkVid, pid);
      if (handle == nullptr) continue;
      try {
        library.autoDetach(handle, 1);
      } catch (_) {}
      final result = library.claim(handle, _interface);
      if (result != 0) {
        library.closeHandle(handle);
        library.exit(context);
        throw SwdException(
          'libusb_claim_interface failed: $result (WinUSB driver bound?)',
        );
      }
      return _WorkerDevice(library, context, handle, pid);
    }
    library.exit(context);
    return null;
  } finally {
    malloc.free(contextPointer);
  }
}

/// Worker isolate entry. Requests are `[id, op, ...args]` and are handled one
/// at a time, in order; each reply is `[id, error-or-null, result]`.
///
/// A handle closed by one request (for example Cancel's disconnect) makes any
/// later request on it fail cleanly instead of touching freed libusb memory.
void _workerMain(SendPort toMain) {
  final requests = ReceivePort();
  toMain.send(requests.sendPort);
  _Libusb? library;
  final devices = <int, _WorkerDevice>{};
  var nextHandle = 1;
  requests.listen((message) {
    final request = message as List<Object?>;
    final id = request[0] as int;
    try {
      final Object? result;
      switch (request[1] as String) {
        case 'open':
          final device = _workerOpen(library ??= _Libusb.open());
          if (device == null) {
            result = null;
          } else {
            final handle = nextHandle++;
            devices[handle] = device;
            result = [handle, device.pid];
          }
        case 'xfer':
          final device = devices[request[2] as int];
          if (device == null) throw SwdException('libusb device closed');
          result = device.xfer(
            request[3] as Uint8List,
            request[4] as Uint8List?,
            request[5] as int,
          );
        case 'close':
          devices.remove(request[2] as int)?.close();
          result = null;
        default:
          throw StateError('unknown USB worker request ${request[1]}');
      }
      toMain.send([id, null, result]);
    } catch (error) {
      toMain.send([id, '$error', null]);
    }
  });
}

/// Main-isolate side of the USB worker: spawned once, lives for the app.
///
/// Desktop swdart used to call libusb directly on the UI isolate. A bulk
/// transfer can block for up to [_timeout] and a device open enumerates USB,
/// so a Power-race that kept missing starved the UI and Cancel was never
/// processed until a catch. Here every call is a message, so each `await`
/// really yields to the event loop.
class _UsbWorker {
  _UsbWorker._(this._toWorker);

  final SendPort _toWorker;
  final _pending = <int, Completer<Object?>>{};
  var _nextId = 0;

  static Future<_UsbWorker>? _instance;

  static Future<_UsbWorker> get instance => _instance ??= _spawn();

  static Future<_UsbWorker> _spawn() async {
    final replies = ReceivePort();
    final ready = Completer<SendPort>();
    late final _UsbWorker worker;
    replies.listen((message) {
      if (!ready.isCompleted) {
        ready.complete(message as SendPort);
        return;
      }
      final reply = message as List<Object?>;
      final completer = worker._pending.remove(reply[0] as int);
      if (completer == null) return;
      final error = reply[1] as String?;
      if (error != null) {
        completer.completeError(SwdException(error));
      } else {
        completer.complete(reply[2]);
      }
    });
    try {
      await Isolate.spawn(
        _workerMain,
        replies.sendPort,
        debugName: 'x3utils-usb',
      );
    } catch (_) {
      replies.close();
      _instance = null;
      rethrow;
    }
    worker = _UsbWorker._(await ready.future);
    return worker;
  }

  Future<Object?> call(String op, [List<Object?> args = const []]) {
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _toWorker.send([id, op, ...args]);
    return completer.future;
  }
}

class _NativeUsbTransport implements UsbTransport {
  _NativeUsbTransport(this._worker, this._handle, this._pid);

  final _UsbWorker _worker;
  final int _handle;
  final int _pid;

  @override
  int get productId => _pid;

  @override
  String get productName =>
      isV3 ? 'STLINK-V3' : (_pid == 0x3748 ? 'ST-Link/V2' : 'ST-Link/V2-1');

  @override
  bool get isV3 => v3Pids.contains(_pid);

  @override
  Future<Uint8List> xfer(
    List<int> command, {
    int rxLen = 0,
    Uint8List? data,
  }) async {
    final packet = Uint8List(16)..setRange(0, command.length, command);
    final result = await _worker.call('xfer', [_handle, packet, data, rxLen]);
    return result as Uint8List;
  }

  @override
  Future<void> close() => _worker.call('close', [_handle]);
}

Future<UsbTransport?> _open() async {
  final worker = await _UsbWorker.instance;
  final opened = await worker.call('open') as List<Object?>?;
  if (opened == null) return null;
  return _NativeUsbTransport(worker, opened[0] as int, opened[1] as int);
}

UsbDeviceStatus get initialStlinkStatus =>
    const UsbDeviceStatus(UsbDeviceState.ready);

Future<UsbDeviceStatus> refreshStlinkSelection() async => initialStlinkStatus;

Future<UsbDeviceStatus> selectStlink() async => initialStlinkStatus;

void watchStlinkSelection(UsbDeviceStatusListener listener) {}

Future<UsbTransport> openSelectedStlink() async {
  final transport = await _open();
  if (transport == null) {
    throw const UsbAcquireException(
      UsbAcquireFailureKind.unavailable,
      'No ST-Link found on USB',
    );
  }
  return transport;
}
