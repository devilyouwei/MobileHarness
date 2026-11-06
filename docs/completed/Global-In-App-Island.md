# App 内灵动岛全局显示

## 需求与边界

2026-11-06：用户要求设置及其他页面也能持续查看录音、播放等实时状态，并展开/收起灵动岛；已明确保持现有顶部位置。

当前 IslandHost 已通过 scene 内独立透明 UIWindow 覆盖根页面，但 UIContainer 将首页导航可见性同步给 IslandState，进入其他页面便主动拆卸。本次解除该限制，所有页面共享根拥有的同一灵动岛，不复制业务状态，不新增目录或模块。

## 代码前实施计划

- `UI/UIContainer.swift`：首页导航可见性只控制首页窗口；不改变灵动岛状态、代际、完成回执或展开偏好。
- `UI/Components/Island/IslandState.swift`：删除导航专用可见性开关、暂存偏好及相关分支。原生本地显示仍受根 available、sceneActive 和实际内容控制。活动替换/结束、后台恢复、根失活的原有围栏保留。
- `UI/Components/Island/IslandHost.swift`：删除导航可见性判断，继续使用已存在的非 key、alert 层透明覆盖窗口。命中限于实际岛身，外侧触摸透传；不改变顶部位置、手势、排序或业务执行。
- `Tests/UITests/NavigationContextTests.swift`：替换原“导航隐藏”断言，覆盖多层导航保持挂载/状态栏、任意页面切换展开偏好、录音/播放状态及频带更新、前后台恢复、活动结束与根失活不复活旧内容。
- 更新 `UI/README.md`、`UI/Root/README.md`、Island README、`MobileHarness/README.md` 中旧层级和导航暂停描述；更新测试 README。跨模块生产者、Gateway、声音采集/播放接口不变。

## 验证

定向运行导航/Island 状态回归，再执行 `scripts/check.sh` 和 `scripts/build-ios.sh`。有可用设备/模拟器及交互能力时验证设置、多层记录页中的显示、展开/收起和页面触摸；真实麦克风/声音及物理触控单独记录，不用状态测试代替。验证结果保存在 `docs/validation/Global-In-App-Island.md`。

## 交付结果

实现、旧导航隐藏逻辑清理及当前技术文档已完成。定向 49 项 UI/6 项集成测试通过；四个 iOS scheme 构建通过。完整检查首次有一项无本次改动的平台状态恢复限时失败，独立复跑及整个失败阶段复跑通过，独立原生运行时阶段 227 项通过。首次失败及日志保留在 [验证记录](../validation/Global-In-App-Island.md)。

原生界面工具因 Mac 锁定不可用，用户明确暂不方便解锁；模拟器实际交互、真机显示/声音和安装未执行，作为独立设备复验记录，不将状态测试冒充物理验收。
