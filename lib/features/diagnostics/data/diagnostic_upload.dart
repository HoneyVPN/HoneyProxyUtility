import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'diagnostic_report.dart';

enum DiagnosticUploadFailure { unavailable, timeout, rejected, busy }

class DiagnosticUploadException implements Exception {
  const DiagnosticUploadException(this.failure);
  final DiagnosticUploadFailure failure;
}

class DiagnosticUploader {
  DiagnosticUploader({
    Dio? dio,
    this.demo = false,
    this.totalTimeout = const Duration(seconds: 25),
  }) : _dio =
           dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 10)));
  static final endpoint = Uri.parse(
    'https://api.honeyvpn.ru/app/api/diagnostics',
  );
  final Dio _dio;
  final bool demo;
  final Duration totalTimeout;
  CancelToken? _active;
  bool _busy = false;
  Future<String> send(DiagnosticReport report) async {
    if (_busy)
      throw const DiagnosticUploadException(DiagnosticUploadFailure.busy);
    // The mock and web preview must never reach a support server.
    if (demo) return 'DEMO-LOCAL';
    if (kIsWeb)
      throw const DiagnosticUploadException(
        DiagnosticUploadFailure.unavailable,
      );
    _busy = true;
    // Dio also cancels the adapter stream internally without awaiting/catching
    // its cancellation. Keep that boundary safe before Dio wraps the stream.
    if (_dio.httpClientAdapter is! _CancellationSafeAdapter) {
      _dio.httpClientAdapter = _CancellationSafeAdapter(_dio.httpClientAdapter);
    }
    final token = CancelToken();
    _active = token;
    StreamSubscription<Uint8List>? subscription;
    Completer<Uint8List>? completion;
    final deadline = Timer(totalTimeout, () {
      token.cancel('deadline');
      _cancelQuietly(subscription);
      if (completion != null && !completion.isCompleted) {
        completion.completeError(
          const DiagnosticUploadException(DiagnosticUploadFailure.timeout),
        );
      }
    });
    try {
      final response = await _dio.post<ResponseBody>(
        endpoint.toString(),
        data: utf8.decode(report.bytes),
        cancelToken: token,
        options: Options(
          contentType: Headers.jsonContentType,
          responseType: ResponseType.stream,
          followRedirects: false,
          maxRedirects: 0,
          sendTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 15),
          headers: {'Accept': 'application/json'},
          validateStatus: (_) => true,
        ),
      );
      final body = response.data;
      if (response.statusCode != 201 || body == null) {
        token.cancel('rejected');
        throw const DiagnosticUploadException(DiagnosticUploadFailure.rejected);
      }
      final bytes = BytesBuilder(copy: false);
      final result = Completer<Uint8List>();
      completion = result;
      subscription = body.stream.listen(
        (chunk) {
          if (result.isCompleted) return;
          if (bytes.length + chunk.length > 1024) {
            token.cancel('response limit');
            _cancelQuietly(subscription);
            result.completeError(
              const DiagnosticUploadException(DiagnosticUploadFailure.rejected),
            );
          } else {
            bytes.add(chunk);
          }
        },
        onError: (Object error) {
          if (!result.isCompleted) result.completeError(error);
        },
        onDone: () {
          if (!result.isCompleted) result.complete(bytes.takeBytes());
        },
      );
      final data = jsonDecode(utf8.decode(await result.future));
      if (data is! Map ||
          data.length != 2 ||
          data['accepted'] != true ||
          data['reportId'] is! String ||
          data['reportId'] != report.data['requestId'] ||
          !RegExp(r'^[a-f0-9]{32}$').hasMatch(data['reportId'] as String)) {
        throw const DiagnosticUploadException(DiagnosticUploadFailure.rejected);
      }
      return data['reportId'] as String;
    } on DiagnosticUploadException {
      rethrow;
    } on DioException catch (e) {
      throw DiagnosticUploadException(
        e.type == DioExceptionType.cancel ||
                e.type == DioExceptionType.connectionTimeout ||
                e.type == DioExceptionType.sendTimeout ||
                e.type == DioExceptionType.receiveTimeout
            ? DiagnosticUploadFailure.timeout
            : DiagnosticUploadFailure.unavailable,
      );
    } catch (_) {
      throw const DiagnosticUploadException(DiagnosticUploadFailure.rejected);
    } finally {
      deadline.cancel();
      try {
        await subscription?.cancel().timeout(const Duration(seconds: 2));
      } catch (_) {
        /* A broken response cannot retain the button's busy lock. */
      }
      _active = null;
      _busy = false;
    }
  }

  static void _cancelQuietly(StreamSubscription<Uint8List>? subscription) {
    if (subscription == null) return;
    try {
      unawaited(subscription.cancel().catchError((Object _) {}));
    } catch (_) {
      /* A faulty stream cannot introduce a second unhandled error. */
    }
  }

  void dispose() {
    _active?.cancel('disposed');
    _dio.close(force: true);
  }
}

class _CancellationSafeAdapter implements HttpClientAdapter {
  _CancellationSafeAdapter(this.delegate);
  final HttpClientAdapter delegate;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = await delegate.fetch(options, requestStream, cancelFuture);
    final source = body.stream;
    StreamSubscription<Uint8List>? upstream;
    late StreamController<Uint8List> guarded;
    guarded = StreamController<Uint8List>(
      onListen: () {
        upstream = source.listen(
          guarded.add,
          onError: guarded.addError,
          onDone: guarded.close,
        );
      },
      onPause: () => upstream?.pause(),
      onResume: () => upstream?.resume(),
      onCancel: () async {
        try {
          await upstream?.cancel().timeout(const Duration(seconds: 2));
        } catch (_) {
          /* A broken adapter cancellation must not escape Dio's callback. */
        }
      },
    );
    body.stream = guarded.stream;
    return body;
  }

  @override
  void close({bool force = false}) => delegate.close(force: force);
}

final diagnosticUploaderProvider = Provider((ref) {
  final uploader = DiagnosticUploader();
  ref.onDispose(uploader.dispose);
  return uploader;
});
