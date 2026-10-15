library mobile_scanner;

import 'package:flutter/widgets.dart';

enum MobileScannerErrorCode {
  controllerAlreadyInitialized,
  controllerDisposed,
  controllerUninitialized,
  genericError,
  permissionDenied,
  unsupported,
  controllerInitializing,
  controllerNotAttached,
}

class MobileScannerException implements Exception {
  final MobileScannerErrorCode errorCode;
  const MobileScannerException({required this.errorCode});
}

class MobileScannerController {
  void dispose() {}
}

class Barcode {
  final String? rawValue;
  const Barcode({this.rawValue});
}

class BarcodeCapture {
  final List<Barcode> barcodes;
  const BarcodeCapture({this.barcodes = const []});
}

class MobileScanner extends StatelessWidget {
  final MobileScannerController controller;
  final void Function(BarcodeCapture)? onDetect;
  final Widget Function(BuildContext, MobileScannerException)? errorBuilder;
  const MobileScanner({
    super.key,
    required this.controller,
    this.onDetect,
    this.errorBuilder,
  });
  @override
  Widget build(BuildContext context) => const SizedBox();
}
