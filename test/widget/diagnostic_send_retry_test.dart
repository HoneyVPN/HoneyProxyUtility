import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:honeyproxyutility/features/connection/domain/entities/connection_state.dart';
import 'package:honeyproxyutility/features/connection/presentation/notifiers/connection_notifier.dart';
import 'package:honeyproxyutility/features/connection/presentation/screens/home_screen.dart';
import 'package:honeyproxyutility/features/diagnostics/data/diagnostic_report.dart';
import 'package:honeyproxyutility/features/diagnostics/data/diagnostic_upload.dart';
import 'package:honeyproxyutility/features/diagnostics/presentation/diagnostic_send_sheet.dart';
import 'package:honeyproxyutility/features/servers/data/models/server_profile_model.dart';
import 'package:honeyproxyutility/features/settings/data/models/app_settings.dart';
import 'package:honeyproxyutility/features/subscriptions/data/services/subscriptions_notifier.dart';
import '../support/design_preview.dart';

void main() {
  testWidgets('lost receipt retries identical report ID and payload', (
    tester,
  ) async {
    final builder = _SyntheticBuilder();
    final uploader = _LostReceiptUploader();
    await _render(tester, builder, uploader);
    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Отправить в поддержку'));
    await tester.pumpAndSettle();
    final buildsAfterFailure = builder.builds;
    expect(uploader.reports, hasLength(1));
    await tester.tap(find.text('Отправить в поддержку'));
    await tester.pumpAndSettle();
    expect(uploader.reports, hasLength(2));
    expect(builder.builds, buildsAfterFailure);
    expect(uploader.reports.last.bytes, uploader.reports.first.bytes);
    expect(
      find.text(uploader.reports.first.data['requestId']! as String),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('edited note starts a new explicit report attempt', (
    tester,
  ) async {
    final builder = _SyntheticBuilder();
    final uploader = _LostReceiptUploader();
    await _render(tester, builder, uploader);
    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Отправить в поддержку'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Synthetic edited note');
    await tester.tap(find.text('Отправить в поддержку'));
    await tester.pumpAndSettle();
    expect(uploader.reports, hasLength(2));
    expect(
      uploader.reports.last.data['requestId'],
      isNot(uploader.reports.first.data['requestId']),
    );
    expect(uploader.reports.last.data['description'], 'Synthetic edited note');
    expect(tester.takeException(), isNull);
  });

  testWidgets('connection error opens review without uploading', (
    tester,
  ) async {
    await tester.pumpWidget(
      designPreviewScope(
        child: ProviderScope(
          overrides: [
            connectionNotifierProvider.overrideWith(_ErrorConnection.new),
          ],
          child: const MaterialApp(home: HomeScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Отправить диагностику'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Ничего не отправляется автоматически.'),
      findsOneWidget,
    );
    expect(find.text('Отправить в поддержку'), findsOneWidget);
    expect(find.text('DEMO-LOCAL'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _render(
  WidgetTester tester,
  _SyntheticBuilder builder,
  _LostReceiptUploader uploader,
) async {
  await tester.pumpWidget(
    designPreviewScope(
      child: ProviderScope(
        overrides: [
          diagnosticReportBuilderProvider.overrideWithValue(builder),
          diagnosticUploaderProvider.overrideWithValue(uploader),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDiagnosticSendSheet(context),
                child: const Text('Review'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  addTearDown(uploader.dispose);
}

class _SyntheticBuilder extends DiagnosticReportBuilder {
  int builds = 0;
  @override
  Future<DiagnosticReport> build({
    required AppSettings settings,
    required NexConnectionState connection,
    required SubscriptionsState subscriptions,
    required List<ServerProfileModel> profiles,
    String description = '',
    PackageInfo? package,
    DateTime? now,
    String? platform,
    bool profilesLoaded = true,
    bool subscriptionsLoaded = true,
  }) async => DiagnosticReport({
    'requestId': (++builds).toRadixString(16).padLeft(32, '0'),
    'description': description,
    'events': <Object>[],
  });
}

class _LostReceiptUploader extends DiagnosticUploader {
  final reports = <DiagnosticReport>[];
  @override
  Future<String> send(DiagnosticReport report) async {
    reports.add(report);
    if (reports.length == 1) {
      throw const DiagnosticUploadException(DiagnosticUploadFailure.timeout);
    }
    return report.data['requestId']! as String;
  }
}

class _ErrorConnection extends ConnectionNotifier {
  @override
  NexConnectionState build() => const NexConnectionState(
    status: ConnectionStatus.error,
    errorMessage: 'Synthetic connection error',
  );
}
