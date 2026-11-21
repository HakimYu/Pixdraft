import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class ErrorDetails extends StatelessWidget {
  const ErrorDetails({super.key, required this.message});
  final String message;

  Future<void> _copy(BuildContext context) async {
    // 先取 messenger，避免 await 之后再用可能失效的 context。
    final messenger = ScaffoldMessenger.of(context);
    try {
      await Clipboard.setData(ClipboardData(text: message));
    } catch (_) {
      if (messenger.mounted) messenger.showSnackBar(const SnackBar(content: Text('复制报错失败')));
      return;
    }
    if (messenger.mounted) messenger.showSnackBar(const SnackBar(content: Text('完整报错已复制')));
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(message.split('\n').first, style: TextStyle(color: Theme.of(context).colorScheme.error)),
    Wrap(spacing: 4, children: [
      TextButton.icon(icon: const Icon(Icons.info_outline), label: const Text('查看错误信息'), onPressed: () => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('错误详情'),
          content: SingleChildScrollView(child: SelectableText(message)),
          actions: [
            TextButton(onPressed: () => _copy(context), child: const Text('复制完整报错')),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭')),
          ],
        ),
      )),
      TextButton.icon(icon: const Icon(Icons.copy_all), label: const Text('复制报错'), onPressed: () => _copy(context)),
    ]),
  ]);
}
