import 'package:flutter/material.dart';
import '../../../../app/app_theme.dart';

class ProtocolChip extends StatelessWidget {
  final String protocol;
  const ProtocolChip({super.key, required this.protocol});

  @override
  Widget build(BuildContext context) {
    final color = switch (protocol.toLowerCase()) {
      'vmess' => NexColors.vmess,
      'vless' => NexColors.vless,
      'trojan' => NexColors.trojan,
      'ss' || 'shadowsocks' => NexColors.shadowsocks,
      'hy2' || 'hysteria2' => NexColors.hysteria2,
      'tuic' => NexColors.tuic,
      'wg' || 'wireguard' => NexColors.wireguard,
      'naive' => NexColors.naive,
      _ => Colors.grey,
    };

    final label = switch (protocol.toLowerCase()) {
      'ss' => 'SS',
      'hy2' => 'HY2',
      'wg' => 'WG',
      _ => protocol.toUpperCase(),
    };

    return Container(
      width: 54,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: color,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}
