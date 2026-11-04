# MoleSignal Flutter RUM

MoleSignal 官方 Flutter Real User Monitoring SDK。它把 MoleSignal RUM 事件契约
（`view`、`action`、`error`、`resource`、`long_task`、`vital` 六类事件）发送到
`POST /api/v1/rum/events`，与 `@molesignal/browser-rum` 使用同一份契约，并为
Flutter 提供对应的页面、点击、挫败信号、渲染性能、移动端 Vitals 与屏幕回放能力。

[English](README.md)

## 能力对齐

Web 和 Flutter 的运行模型不同，但上报能力与控制台体验保持对齐：

| Web SDK | Flutter SDK |
| --- | --- |
| History 页面 View（`view`） | `RumNavigationObserver` 或 `startView`；View 随变化多次上报 |
| Click（`action`） | `RumApp` 自动 Tap、`RumUserAction` 显式命名、`addAction` |
| Rage / Error Click | Tap Action 上的 `rage_tap` / `error_tap` 挫败信号 |
| Runtime Error（`error`） | `FlutterError`、`PlatformDispatcher.onError`（记为崩溃）、`addError`、失败的请求 |
| fetch / XHR（`resource`） | `MoleSignalHttpClient`、`startResource`/`stopResource`、`addResource` |
| Long Task（`long_task`） | 慢帧；冻结帧带 `is_frozen_frame` |
| Web Vitals（`vital`） | 冷启动 `app_launch`（`ttid`）、首次构建完成、View 上的帧与内存指标；自定义时长用 `startDurationVital` |
| rrweb DOM Replay | 隐私处理后的屏幕快照，编码成 rrweb FullSnapshot + Mutation，在同一播放器回放 |
| W3C Trace Context | 请求、响应或 `Server-Timing` 中的 `traceparent`，落到 `resource.trace_id` / `span_id` |

LCP、CLS 等是浏览器专属语义，Flutter 不会伪造这些值；SDK 上报对应的 build、
raster、刷新率、慢帧/冻结帧与内存数据。

## 环境要求与安装

- Flutter 3.35 或更高版本
- Dart 3.9 或更高版本
- 使用默认持久化身份存储时，需要 Android 24+ 或 iOS 13+

```yaml
dependencies:
  molesignal_flutter: ^0.4.0
```

设备品牌、型号、系统版本、电量与网络状态通过 `device_info_plus`、`battery_plus`、
`connectivity_plus` 读取（本包已依赖它们）。设置 `trackDeviceInfo: false` 后只发送
Flutter 自身可得的信息（系统名、语言、时区偏移、屏幕尺寸、架构）。

## 初始化

在 `runApp` 前初始化，用 `RumApp` 包住应用，再添加导航观察器：

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final rum = await initRum(
    const RumConfiguration(
      applicationId: 'checkout-mobile',
      clientToken: String.fromEnvironment('MOLESIGNAL_RUM_TOKEN'),
      site: 'https://molesignal.example.com',
      service: 'checkout-app',
      env: 'production',
      version: String.fromEnvironment('MOLESIGNAL_VERSION'),
      buildVersion: String.fromEnvironment('MOLESIGNAL_BUILD_VERSION'),
      architecture: String.fromEnvironment('MOLESIGNAL_ARCHITECTURE'),
      debugId: String.fromEnvironment('MOLESIGNAL_DEBUG_ID'),
      sessionSampleRate: 100,
      sessionReplaySampleRate: 20,
      trackUserInteractions: true,
    ),
  );

  runApp(
    RumApp(
      client: rum,
      child: MaterialApp(
        navigatorObservers: <NavigatorObserver>[
          RumNavigationObserver(rum),
        ],
        routes: <String, WidgetBuilder>{
          '/': (_) => const HomePage(),
          '/checkout': (_) => const CheckoutPage(),
        },
      ),
    ),
  );
}
```

请尽早调用 `initRum`：冷启动耗时从这里算到第一帧上屏。回放采样率默认为 `0`，不会因为
加入根组件而自动录屏。使用 Router/go_router 时，将 `RumNavigationObserver` 传给对应的
`navigatorObservers`，或者在路由状态变化时调用 `rum.startView`。

`applicationId` 必须是 `clientToken`（`mspat-…`）所绑定的应用；它作为
`application.id` 发送，接入端会拒绝指向其他应用的事件。

## 会话

会话由保存在 shared preferences 里的 UUID 标识，15 分钟无活动或满 4 小时即结束，采样只在
会话开始时决定一次（`sessionSampleRate`）。SDK **不再发送会话事件**：MoleSignal 从事件本身
派生会话。每个事件都带有 `session.id`、`session.type` 与 `session.start`（会话开始时间，epoch
毫秒，接收方用它区分“刚开始的新会话”和“丢了状态的老会话”）；`view` 事件还带有
`session.has_replay`（该会话记录过回放分段后为 true）。随 SDK 一起开始的新会话从 `initRum`
被调用的时刻算起，已保存的会话跨启动保留原来的开始时间。View 不会跨会话：展示某个 View 时
会话被续期，该 View 结束，同一页面以 `loading_type: session_renewal` 在新会话里继续。

## View

```dart
rum.startView('/checkout', name: 'Checkout');
rum.addTiming('cart_ready');          // view.custom_timings
rum.stopView('/checkout');
```

`view.url` 是路由路径（默认去掉 query 与 fragment，除非 `trackUrlQueryString`），
`view.name` 是名称。开始新 View 会结束上一个。View 内容变化时会再次上报：`view.revision`
加一并带上累计计数，最多每个 `flushInterval` 一次，开始、结束或 flush 时立即上报；`date` 始终是
View 开始的时间。应用进入后台时 View 结束，回到前台后以
`view_controller_redisplay` 重新展示。

View 携带 `time_spent`、`is_active`、`loading_type`、各类计数（`action`、`error`、`crash`、
`resource`、`long_task`、`frozen_frame`、`frustration`）、`custom_timings`，以及
[性能字段](#性能字段) 中的 Flutter 指标。第一次 `startView` 之前发生的事件归入
`ApplicationLaunch` View。

## Action、Error、Resource 与 Vital

```dart
rum.setUser(const RumUser(id: 'user-42', attributes: {'plan': 'enterprise'}));
rum.setAccount(const RumAccount(id: 'acme', name: 'Acme'));
rum.setGlobalContextProperty('region', 'cn-east-1');
rum.addFeatureFlagEvaluation('new_checkout', true);

rum.addAction('Checkout submitted', context: {'cart_size': 3});

try {
  await submitOrder();
} catch (error, stackTrace) {
  rum.addError(error, stackTrace: stackTrace, context: {'step': 'payment'});
}

rum.startDurationVital('checkout_form_ready');
// ...
rum.stopDurationVital('checkout_form_ready');
rum.addDurationVital('cart_sync', const Duration(milliseconds: 640));

final http.Client httpClient = MoleSignalHttpClient(rum, inner: http.Client());
await httpClient.get(Uri.parse('https://api.example.com/orders'));
```

**Action** 有 `tap`、`custom`、`back` 与自动产生的 `application_start`。自动 Tap 使用通用名称
`Tap`（`name_source: mask_placeholder`），不读取屏幕内容；需要业务名称时用 `RumUserAction`。
系统返回键与 iOS 侧滑返回都是 `back` Action。Tap 在它发起的请求进行期间（最长 5 秒）以及最后一次
引发事件后的 100 毫秒内保持打开；这段时间里的错误、崩溃与资源带上它的 `action.id`，Action 上报它们的
计数。1 秒内、50 逻辑像素范围内的三次点击使最后一次成为 `rage_tap`；引发错误的点击是 `error_tap`。
同一次手势里，显式 `RumUserAction` 优先于根节点自动 Tap（`actionDeduplicationWindow` 内）。

**Error** 携带 `source`、`type`、`message`、`stack`、结构化 `frames` 与 `handling`。框架错误是
`source: source`、`handling: unhandled`；`PlatformDispatcher.onError` 的错误还带
`is_crash: true`。`addError` 上报 `handling: handled`，`source` 由你指定（默认 `custom`）。
没有拿到响应的请求会产生 `network` 错误及 `error.resource`（`method`、`status_code: 0`、`url`）；
HTTP 错误状态码只是 Resource。所有错误的 `source_type` 都是 `flutter`。额外 isolate 中的异常仍需转发到
主 isolate 再调用 `addError`。SDK 不设置 `error.fingerprint`，需要改变分组时传入 `fingerprint:`。

**Resource** 的 `type` 是 `native`，带 `method`、`status_code`、`duration`、`size`（响应字节数）与
`trace_id` / `span_id`。`MoleSignalHttpClient` 在响应 body 消费完成、失败或取消后才结束计时。Dio 等客户端
可在 interceptor 中调用 `startResource` / `stopResource`，或对已完成的请求调用 `addResource`。

**Vital**：`initRum` 之后的第一帧是冷启动，上报一个 `application_start` Action 和一个 `app_launch` Vital
（`app_launch_metric: ttid`、`startup_type: cold_start`）。`startDurationVital` / `stopDurationVital` 与
`addDurationVital` 上报 `duration` 类 Vital。

原生崩溃采集器可保留结构化 frame：

```dart
rum.addError(
  nativeError,
  frames: const <RumStackFrame>[
    RumStackFrame(
      artifactKind: RumArtifactKind.androidNativeSymbols,
      module: 'libpayments.so',
      relativeAddress: '0x1234',
      debugId: 'elf-build-id',
    ),
  ],
);
```

Flutter `--obfuscate --split-debug-info`、Android native symbols、Apple dSYM 与
Flutter Web sourcemap 的完整流程见 [Release symbols](doc/release-symbols.md)，真机
[production E2E fixture](doc/production-e2e.md) 也已包含在仓库中。

## Session Replay 与隐私

Flutter 没有 DOM。SDK 首次采集会生成可被现有 rrweb player 识别的
`Meta(type=4)` 和 `FullSnapshot(type=2)`；后续画面变化作为
`IncrementalSnapshot(type=3)` 图片属性 mutation 上报。重复画面不会上传。

```dart
const RumConfiguration(
  // ...
  sessionReplaySampleRate: 20,
  sessionReplay: RumSessionReplayConfiguration(
    captureInterval: Duration(seconds: 2),
    captureOnAction: true,
    pixelRatio: 0.75,
    maximumImageDimension: 1200,
  ),
)
```

也可只为当前已采样会话手动开关：

```dart
rum.startSessionReplayRecording();
rum.stopSessionReplayRecording();
```

回放发送到 `POST /api/v1/rum/replay`，有独立的 10 秒 flush 周期、每会话递增 `seq`、约 1 MiB 的目标
分段和 8 MiB 请求上限。未发送分段会持久化并在进程重启后恢复；可重试失败会原样复用同一 `seq` 与
payload，服务端按 application、session ID、seq 幂等处理重复投递。每个回放请求还带上配置的
`service`、`env`（已设置时）和 `version`，服务端靠它们判断应用是否保留这个会话。回放流里只有
rrweb 记录；描述会话的 RUM 事件走事件上传。

### 回放隐私

- `defaultPrivacyLevel: RumPrivacyLevel.mask` 默认遮住所有 `Text`、`RichText` 和
  `EditableText` 区域；输入框即使在 `allow` 模式下也始终遮罩。
- 用 `RumReplayMask` 或 `RumReplayBlock` 包住余额、验证码、地图、图片或任何敏感
  自绘区域：

```dart
RumReplayBlock(
  child: AccountBalanceCard(),
)
```

- 遮罩直接写入原始 RGBA 像素，之后才编码 PNG；未遮罩的原始截图不会进入事件队列。
- `CustomPainter` 中自行绘制的文字无法通过 Widget 类型自动识别，必须显式包裹。
- Platform View 能否出现在截图中取决于平台合成方式；敏感 Platform View 应始终
  显式包裹，且需要在真机验证呈现结果。

## 接入契约

事件批量成 JSON 数组，发送到 `POST {site}/api/v1/rum/events`，使用
`Authorization: Bearer <clientToken>`。`site` 可以已经包含 `/api`、`/api/v1` 或
`/api/v1/rum`，路径会被补全。超过 1 KiB 的批次在有 `dart:io` 的平台上用 gzip 压缩
（`Content-Encoding: gzip`，`compressRequests: false` 可关闭）。单次请求最多带 48 KiB 的事件（更大的单个事件会单独发送），远低于接入端
5000 条、5 MiB 的上限。

接入端应答 `{"accepted": n, "rejected": [{"index": i, "reason": "…"}]}`：

- **被拒绝**的事件只报告（`RumConfiguration.onError`，以及 `RumFlushResult.dropped` /
  `dropReasons['rejected']`），不会重试。
- 网络错误、超时、`408`、`429`、`5xx` 按指数退避加抖动重试，且不早于服务端给出的 `Retry-After`；
  事件保存在持久化离线队列里。
- 其他 `4xx` 直接丢弃该批（`non_retryable`）。

队列受条数、字节数、存活时间限制（`maxQueueSize`、`maxQueueBytes`、`queueItemTtl`）；同一 View
的新版本会替换队列中等待发送的旧版本。

所有时长以及相对于 View 开始的时间都是**整数纳秒**，`date` 是毫秒时间戳。每个事件都带有：

| 字段 | 取值 |
| --- | --- |
| `source` | `flutter` |
| `application.id` | `applicationId` |
| `service`、`env`、`version`、`build_version`、`build_id` | 配置；`build_id` 即 `debugId` |
| `session` | `id`、`type: user`、`start`（epoch 毫秒）；View 上还有 `has_replay` |
| `view` | `id`、`url`、`name`、`in_foreground`（`view` 事件里是 View 本身） |
| `action.id` | 由某个 Action 引发的事件上 |
| `usr` | `setUser` 加持久化的 `anonymous_id`，额外属性保留 |
| `account` | `setAccount` |
| `os` | `name`、`version`、`version_major`、`build` |
| `device` | `type`（`mobile`/`tablet`/`desktop`）、`brand`、`model`、`architecture`、`locale`、`time_zone`（`UTC+08:00`）、`battery_level`、`power_saving_mode`、`is_low_ram`、`total_ram`、`logical_cpu_count` |
| `connectivity` | `status` 与 `interfaces` |
| `display.viewport` | 逻辑像素 `width` / `height` |
| `sdk` | `name: molesignal_flutter`、`version`、`session_sample_rate`、`replay_sample_rate` |
| `context` | 全局上下文与事件自身属性合并 |
| `feature_flags` | `addFeatureFlagEvaluation` 记录的值 |

## 性能字段

| 字段 | 含义 |
| --- | --- |
| `view.performance.fbc.timestamp` | 首次构建完成：从 View 开始到为它构建的第一帧结束的纳秒数 |
| `view.flutter_build_time`、`flutter_raster_time` | 每帧 UI 线程构建 / raster 线程光栅化耗时的 `min`/`max`/`average`（纳秒） |
| `view.refresh_rate_average`、`refresh_rate_min` | 这些帧能够维持的帧率（fps），以屏幕刷新率为上限 |
| `view.slow_frames_rate` | 每秒 View 时间里花在慢帧（超出帧预算但未冻结）上的毫秒数 |
| `view.freeze_rate` | 每小时 View 时间里花在冻结帧上的秒数 |
| `view.memory_average`、`memory_max` | 进程常驻内存字节数（Flutter Web 无） |
| `long_task.duration`、`is_frozen_frame` | 不短于 `longFrameThreshold`（100 ms）的帧；从 `frozenFrameThreshold`（700 ms）起为冻结帧 |
| `vital app_launch` | 冷启动：从 `initRum` 到为应用 UI 构建的第一帧结束的纳秒数 |

启动与首次构建用框架的 post-frame 回调测量，所有平台行为一致。帧指标来自 Flutter 的 frame timing，引擎
按批上报（Flutter Web 上报得更晚，且只有单调时钟），所以 `long_task` 的时间总是被限定在它所发生的 View 之内。

## 主要配置

| 选项 | 默认值 | 用途 |
| --- | --- | --- |
| `applicationId`, `clientToken`, `site` | 必填 | 应用标识、应用绑定的 RUM Token 与接入地址 |
| `service` | `applicationId` | `service` |
| `env`, `user`, `globalContext` | 未设置 | 部署与身份维度 |
| `version`, `buildVersion` | `unknown`，未设置 | `version`（调试产物的 release）与 `build_version` |
| `platform`, `architecture`, `debugId` | 自动检测/稳定回退 | 栈解析、`device.architecture`、`build_id`、frame 的 `debug_id` |
| `sessionSampleRate` | `100` | 会话采样百分比 |
| `sessionReplaySampleRate` | `0` | 已采样会话中的回放百分比 |
| `sessionReplay` | 隐私安全默认值 | 截图周期、分辨率、Action 后采集与遮罩颜色 |
| `trackUserInteractions` | `false` | `RumApp` 自动 Tap 与 `back` Action |
| `trackFrustrations` | 跟随交互配置 | `rage_tap` / `error_tap` |
| `trackResources` | `true` | HTTP Resource |
| `trackLongTasks` | `true` | 慢帧、冻结帧作为 `long_task` 事件，以及 View 的 `long_task`/`frozen_frame` 计数 |
| `trackViewPerformance` | `true` | 启动、首次构建、帧与内存指标 |
| `trackDeviceInfo` | `true` | 通过插件读取品牌、型号、电量、网络 |
| `trackFlutterErrors` / `trackPlatformErrors` | `true` | Framework / root-isolate 异常 |
| `trackAppLifecycle` | `true` | 进入后台时结束 View；后台 flush |
| `trackAnonymousUser` | `true` | 持久化 `usr.anonymous_id` |
| `trackUrlQueryString` | `false` | 是否保留 URL query |
| `defaultPrivacyLevel` | `mask` | 回放文字与 raw stack 策略 |
| `sessionInactivityTimeout` / `maxSessionDuration` | `15 min` / `4 h` | 会话上限 |
| `flushInterval` / `batchSize` | `5 s` / `50` | 普通事件上传策略 |
| `replayFlushInterval` / `replayBatchSize` | `10 s` / `100` | 回放上传策略 |
| `maxQueueSize` / `maxQueueBytes` / `queueItemTtl` | `1000` / `32 MiB` / `24 h` | 持久化离线队列边界 |
| `retryInitialDelay` / `retryMaxDelay` | `1 s` / `1 min` | 退避 |
| `requestTimeout` / `flushTimeout` | `15 s` / `20 s` | 有界请求与生命周期 flush |
| `compressRequests` | `true` | gzip 压缩事件批次 |
| `beforeSend` | 未设置 | 修改或丢弃任意事件，包括 replay |

还可配置 URL 过滤（`excludedUrls`、`allowedTracingUrls`）、各类阈值、诊断回调 `onError`、自定义
`transport`、`persistence` 与 `deviceInfoProvider`。

`flush()` / `stop()` 返回 `RumFlushResult`，明确区分 accepted、retried、dropped、
remaining、timedOut 和各丢弃原因。`stop()` 会对当前 View 做最后一次上报。Session ID、采样决策、
最后活动时间和回放序号都会跨重启保存。

## 安全

- 默认移除 URL query 与 fragment；
- 递归脱敏 `password`、`secret`、`token`、`authorization`、`cookie`、
  `api_key`、银行卡和 CVV 等字段；
- 仅在 `RumPrivacyLevel.allow` 下上传原始栈文本；否则 `error.stack` 由已脱敏的结构化 frame 重建；
- 事件、诊断、Replay metadata 和离线队列不会保存 credential、Authorization、URL
  user info、敏感 query 值、请求/响应 body 或开发机绝对路径；
- `clientToken` 会随 App 下发，必须视为公开凭证。请使用数据源接入向导生成的
  应用绑定 Client Token。所有 MoleSignal Token 都是 `mspat-<36 位小写字母数字>`，SDK
  无法区分。本地保存非秘密 application binding 以尽早发现误复用，服务端仍是最终隔离边界；
- Shared Preferences 不是加密保险箱。队列内容已经过隐私清洗；要求本地静态加密的
  应用应提供自己的加密 `RumPersistence`。

## 兼容性范围

协议覆盖 Android（`arm64`、`armv7`、`x86_64`）、iOS（`arm64`）和 Flutter Web
JavaScript；实际支持的 OS/ABI 组合应通过 production fixture 逐项验证。Web frame
只带文件位置、没有原生 `artifact_kind`，不会冒充移动端 AOT。uni-app 不在本 package 范围内。

## 开发验证

```bash
flutter pub get
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
```

测试会用共享的事件契约（`v1.schema.json`）校验 SDK 发出的每一条事件。把 `MOLESIGNAL_CONTRACTS`
指向服务端仓库的 `contracts/rum/events` 目录；默认是 `../molesignal/contracts/rum/events`。
找不到时，契约相关测试会带着这条说明被跳过。

## 从 0.2 升级

`clientToken` 改为 `mspat-<36 位小写字母数字>` 格式。旧格式 `msrum_<16>_<32>` 的 Token 在客户端启动时就会被拒绝。
新格式需要能签发它的 MoleSignal 服务端，请在那里新建 Client Token。

## 从 0.1 升级

0.2.0 与 0.1 协议不兼容，全部破坏性变更见 [CHANGELOG](CHANGELOG.md)。
