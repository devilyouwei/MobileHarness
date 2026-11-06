# App 内灵动岛全局显示验证

日期：2026-11-06。需求：[全局灵动岛](../completed/Global-In-App-Island.md)。用户确认保持现有顶部位置。

## 变更

UIContainer 的首页可见性通知只影响首页 WindowHost；删除 IslandState 的导航可见性开关、暂存展开偏好以及 IslandHost 的对应判断。根拥有的单一 scene 覆盖窗口持续显示在设置、记录、相册及详情页之上，原有状态、频谱、手势、命中和状态栏接管沿用同一实例。导航不改活动代际或本地呈现 revision。后台与根失活仍独立停止本地显示；旧活动/旧根偏好不能被回退导航复活。

## 自动验证

- 定向 `swift test --filter 'navigation|globalIsland|island'` 通过（exit 0）：UI 49 项、集成 6 项。日志 `/tmp/mh-global-island-tests.log`。
- 导航回归覆盖初始展开/收起两种状态、设置→记录→相册→返回、页面内用户修改偏好、实时录音/播放内容与频带更新、状态栏与几何保留、后台禁止迟到挂载/完成、前台当前页面恢复、活动结束和根失活。
- 首次 `scripts/check.sh` exit 1：集成阶段 `residentNativeStatePreservesFailuresAndRecoversOnObservation` 抛出 invalidSnapshot，该测试等待通知更新的上限为 3 秒；其余目标、边界/格式、Python 与 plist 检查通过，独立原生运行时阶段 227 项通过（206.110 秒）。日志 `/tmp/mh-global-island-check.log`。本次未修改该测试或平台状态实现，不能将整次检查记为通过。
- 完整运行结束后，上述失败测试独立复跑通过（0.009 秒、exit 0），日志 `/tmp/mh-global-island-native-state-recheck.log`。出现失败的非原生阶段整体复跑通过（exit 0），含 1054 项集成测试，日志 `/tmp/mh-global-island-phase-recheck.log`；此前已通过的独立原生阶段不重复运行。该现象与并行负载下等待限时有关，但不以复跑结果抹去首次失败，也未放宽测试限时。
- `scripts/build-ios.sh` 通过（exit 0）：MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero 四个 scheme，含 Agent/Island 应用资源检查。日志 `/tmp/mh-global-island-ios.log`。

## 验收边界

尝试通过原生界面工具访问 Simulator，工具报告 Mac 锁定且不能自动解锁；用户明确暂不方便解锁。本轮未进行模拟器实际触摸/动画、页面控件避让、系统弹层或真机声音/录音验收，也未安装到真机。状态回归使用合成内容和频带，不能宣称采集或播放硬件已验收。

后续原生复验：保持录音或播放时进入设置和多层记录页，检查顶部状态持续更新；在有详情内容时展开/点击收起/上滑收起并返回，确认偏好保留、岛外页面触摸可达；后台返回原页面仍可交互，根停止后无旧状态复活。
