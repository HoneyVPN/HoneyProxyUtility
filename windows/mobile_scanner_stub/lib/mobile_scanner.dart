library mobile_scanner;

import "package:flutter/widgets.dart";

export "mobile_scanner.dart";

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
  const MobileScanner({super.key, required this.controller, this.onDetect});

  @override
  Widget build(BuildContext context) => const SizedBox();
}
