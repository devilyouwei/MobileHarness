# Writer 工具与工作区身份验证

验证使用临时 SQLite、工作区目录和合成记录。数据库格式测试从旧 schema 启动，核对工作区文件外键、旧文件清理、配置保留和同版本再次启动。测试数据独立于手机。

## 自动化用例

- Writer 的参数化 Gateway/Artifacts 流程检查明确新建直接调用 workspace.create，HTML 误填后 workspace_2 尚未分配且没有窗口，修正后建立一个空入口，重复请求被拦截，再 edit、render、finish。
- 同一组覆盖现有作品查询、多开、切换及失败回滚，分别检查作品库和编辑阶段的 finish。工具目录测试核对点号别名、文件工具作用域和旧参数拒绝。历史及 SQLite 用例检查工作区/委托消息归属和新 ID 持久化。

## 真实模型与原生 UI

现有 Writer 评估矩阵的 P01 使用已有同名作品的显式重新创建请求，P04 修改已保存作品。输出记录实际首个工具与参数。原生 UI 使用独立 Simulator 和合成记录。

## 2026-11-10 验证证据

- 最终 check.sh 退出 0。IntegrationTests 1109 项及独立运行时阶段 229 项通过，项目配置校验通过。早期全量失败来自测试夹具仍使用旧目录、工具名及历史断言，均已改用当前契约。
- Swift Testing 定向运行 8 项通过，其中两个 Writer 参数化场景各 15 例，覆盖已注册别名、真实直接调用、模型阶段、SQLite 持久化与历史导出。SQLite 重置、索引事务回滚、受限路径删除另跑 3 项通过。
- build-ios.sh 四个 Simulator 方案构建成功。生产 App 打包资源通过脚本校验。
- 真实模型首跑的 WebKit 预检两项通过。两场景均在发起模型请求前拒绝旧评估委托携带的 entry。评估夹具已移除该字段，使用与生产相同的委托参数。
- Qwen 3.8 Max、minimum thinking，复跑 2/2 通过。P01 首个调用 workspace.create，参数 title 为「软件工程流程图」，entry 为 flowchart.html。随后 edit、render、finish，新作品为 workspace_2，旧同名作品保留。P04 首个调用 workspace.search，query 为「项目周报」，随后进入 workspace_1，读取并将「评审中」改为「已通过」，无新增工作区。此次运行的源码和二进制哈希保持一致。
- iOS Simulator 原生首跑启动 App，但欢迎引导晚于原有等待出现，遮挡设置入口。记录在 WriterUI.xcresult，未进入 My Writer。复测增加明确的引导退出和设置入口等待。
- iPhone 18 Pro Simulator（iOS 27.0）合成 SQLite 复测通过。原生点击通过 My Writer、委托详情、进入前请求、工作区消息第 40 轮和返回保留页检查。原生结果在 WriterUI-Rerun.xcresult。工作区导出 JSON 由定向集成测试校验。本轮验证未使用物理设备。

## 真机安装

- 2026-11-10，iPhone 17 Pro 原位更新为 0.1.0（2026111001）。签名、Agent/Skill 打包资源和 Live Activity 扩展校验通过，设备应用清单确认版本，系统启动请求成功。
- 安装使用系统原位更新。此步骤验证打包、安装和启动，数据库重置与 Writer 行为的验证证据见上文的隔离测试。
