import 'dart:io';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../../app/l10n/strings.dart';

class QrScanDialog extends ConsumerStatefulWidget {
  const QrScanDialog({super.key});

  @override
  ConsumerState<QrScanDialog> createState() => _QrScanDialogState();
}

class _QrScanDialogState extends ConsumerState<QrScanDialog> {
  final MobileScannerController _ctrl = MobileScannerController();
  bool _scanned = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_scanned) return;
    final barcode = capture.barcodes.firstOrNull;
    final value = barcode?.rawValue;
    if (value != null && value.isNotEmpty) {
      _scanned = true;
      Navigator.of(context).pop(value);
    }
  }

  Widget _cameraError(MobileScannerException error, bool ru) {
    // Show a useful localized explanation rather than the plugin's English
    // diagnostic message or raw platform details.
    final message = switch (error.errorCode) {
      MobileScannerErrorCode.permissionDenied =>
        ru
            ? 'Доступ к камере не разрешён. Разрешите его в настройках устройства.'
            : 'Camera permission was denied. Allow access in your device settings.',
      MobileScannerErrorCode.unsupported =>
        ru
            ? 'На этом устройстве сканирование QR недоступно.'
            : 'QR scanning is unavailable on this device.',
      _ =>
        ru
            ? 'Не удалось открыть камеру. Вставьте ссылку вручную.'
            : 'Could not open the camera. Paste the link manually.',
    };
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: SizedBox(
          width: 160,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.no_photography_outlined,
                size: 24,
                color: Colors.white70,
              ),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.35,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return const SizedBox();
    }
    final strings = ref.watch(stringsProvider);
    final ru = strings.locale == 'ru';
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: Material(
        color: colors.surface,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Semantics(
                          header: true,
                          child: Text(
                            ru ? 'Сканировать QR' : 'Scan QR',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.2,
                            ),
                          ),
                        ),
                      ),
                      SizedBox.square(
                        dimension: 44,
                        child: IconButton(
                          tooltip: strings.closeButton,
                          onPressed: () => Navigator.of(context).pop(null),
                          style: IconButton.styleFrom(
                            minimumSize: const Size(44, 44),
                            maximumSize: const Size(44, 44),
                            padding: EdgeInsets.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          icon: Container(
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              color: colors.surfaceContainerHighest,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              CupertinoIcons.xmark,
                              size: 13,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  fit: FlexFit.loose,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: SizedBox(
                            height: 224,
                            width: double.infinity,
                            child: ColoredBox(
                              color: Colors.black,
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  MobileScanner(
                                    controller: _ctrl,
                                    onDetect: _onDetect,
                                    errorBuilder: (_, error) =>
                                        _cameraError(error, ru),
                                  ),
                                  Center(
                                    child: IgnorePointer(
                                      child: Container(
                                        width: 180,
                                        height: 180,
                                        decoration: BoxDecoration(
                                          border: Border.all(
                                            color: Colors.white.withValues(
                                              alpha: 0.75,
                                            ),
                                            width: 0.75,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 12, bottom: 16),
                          child: Text(
                            ru
                                ? 'Поместите QR-код в рамку'
                                : 'Place the QR code inside the frame',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontSize: 13,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
