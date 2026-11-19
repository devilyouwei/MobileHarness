# 模块测试修复验证

2026-11-18 至 2026-11-19。按 [模块审查](Module-Test-Coverage.md) 修复；执行证据与未执行范围分别记录如下。

## 变更

- 跨模块测试按发起工作流归属；Gateway 调度、Agents/Writer 工作流、App 根注册已迁入对应既有目录，编译 target 保持原边界。
- AppWorkflowTests 独立安装生产 Action 声明；Writer/Web 不依赖另一测试进程先初始化。Writer 取消等待增加有限期限和取消 join。
- 提示词契约核对当前语音/字幕说明；识别模型清单包含已有 DeepFilter。三个截止时间敏感用例在原 LiveRuntimeTests 串行阶段执行，不改生产期限。
- SoundSource 核对处理总采样量，不再把 VAD 切片数等同原始输入次数；保留慢订阅者期间后续方向可达断言。
- 实际 ServiceFactories/ModuleRegistration/AppComposition 在独立 Simulator 验收中启动，使用临时根和语言偏好，验证 UI 设置恢复、导航、前后台、停止和拒绝后续请求；正常产品编译入口不执行验收。

## 已取得的专项证据

- Writer/Web/提示词/资源清单修复的专项运行中，AppWorkflowTests 29项通过；IntegrationTests 的 Writer 等相关用例通过，第一次声音断言修正发现旧包数假设，随后按采样量修复。
- 声音专项重跑1项通过（0.054秒），日志 `/tmp/mh-sound-repair.log`。
- 18项 Python 工具回归通过，175个 Tests Swift 源文件均登记且无重复。

原生装配及全量检查日志：`/tmp/mh-composition-ios.log`、`/tmp/mh-module-check.log`。模型通信 smoke 仍显式关闭；本次不读取真实凭据，不作真实模型质量、设备效果验收结论。

## 完整工程检查

- 独立重跑 `./scripts/check.sh` 返回0：边界、18项 Python、严格格式、Swift 两阶段和五个项目/plist 检查全部通过。普通 IntegrationTests 为1197项，AppWorkflowTests 为198项，串行 LiveRuntimeTests 为231项。
- 最后四个纯宿主注册/顺序/回滚用例从 Gateway 迁到 App/Composition 后重新编译并定向运行，4项通过；没有改变其测试语义。日志 `/tmp/mh-module-root-moves.log`。
- Tests 的2106个 @Test 声明保留；新增 Simulator 验收为独立条件入口，不计入默认 Swift 测试数量。175个源码成员无漏挂/重复，受影响导航链接与 diff 格式通过。
- 首次全量检查与全新模拟器初始化重叠，出现多项超时/短等待失败；停止该专用模拟器后独立重跑全部通过。首次日志单独保留在 `/tmp/mh-module-check-with-simulator.log`，不以首次运行作为通过证据。
- 装配运行器限定受支持的 arm64 Simulator，安装/启动/等待均有超时，且独立 DerivedData 不覆盖普通 App。真实模型 smoke、原生页面点击和真机验收未运行。

## 最终全量重跑（2026-11-19）

全部改动完成后，再次独立执行 `./scripts/check.sh`，日志 `/tmp/mh-final-full-check.log`。所有 Swift target 的测试汇总通过：普通 IntegrationTests 1197项（70.722秒）、AppWorkflowTests 198项（2.690秒）、串行 LiveRuntimeTests 231项（216.198秒）及其余 target 均通过；未出现失败记录。18项 Python 工具测试、模块边界、严格格式及最后五项项目/plist 检查通过。此次未并行启动模拟器或构建，真实模型、实验评估和其他显式开启的验收仍按默认配置跳过，不计为已验证。

## 生产装配 Simulator 验收

`./scripts/simulator/test-composition.sh` 独立运行返回0。新建并最终删除专用 iPhone Simulator；实际生产 ServiceFactories、ModuleRegistration、AppComposition 完成启动、UI 设置恢复请求、导航、快速前后台、停止后拒绝请求及重复停止。记录 `build/CompositionAcceptanceDerivedData/composition-acceptance.json` 为 `{"result":"passed"}`。

这证明生产装配与公共端口闭环，不代表真实模型推理、UI 点击/截图或物理设备验收。首次多架构链接失败已通过限定支持的 arm64 修正；首次与全量测试重叠的启动被终止，随后独立运行通过。验收产物与普通 App 独立，避免测试入口污染后续 UI 验收。

## 普通 iOS 构建

`./scripts/build-ios.sh` 返回0，MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero、ModelKitAppleLLM 五个 Simulator scheme 均构建成功；最终普通 App 的 Agent/Skill 资源、Live Activity 和中英文本地化验证通过。正常 App 入口已重新构建，与独立验收产物分离。日志 `/tmp/mh-module-ios.log`。
