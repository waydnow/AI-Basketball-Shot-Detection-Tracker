# 篮球高光 App（Android / Flutter）

选几段投篮视频，把进球瞬间前后 N 秒截出来拼成一条高光。识别结果在原始视频的时间轴上以「针」的形式呈现，可拖动、可增删，识别错了当场改掉。

当前进度是计划的阶段 3：UI 与打点闭环已经能跑，识别结果读的是 `assets/fixtures/video_test_5_events.json`（Python 参考实现的黄金文件），端侧 ONNX Runtime 推理在阶段 4 接进来，FFmpeg 裁剪拼接在阶段 5。

## 跑起来

```sh
export PATH="$HOME/development/flutter/bin:$HOME/opt/jdk17/lib/jvm/bin:$HOME/Library/Android/sdk/platform-tools:$PATH"
export JAVA_HOME="$HOME/opt/jdk17/lib/jvm"
export ANDROID_HOME="$HOME/Library/Android/sdk"
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn

adb push ../video_test_5.mp4 /sdcard/DCIM/
# 相册里看不到这个文件时，补一次媒体扫描
adb shell am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE \
  -d file:///sdcard/DCIM/video_test_5.mp4
flutter run
```

进 App 后「选择视频」→ 选 `video_test_5.mp4` → 「识别」，时间轴上会出现 28 根针（25 进球 / 3 未中），与 `tools/dump_reference.py` 的输出一致。

## 时间轴操作

- 点针：选中并把视频 seek 到该时刻；点空白：只 seek。
- 左右拖针：改时间，针变琥珀色（手动），自动检测结果不再被覆盖。
- 选中后拖两侧把手：单独改这个点的前 / 后截取窗口。
- 长按空白：在该时刻加一根手动针。
- 列表左滑删除，可撤销；勾选框控制这根针是否参与导出。
- 缩放按钮改的是可视窗口，不是视频。

## 网络替代源

这台机器直连 `services.gradle.org` 约 50 KB/s、`maven.google.com` 不通，所以仓库里写死了三处镜像，注释都标了原因，换机器时把镜像行注释掉即可：

| 用途 | 镜像 | 位置 |
|---|---|---|
| Gradle 发行包 | `mirrors.cloud.tencent.com/gradle` | `android/gradle/wrapper/gradle-wrapper.properties` |
| Maven 依赖 | `maven.aliyun.com/repository/{google,public}` | `android/settings.gradle.kts`、`android/build.gradle.kts` |
| pub 包与引擎产物 | `pub.flutter-io.cn` / `storage.flutter-io.cn` | 环境变量 |

## 测试

```sh
flutter test
```

- `test/parity_test.dart`：把黄金检测逐帧喂进 Dart 状态机，断言事件与 Python 完全一致。
- `test/fixture_sync_test.dart`：App 内置的示例事件必须与 `fixtures/` 的 Python 黄金文件逐字节相同，防止两边各说各话。
- `test/timeline_test.dart`：时间轴换算、拖拽命中判定、截取清单，外加一张 `test/goldens/timeline_strip.png` 渲染基线。

## 目录

```
lib/domain/   models.dart（Video/Shot/截取清单）  shot_logic.dart（Python 判定逻辑的移植）
lib/data/     database.dart（sqflite）  settings.dart  analysis.dart（检测后端抽象 + 示例实现）
lib/ui/       home_page.dart  editor_page.dart  timeline.dart  settings_page.dart
```

`videos.analyzed_at` 记录自动检测是否已经写过；写过之后，重新识别不会覆盖用户改过的针。
