import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// Callback for download progress.
typedef DownloadProgressCallback =
    void Function(int receivedBytes, int totalBytes);

/// Downloads and manages LiteRT-LM model files from Hugging Face.
class ModelDownloader {
  ModelDownloader({
    required this.modelFileName,
    required this.modelUrl,
    required this.modelRepoApiUrl,
    this.minimumValidBytes = 2200000000,
  });

  /// Pre-configured downloader for Gemma 4 E2B.
  factory ModelDownloader.gemma4E2B() => ModelDownloader(
    modelFileName: 'gemma-4-E2B-it.litertlm',
    modelUrl:
        'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm',
    modelRepoApiUrl:
        'https://huggingface.co/api/models/litert-community/gemma-4-E2B-it-litert-lm',
  );

  final String modelFileName;
  final String modelUrl;
  final String modelRepoApiUrl;
  final int minimumValidBytes;

  /// Validates a Hugging Face token against the model repo.
  Future<void> validateToken(String token) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(modelRepoApiUrl));
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close();
      if (response.statusCode >= 400) {
        throw Exception('Token validation failed (${response.statusCode}).');
      }
      await response.drain<void>();
    } finally {
      client.close(force: true);
    }
  }

  /// Returns the model path if already downloaded, otherwise null.
  Future<String?> findInstalledModelPath() async {
    await _normalizeFiles();
    final file = await _modelFile();
    return file.existsSync() ? file.path : null;
  }

  /// Downloads the model with resume support. Returns the installed path.
  Future<String> download({
    required String token,
    required DownloadProgressCallback onProgress,
  }) async {
    await _normalizeFiles();

    final file = await _modelFile();
    final partialFile = await _partialFile();
    await file.parent.create(recursive: true);

    if (file.existsSync()) {
      final length = await file.length();
      if (length >= minimumValidBytes) return file.path;
      await file.rename(partialFile.path);
    }

    final existingBytes = partialFile.existsSync()
        ? await partialFile.length()
        : 0;
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(modelUrl));
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      if (existingBytes > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$existingBytes-');
      }

      final response = await request.close();
      if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.partialContent) {
        final body = await utf8.decodeStream(response);
        throw Exception(
          'Download failed (${response.statusCode})${body.isEmpty ? '' : ': $body'}',
        );
      }

      final isResumed =
          response.statusCode == HttpStatus.partialContent && existingBytes > 0;
      final totalBytes = _resolveTotalBytes(response, existingBytes);
      onProgress(existingBytes, totalBytes);

      final sink = partialFile.openWrite(
        mode: isResumed ? FileMode.append : FileMode.write,
      );
      var receivedBytes = existingBytes;
      var lastUpdate = DateTime.fromMillisecondsSinceEpoch(0);
      try {
        await for (final chunk in response) {
          sink.add(chunk);
          receivedBytes += chunk.length;
          final now = DateTime.now();
          if (now.difference(lastUpdate).inMilliseconds >= 150 ||
              receivedBytes == totalBytes) {
            onProgress(receivedBytes, totalBytes);
            lastUpdate = now;
          }
        }
      } finally {
        await sink.flush();
        await sink.close();
      }

      final downloadedBytes = await partialFile.length();
      if (downloadedBytes < minimumValidBytes) {
        throw Exception('Download incomplete. Tap download to resume.');
      }

      if (file.existsSync()) await file.delete();
      await partialFile.rename(file.path);
      return file.path;
    } finally {
      client.close(force: true);
    }
  }

  /// Deletes the model and any partial downloads.
  Future<void> delete() async {
    final file = await _modelFile();
    final partial = await _partialFile();
    if (file.existsSync()) await file.delete();
    if (partial.existsSync()) await partial.delete();
  }

  Future<File> _modelFile() async {
    final dir = await getApplicationSupportDirectory();
    return File(path.join(dir.path, modelFileName));
  }

  Future<File> _partialFile() async {
    final dir = await getApplicationSupportDirectory();
    return File(path.join(dir.path, '$modelFileName.part'));
  }

  Future<void> _normalizeFiles() async {
    final file = await _modelFile();
    final partial = await _partialFile();
    if (file.existsSync() && await file.length() < minimumValidBytes) {
      if (partial.existsSync()) {
        if (await partial.length() < await file.length()) {
          await partial.delete();
          await file.rename(partial.path);
        } else {
          await file.delete();
        }
      } else {
        await file.rename(partial.path);
      }
    }
  }

  int _resolveTotalBytes(HttpClientResponse response, int existingBytes) {
    final contentRange = response.headers.value(HttpHeaders.contentRangeHeader);
    if (contentRange != null) {
      final slashIndex = contentRange.lastIndexOf('/');
      if (slashIndex != -1) {
        return int.tryParse(contentRange.substring(slashIndex + 1)) ?? 0;
      }
    }
    final contentLength = response.contentLength;
    if (contentLength <= 0) return 0;
    return response.statusCode == HttpStatus.partialContent
        ? existingBytes + contentLength
        : contentLength;
  }
}
