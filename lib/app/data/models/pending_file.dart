class PendingFile {
  final bool isDirectory;
  final String filePath;
  final String? fileName;
  final int? size;
  final bool isUri;
  final List<String> directories;

  const PendingFile({
    required this.isDirectory,
    required this.filePath,
    required this.directories,
    this.isUri = false,
    this.fileName,
    this.size,
  });

  @override
  String toString() {
    return 'PendingFile{isDirectory: $isDirectory, filePath: $filePath, fileName: $fileName, size: $size, directories: $directories}, isUri $isUri';
  }

  Map<String, dynamic> toJson() {
    return {
      "isDirectory": isDirectory,
      "filePath": filePath,
      "fileName": fileName,
      "size": size,
      "isUri": isUri,
      "directories": directories,
    };
  }

  factory PendingFile.fromJson(Map<String, dynamic> map) {
    return PendingFile(
      isDirectory: map["isDirectory"] as bool,
      filePath: map["filePath"] as String,
      directories: (map["directories"] as List?)?.cast<String>() ?? const [],
      isUri: map["isUri"] as bool? ?? false,
      fileName: map["fileName"] as String?,
      size: map["size"] as int?,
    );
  }
}
