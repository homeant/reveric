// 职责: 在 UDP 控制已预备下一次选择时，将桌面文件选择结果交给控制端填写。
// 关联文件:
//   lib/desktop/features/udp_control/server.dart
//   lib/main.dart

import 'dart:async';
import 'dart:io';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';

class UdpFileDialog extends FileSelectorPlatform {
  UdpFileDialog(this._delegate);

  final FileSelectorPlatform _delegate;
  bool _armed = false;
  Completer<List<String>>? _completion;
  String? _kind;
  List<XTypeGroup>? _types;
  String? _suggestedName;

  void arm() {
    if (_armed || _completion != null) {
      throw StateError('A file dialog is already armed or pending');
    }
    _armed = true;
  }

  void cancel() {
    if (_armed) {
      _armed = false;
      return;
    }
    complete([]);
  }

  void dispose() {
    _armed = false;
    final completion = _completion;
    _completion = null;
    _kind = null;
    _types = null;
    _suggestedName = null;
    completion?.complete([]);
  }

  Map<String, Object?> get pending => {
    'armed': _armed,
    'kind': _kind,
    'suggestedName': _suggestedName,
    'acceptedTypes': _types?.map((group) => group.label).toList(),
  };

  void complete(List<String> paths) {
    final completion = _completion;
    final kind = _kind;
    if (completion == null || kind == null) {
      throw StateError('No file dialog is pending');
    }
    if (paths.length > 1 && !kind.endsWith('s')) {
      throw ArgumentError('This dialog accepts only one path');
    }
    for (final path in paths) {
      if (path.isEmpty) {
        throw ArgumentError('Path must not be empty');
      }
      if (kind == 'save') {
        if (!File(path).parent.existsSync()) {
          throw ArgumentError(
            'Save destination directory does not exist: $path',
          );
        }
      } else if (kind.startsWith('director')) {
        if (!Directory(path).existsSync()) {
          throw ArgumentError('Directory does not exist: $path');
        }
      } else if (!File(path).existsSync()) {
        throw ArgumentError('File does not exist: $path');
      }
    }
    _completion = null;
    _kind = null;
    _types = null;
    _suggestedName = null;
    completion.complete(paths);
  }

  Future<List<String>>? _intercept(
    String kind, {
    List<XTypeGroup>? types,
    String? suggestedName,
  }) {
    if (!_armed) {
      return null;
    }
    _armed = false;
    _kind = kind;
    _types = types;
    _suggestedName = suggestedName;
    _completion = Completer<List<String>>();
    return _completion!.future;
  }

  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    final result = _intercept('file', types: acceptedTypeGroups);
    if (result == null) {
      return _delegate.openFile(
        acceptedTypeGroups: acceptedTypeGroups,
        initialDirectory: initialDirectory,
        confirmButtonText: confirmButtonText,
      );
    }
    final paths = await result;
    return paths.isEmpty ? null : XFile(paths.single);
  }

  @override
  Future<List<XFile>> openFiles({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    final result = _intercept('files', types: acceptedTypeGroups);
    if (result == null) {
      return _delegate.openFiles(
        acceptedTypeGroups: acceptedTypeGroups,
        initialDirectory: initialDirectory,
        confirmButtonText: confirmButtonText,
      );
    }
    return (await result).map(XFile.new).toList();
  }

  @override
  Future<FileSaveLocation?> getSaveLocation({
    List<XTypeGroup>? acceptedTypeGroups,
    SaveDialogOptions options = const SaveDialogOptions(),
  }) async {
    final result = _intercept(
      'save',
      types: acceptedTypeGroups,
      suggestedName: options.suggestedName,
    );
    if (result == null) {
      return _delegate.getSaveLocation(
        acceptedTypeGroups: acceptedTypeGroups,
        options: options,
      );
    }
    final paths = await result;
    return paths.isEmpty ? null : FileSaveLocation(paths.single);
  }

  @override
  Future<String?> getSavePath({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? suggestedName,
    String? confirmButtonText,
  }) async {
    final location = await getSaveLocation(
      acceptedTypeGroups: acceptedTypeGroups,
      options: SaveDialogOptions(
        initialDirectory: initialDirectory,
        suggestedName: suggestedName,
        confirmButtonText: confirmButtonText,
      ),
    );
    return location?.path;
  }

  @override
  Future<String?> getDirectoryPathWithOptions(FileDialogOptions options) async {
    final result = _intercept('directory');
    if (result == null) {
      return _delegate.getDirectoryPathWithOptions(options);
    }
    final paths = await result;
    return paths.isEmpty ? null : paths.single;
  }

  @override
  Future<String?> getDirectoryPath({
    String? initialDirectory,
    String? confirmButtonText,
  }) => getDirectoryPathWithOptions(
    FileDialogOptions(
      initialDirectory: initialDirectory,
      confirmButtonText: confirmButtonText,
    ),
  );

  @override
  Future<List<String>> getDirectoryPathsWithOptions(
    FileDialogOptions options,
  ) async {
    final result = _intercept('directories');
    if (result == null) {
      return _delegate.getDirectoryPathsWithOptions(options);
    }
    return result;
  }

  @override
  Future<List<String>> getDirectoryPaths({
    String? initialDirectory,
    String? confirmButtonText,
  }) => getDirectoryPathsWithOptions(
    FileDialogOptions(
      initialDirectory: initialDirectory,
      confirmButtonText: confirmButtonText,
    ),
  );
}
