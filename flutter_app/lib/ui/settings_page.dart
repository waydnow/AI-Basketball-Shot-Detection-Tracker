import 'package:flutter/material.dart';

import '../data/settings.dart';

/// Every control writes through immediately: these are defaults for *new* markers and
/// thresholds for the detector, never a rewrite of markers the user already tuned.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.settings, required this.analysisLabel});

  final AppSettings settings;
  final String analysisLabel;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  void _set(void Function() change) {
    change();
    widget.settings.save();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          const _Section('截取窗口', '每个标记默认截取的前后时长'),
          _SliderTile(
            label: '进球前',
            value: s.windowBeforeS,
            max: 10,
            divisions: 20,
            format: (v) => '${v.toStringAsFixed(1)}s',
            onChanged: (v) => _set(() => s.windowBeforeS = v),
          ),
          _SliderTile(
            label: '进球后',
            value: s.windowAfterS,
            max: 10,
            divisions: 20,
            format: (v) => '${v.toStringAsFixed(1)}s',
            onChanged: (v) => _set(() => s.windowAfterS = v),
          ),
          const _Section('识别灵敏度', '阈值越高越严：漏检多就调宽松，误判多就调严格'),
          _ChoiceTile<DetectionSensitivity>(
            label: '检测灵敏度',
            detail: '篮球 ${s.ballConf.toStringAsFixed(2)} · 筐区篮球 ${s.ballConfNearHoop.toStringAsFixed(2)}'
                ' · 篮筐 ${s.hoopConf.toStringAsFixed(2)}',
            value: s.sensitivity,
            values: {for (final e in DetectionSensitivity.values) e: e.label},
            onChanged: (v) => _set(() => s.sensitivity = v),
          ),
          const _Section('导出'),
          SwitchListTile(
            title: const Text('包含未命中的出手'),
            subtitle: const Text('关掉后只拼接进球的片段'),
            value: s.includeMisses,
            onChanged: (v) => _set(() => s.includeMisses = v),
          ),
          _ChoiceTile<int>(
            label: '输出高度',
            value: s.outputHeight,
            values: const {0: '保持源', 480: '480p', 720: '720p', 1080: '1080p'},
            onChanged: (v) => _set(() => s.outputHeight = v),
          ),
          _ChoiceTile<double>(
            label: '输出帧率',
            value: s.outputFps,
            values: {0: '保持源', 25: '25', 30: '30', 60: '60'},
            onChanged: (v) => _set(() => s.outputFps = v),
          ),
          const _Section('关于'),
          ListTile(
            title: const Text('检测来源'),
            subtitle: Text(widget.analysisLabel),
          ),
          const ListTile(
            title: Text('已知限制'),
            subtitle: Text('同一画面里只有一个篮筐时判定才可靠；多球、多筐或严重遮挡会误判，'
                '请在时间轴上手动修正。'),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, [this.subtitle]);

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Colors.lightBlue)),
          if (subtitle != null)
            Text(subtitle!, style: const TextStyle(fontSize: 11, color: Colors.white38)),
        ],
      ),
    );
  }
}

class _SliderTile extends StatelessWidget {
  const _SliderTile({
    required this.label,
    required this.value,
    required this.max,
    required this.divisions,
    required this.format,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double max;
  final int divisions;
  final String Function(double) format;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    // Slider asserts a divisions-aligned value, so keep the endpoint inside the range.
    final shown = value.clamp(0.01, max);
    return ListTile(
      title: Text(label),
      subtitle: Slider(
        value: shown,
        max: max,
        divisions: divisions,
        label: format(value),
        onChanged: (v) => onChanged(v),
      ),
      trailing: Text(format(value)),
    );
  }
}

class _ChoiceTile<T> extends StatelessWidget {
  const _ChoiceTile({
    required this.label,
    required this.value,
    required this.values,
    required this.onChanged,
    this.detail,
  });

  final String label;

  /// The numbers behind the chosen word, so a preset is never a black box.
  final String? detail;
  final T value;
  final Map<T, String> values;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(label),
      subtitle: detail == null ? null : Text(detail!, style: const TextStyle(fontSize: 11)),
      trailing: DropdownButton<T>(
        value: values.containsKey(value) ? value : values.keys.first,
        items: [for (final e in values.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
        onChanged: (v) => v == null ? null : onChanged(v),
      ),
    );
  }
}
