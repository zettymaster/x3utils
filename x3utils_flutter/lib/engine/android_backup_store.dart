import 'package:flutter/services.dart';

const androidBackupStoreChannelName = 'dev.x3utils/backup_store';
const androidBackupDirectoryLabel = 'Downloads/x3utils/backup';
const androidSecondCopyDirectoryLabel = 'Documents/x3utils_2nd_copy';
const androidLogsDirectoryLabel = 'Downloads/x3utils/logs';

const MethodChannel _channel = MethodChannel(androidBackupStoreChannelName);

typedef AndroidBackupPublisher =
    Future<String> Function(Uint8List bytes, String fileName);

/// The fixed MediaStore folders the native bridge accepts.
enum AndroidStoreFolder {
  /// `Downloads/x3utils/backup` — backups and their sidecars.
  backup('backup'),

  /// `Documents/x3utils_2nd_copy` — the redundant copy, under a different
  /// parent from the backups.
  secondCopy('second_copy'),

  /// `Downloads/x3utils/logs/<action>` — per-run logs.
  logs('logs');

  const AndroidStoreFolder(this.channelName);
  final String channelName;
}

typedef AndroidFilePublisher =
    Future<String> Function(
      Uint8List bytes,
      String fileName,
      AndroidStoreFolder folder, {
      String? subfolder,
    });

class AndroidBackupStoreException implements Exception {
  const AndroidBackupStoreException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Publishes one already-validated backup through Android scoped storage.
///
/// The native bridge keeps the MediaStore row pending until every byte has
/// been written, so an interrupted save never appears as a completed `.bin`.
Future<String> publishAndroidBackup(Uint8List bytes, String fileName) =>
    _invoke('publishBackup', {'bytes': bytes, 'fileName': fileName});

/// Publishes a `.bin`, `.json` or `.log` into one of the fixed folders, with
/// the same pending-row guarantee as [publishAndroidBackup].
Future<String> publishAndroidFile(
  Uint8List bytes,
  String fileName,
  AndroidStoreFolder folder, {
  String? subfolder,
}) => _invoke('publishFile', {
  'bytes': bytes,
  'fileName': fileName,
  'folder': folder.channelName,
  'subfolder': ?subfolder,
});

Future<String> _invoke(String method, Map<String, Object> arguments) async {
  try {
    final path = await _channel.invokeMethod<String>(method, arguments);
    if (path == null || path.isEmpty) {
      throw const AndroidBackupStoreException(
        'Android storage did not return the saved location.',
      );
    }
    return path;
  } on AndroidBackupStoreException {
    rethrow;
  } on PlatformException catch (error) {
    throw AndroidBackupStoreException(
      error.message ?? 'Android storage failed (${error.code}).',
    );
  } on MissingPluginException {
    throw const AndroidBackupStoreException(
      'Android storage is not available in this build.',
    );
  }
}
