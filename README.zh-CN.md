# MoleSignal Flutter RUM

MoleSignal 官方 Flutter Real User Monitoring SDK。它与
`@molesignal/browser-rum` 使用相同的会话、Action、错误、资源和 Session Replay
写入契约，并为 Flutter 提供对应的页面、交互挫败、渲染性能与屏幕回放能力。

[English](README.md)

## 能力对齐

Web 和 Flutter 的运行模型不同，但上报能力与控制台体验保持对齐：

| Web SDK | Flutter SDK |
| --- | --- |
| History 页面 View | `RumNavigationObserver` 或 `startView` |
| Click / Submit | `RumApp` 自动 Tap、`RumUserAction` 显式命名 |
| Rage / Dead Click | `rage_click` / `dead_click`，后者结合视觉指纹与 RUM 状态变化判断 |
| Runtime / Promise Error | `FlutterError`、`PlatformDispatcher.onError`、`addError` |
| fetch / XHR Resource | `MoleSignalHttpClient`，Dio 等通过 `addResource` 接入 |
| Long Task / Web Vitals | 慢帧与每个 View 的 Flutter time-to-first-render |
| rrweb DOM Replay | 隐私处理后的屏幕快照，编码成 rrweb FullSnapshot + Mutation，在同一播放器回放 |
| W3C Trace Context | 请求、响应或 `Server-Timing` 中的 `traceparent` |

LCP、CLS 等是浏览器专属语义，Flutter 不会伪造这些值；SDK 上报对应的首屏渲染、
build、raster、vsync 与慢帧数据。

## 环境要求

- Flutter 3.35 或更高版本
- Dart 3.9 或更高版本
- 使用默认持久化身份存储时，需要 Android 24+ 或 iOS 13+

## 安装与初始化

```yaml
dependencies:
  molesignal_flutter: ^0.3.0
```

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

`RumApp` 提供回放边界、自动 Tap 和挫败检测。回放采样率仍默认为 `0`，不会因为
加入根组件而自动录屏。使用 Router/go_router 时，将 `RumNavigationObserver` 传给
对应的 `navigatorObservers`，或者在路由状态变化时调用 `rum.startView`。

## Session Replay

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

回放有独立的 10 秒 flush 周期、每会话递增 `seq`、约 1 MiB 的目标分段和 8 MiB
请求上限。未发送分段会持久化并在进程重启后恢复；可重试失败会原样复用同一
`seq` 与 payload，服务端按 application、session ID、seq 幂等处理重复投递。

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

## 用户、上下文与错误

SDK 链式调用应用已有的 `FlutterError.onError` 与
`PlatformDispatcher.onError`，不会吞掉原有错误处理：

```dart
rum.setUser(const RumUser(
  id: 'user-42',
  attributes: <String, Object?>{'plan': 'enterprise'},
));
rum.setGlobalContextProperty('region', 'cn-east-1');

try {
  await submitOrder();
} catch (error, stackTrace) {
  rum.addError(
    error,
    stackTrace: stackTrace,
    context: const <String, Object?>{'component': 'CheckoutButton'},
  );
}

rum.addAction(
  'Checkout submitted',
  context: const <String, Object?>{'cart_size': 3},
);
```

额外 isolate 中的异常仍需转发到主 isolate，再调用 `addError`。

自动交互默认使用隐私安全的 `Tap` 名称。需要业务名称时，用 `RumUserAction` 显式标记：

```dart
RumUserAction(
  client: rum,
  name: 'Pay now',
  child: ElevatedButton(onPressed: pay, child: const Text('Pay now')),
)
```

同一次手势里，显式 `RumUserAction` / `addInteraction` 优先于根节点自动 Tap；去重窗口
内相同的 View 通知也只产生一条。原生崩溃采集器可保留结构化 frame：

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

## HTTP 与 Trace 关联

```dart
final http.Client httpClient = MoleSignalHttpClient(
  rum,
  inner: http.Client(),
);

await httpClient.get(Uri.parse('https://api.example.com/orders'));
```

SDK 在响应 body 消费完成、失败或取消后才结束 monotonic duration，记录 method、
脱敏 URL、请求/实际响应字节数、状态码以及稳定的 DNS/TLS/timeout/cancel/connection/
HTTP 错误字段，并依次从响应
`traceparent`、`Server-Timing` 中的 `traceparent`、请求 `traceparent` 提取
`trace_id` / `parent_span_id`。SDK 不会全局劫持网络；Dio 等客户端可在
interceptor 中调用 `rum.addResource`。

## 上传契约

所有请求使用 `Authorization: Bearer <clientToken>`：

- `POST /api/v1/rum/sessions`
- `POST /api/v1/rum/actions`
- `POST /api/v1/rum/errors`
- `POST /api/v1/rum/replay`

前三类 body 是 JSON 数组；replay body 为
`{"application":"...","session_id":"...","seq":1,"events":[...]}`。所有事件都携带
与调试产物上传完全一致的 `application`、`service`、`version`、`platform`、
`architecture`、`debug_id`。请求还带 `x-molesignal-application-id`，服务端会拒绝
绑定到其他 application 的公开 Token。

## 配置

| 选项 | 默认值 | 用途 |
| --- | --- | --- |
| `applicationId`, `clientToken`, `site` | 必填 | 应用标识、应用绑定的 RUM Token 与写入地址 |
| `service` | `applicationId` | Action/Error 的服务名 |
| `env` | 未设置 | 部署维度 |
| `version` | `unknown` | 调试产物 release；生产必须显式传入 |
| `platform`, `architecture`, `debugId` | 自动检测/稳定回退 | 调试产物构建标识 |
| `user`, `globalContext` | 未设置 | 初始身份和自定义维度 |
| `sessionSampleRate` | `100` | 会话采样百分比 |
| `sessionReplaySampleRate` | `0` | 已采样会话中的回放百分比 |
| `sessionReplay` | 隐私安全默认值 | 截图周期、分辨率、Action 后采集与遮罩颜色 |
| `trackUserInteractions` | `false` | `RumApp` 自动 Tap |
| `trackFrustrations` | 跟随交互配置 | Rage / Dead Tap |
| `trackResources` | `true` | HTTP Resource |
| `trackLongTasks` | `true` | 超过阈值的 Flutter 慢帧 |
| `trackViewPerformance` | `true` | View 首次渲染耗时 |
| `longFrameThreshold` | `100 ms` | 慢帧阈值 |
| `trackFlutterErrors` / `trackPlatformErrors` | `true` | Framework / root-isolate 异常 |
| `trackAppLifecycle` | `true` | 前后台 Action 与后台 flush |
| `trackAnonymousUser` | `true` | 持久化匿名 ID |
| `trackUrlQueryString` | `false` | 是否保留 URL query |
| `defaultPrivacyLevel` | `mask` | 回放文字、交互标签与 raw stack 策略 |
| `flushInterval` / `batchSize` | `5 s` / `50` | 普通事件上传策略 |
| `replayFlushInterval` / `replayBatchSize` | `10 s` / `100` | 回放上传策略 |
| `maxQueueSize` / `maxQueueBytes` / `queueItemTtl` | `1000` / `32 MiB` / `24 h` | 持久化离线队列边界 |
| `requestTimeout` / `flushTimeout` | `15 s` / `20 s` | 有界请求与生命周期 flush |
| `beforeSend` | 未设置 | 修改或丢弃任意事件，包括 replay |
| `transport` | `package:http` | 自定义代理或测试 transport |
| `persistence` | shared preferences | 会话与身份存储 |

还可配置 `excludedUrls`、`allowedTracingUrls`、`maxQueueSize`、会话超时和
`onError`。旧的 `trackLongFrames` 仍可用，推荐改为 `trackLongTasks`。

`flush()` / `stop()` 返回 `RumFlushResult`，明确区分 accepted、retried、dropped、
remaining、timedOut 和各丢弃原因。Session ID、采样决策、View/Action/Error/Resource
计数、事件/Replay 序号、最后活动时间和待关闭状态都会跨重启保存；最终 Session
事件包含 duration、各类计数、crash、end reason 与 last page。

## 性能字段契约

`cold_start`、`warm_start`、`view_load`、`slow_frame`、`frozen_frame`、`jank`、
`anr` 和 `network` 的 duration/value 统一使用 monotonic clock 的整数微秒；memory
使用 byte，次数使用 count。事件时间单独使用 epoch microseconds，绝不拿 wall clock
相减计算 duration。原生插件可通过 `addPerformanceMetric` 补充 ANR、memory 与 warm
start；负数、非有限数、溢出值和非法时间戳会在序列化前拒绝。

## 安全

- 默认移除 URL query 与 fragment；
- 递归脱敏 `password`、`secret`、`token`、`authorization`、`cookie`、
  `api_key`、银行卡和 CVV 等字段；
- 默认不上传 raw stack，只上传结构化 Dart stack frame；
- 事件、诊断、Replay metadata 和离线队列不会保存 credential、Authorization、URL
  user info、敏感 query 值、请求/响应 body 或开发机绝对路径；
- `clientToken` 会随 App 下发，必须视为公开凭证。请使用数据源接入向导生成的
  应用绑定 `msrum_<16 位字母数字>_<32 位字母数字>` Client Token。本地保存非秘密
  application binding 以尽早发现误复用，服务端仍是最终隔离边界；
- Shared Preferences 不是加密保险箱。队列内容已经过隐私清洗；要求本地静态加密的
  应用应提供自己的加密 `RumPersistence`。

## 兼容性范围

协议覆盖 Android（`arm64`、`armv7`、`x86_64`）、iOS（`arm64`）和 Flutter Web
JavaScript；实际支持的 OS/ABI 组合应通过 production fixture 逐项验证。Web frame
使用 `javascript_sourcemap` + `platform=flutter`，不会冒充移动端 AOT。uni-app 不在
本 package 范围内。

## 开发验证

```bash
flutter pub get
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
```
