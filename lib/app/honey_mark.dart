import 'package:flutter/material.dart';

/// The application mark, rasterized from the shared vector launcher artwork.
class HoneyMark extends StatelessWidget {
  final double size;
  final Color? color;

  const HoneyMark({super.key, this.size = 24, this.color});

  @override
  Widget build(BuildContext context) => ImageIcon(
    const AssetImage('assets/images/honey-mark.png'),
    size: size,
    color: color,
  );
}
