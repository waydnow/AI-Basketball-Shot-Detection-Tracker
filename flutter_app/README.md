# 篮球高光 App（Android / Flutter）

选几段投篮视频，把进球瞬间前后 N 秒截出来拼成一条高光。识别结果在原始视频的时间轴上以「针」的形式呈现，可拖动、可增删，识别错了当场改掉。

当前进度是计划的阶段 3 + 阶段 4 的推理链路：UI 与打点闭环已经能跑，剪辑流程读的是 `assets/fixtures/video_test_5_events.json`（Python 参考实现的黄金文件），端侧 ONNX Runtime 已经跑在「实时」页上（后置摄像头取景，边拍边计出手 / 命中，并把篮筐、篮球、轨迹画在预览上）；FFmpeg 裁剪拼接在阶段 5。

## 跑起来

```sh
export PATH="$HOME/development/flutter/bin:$HOME/opt/jdk17/lib/jvm/bin:$HOME/Library/Android/sdk/platform-tools:$PATH"
export JAVA_HOME="$HOME/opt/jdk17/lib/jvm"
export ANDROID_HOME="$HOME/Library/Android/sdk"
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn

adb push ../video_test_5.mp4 /sdcard/Download/
# Android 11+ 的 MediaProvider 会忽略 MEDIA_SCANNER_SCAN_FILE 广播，必须显式让它扫这个文件，
# 否则系统选择器里看不到（`content query` 能查到 _id 才算成功）。
adb shell content call --uri content://media/external/file --method scan_file \
  --arg /storage/emulated/0/Download/video_test_5.mp4
flutter run
```

进 App 后「选择视频」→ 选 `video_test_5.mp4` → 「识别」，时间轴上会出现 28 根针（25 进球 / 3 未中），与 `tools/dump_reference.py` 的输出一致。

## 实时模式

主界面右上角「实时」→ 横屏打开后置摄像头，画面里同时出现：

- 出手 / 命中计数，判定理由（`ShotTracker` 的 `explain` 输出，命中/未中都给一句为什么）。
- 右上角的检测吞吐与三段耗时：预处理（NV21→blob）/ 推理（ONNX）/ 解码（NMS + 反 letterbox）。**这三段就是「延迟大不大」的答案**：预览不卡但三段加起来上百毫秒，标注就会明显滞后于画面。
- 黄框 = 篮筐（顶边那条橙线是篮圈，判定就看它），蓝圈 = 篮球，蓝线 = 最近 1 s 的球心轨迹。
- 「标注」开关关掉叠加，只看计数；「旋转」默认按 `sensorOrientation` 推算（横屏锁定后只会是 0° 或 180°），真机上若发现框整体转了 90°，用旁边四个档位手动纠正。
- 灵敏度沿用设置页的宽松 / 标准 / 严格三档，改档会重新计数。

跑之前必须先有模型，`assets/model/best.onnx` 不入库：

```sh
source ../.venv/bin/activate
python ../tools/export_onnx.py            # best.pt -> best.onnx，并做 PyTorch/ONNX 一致性校验
cp ../best.onnx assets/model/best.onnx
```

模型缺失时实时页不会崩，会在顶部给出上面这条提示。

## 没有真机时：x86_64 模拟器

这台 Intel Mac 上模拟器是可用的——新版 emulator 走 macOS Hypervisor.framework，不需要 HAXM/AEHD 内核扩展，所以不需要管理员权限。用 `emulator -accel-check` 确认（返回 `0` 即加速可用）。

```sh
sdkmanager --install "emulator" "system-images;android-35;google_apis;x86_64"
echo no | avdmanager create avd -n flutter_emulator \
  -k "system-images;android-35;google_apis;x86_64" -d pixel_6
$ANDROID_HOME/emulator/emulator -avd flutter_emulator -gpu host -no-audio -no-boot-anim &
```

首次开机约 70 s。APK 里有 `lib/x86_64/`（Flutter 引擎 + FFmpeg 都在），所以端侧推理也能在上面调。

`onnxruntime` 这个 pub 包只带 arm 的 `.so`，x86_64 模拟器要自己补一份 Microsoft 官方 Android 包里的 `libonnxruntime.so`，放在 `android/app/src/main/jniLibs/x86_64/`（已 gitignore，真机用插件自带的那份）。模拟器上实测一帧约 预处理 350 ms + 推理 1.4 s + 解码 120 ms，也就是 0.5 fps 左右——x86_64 软件推理就这样，真机要快一个量级，所以延迟数字以右上角读数为准。

模拟器首次绑定摄像头会刷一堆 `CameraX ... No available camera can be found`，是 emulator 自己少报了一次相机列表，重试几十秒后会正常出画面。

注意 `flutter emulators` 报的 `avdmanager is missing from the Android SDK` 是兜底文案：它的判定条件是 `avdManagerPath != null && emulator 包存在`，缺的其实是 `emulator` 包或 system image，跟 `avdmanager` 无关。

## 时间轴操作

- 点针：选中并把视频 seek 到该时刻；点空白：只 seek。
- 左右拖针：改时间，针变琥珀色（手动），自动检测结果不再被覆盖。
- 选中后拖两侧把手：单独改这个点的前 / 后截取窗口。
- 长按空白：在该时刻加一根手动针。
- 把针拖出时间轴（上或下）：针变红，松手即删除，列表上方给撤销；拖回时间轴内再松手，针留在原位。
- 拖动的第一个方向决定这次拖拽是改时间还是删除：先左右就是改时间，先上下就是删除，中途不会换。
- 勾选框控制这根针是否参与导出。
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
- `test/timeline_test.dart`：时间轴换算、拖拽命中与「先上下还是先左右」的判定、截取清单，外加两张渲染基线 `test/goldens/timeline_strip.png`（常态）与 `timeline_strip_delete_armed.png`（针被拖出时间轴时的红色态）。
- `test/live_preprocess_test.dart`：`pyRound` 的银行家取整、四个旋转档位把画面转到哪一边、padding 是不是训练时那个 114 灰。
- `test/live_reference_test.dart`：由 `python tools/dump_live_reference.py --frames 6` 生成的三组对照——letterbox 几何逐个数、`output0` 张量解码 + NMS 与 ultralytics 完全一致、真 NV21 帧过一遍真模型（需要 host 上有 `libonnxruntime.*.dylib`，缺就 skip）。
- `test/live_detector_test.dart`：推理 isolate 的通道与「忙就丢、不排队」规则，同样对着 Python 的框。

## 目录

```
lib/domain/   models.dart（Video/Shot/截取清单）  shot_logic.dart（Python 判定逻辑的移植）
              letterbox.dart（NV21→blob，含 ultralytics 的取整规则）  yolo_post.dart（解码 + NMS）
lib/data/     database.dart（sqflite）  settings.dart  analysis.dart（检测后端抽象 + 示例实现）
              live_detector.dart（worker isolate：预处理 + 图 + 解码都在里面）
lib/ui/       home_page.dart  editor_page.dart  timeline.dart  settings_page.dart  live_page.dart
```

`videos.analyzed_at` 记录自动检测是否已经写过；写过之后，重新识别不会覆盖用户改过的针。
