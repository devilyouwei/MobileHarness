# 基础 App 相册验证

日期：2026-10-25。当前契约见 [Camera](../../MobileHarness/Actions/Camera/README.md)、[Media](../../MobileHarness/Storage/Database/Media/README.md) 与 [UI Settings](../../MobileHarness/UI/Settings/README.md)。

## 自动化与构建

- 相册专项：9项测试通过，其中原生格式用例分别覆盖JPEG、PNG、HEIC三个参数。覆盖收录与ready分离、重复收录／仓库重开（字节为内存替身）、旧版SQLite迁移、容量保护、稳定分页、原文件字节保持与缩略图、删除清理恢复、部分导入失败、系统导出失败、并发变更拒绝／提交后取消，以及UI → Photographer → Gateway实际调用。
- `./scripts/build-ios.sh`：MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero四个目标通过；最后的摄影资源／无障碍文案修改后，补充主App构建通过。`verify-app-agent-resources.py`核对最终App内25个Agent／Skill资源，确认与源码一致。
- `./scripts/check.sh`：最终退出码0。边界检查、6项Python测试、严格Swift格式、全部普通及原生运行时测试、项目／隐私清单均通过；其中Integration普通阶段838项、原生阶段221项，AppWorkflow阶段133项。提示词预算实际base=23063、photography=30435，保持原有23500／30500上限。
- 修复过程保留：初次直接Swift构建使用Command Line Tools，因找不到metal失败；改用完整Xcode后Actions构建通过。初轮边界检查因选择器新增系统框架未列入许可而失败，现仅为该页面增加公开系统框架许可，不放宽UI项目依赖边界。先前完整回归发现摄影提示超预算，以及完成示例／已提交保存反馈测试仍硬编码旧保存文案；已精简教学并按App相册语义更新断言，没有放宽预算或移除Task闭合验证。已知失败的过期回归在重跑前终止，不记录为通过。
- 新增文档链接可解析，`git diff --check`通过。构建存在仓库既有的unused result／unnecessary await等编译警告，不将其当成真机验收证据。

## 真机验收（未执行）

1. 首页拍照后保存，确认进入App相册且不请求Photos权限；忽略不进入，重启后原片可读。
2. 设置用户板块顺序为记忆／相册／Agent记录；相册导航、空状态、分页、缩略图、详情缩放及返回位置正常，记忆保持静态项。
3. 系统选择器最多20张；JPEG／HEIC／PNG及iCloud待下载项分别导入；Live Photo明确仅静态照片。超限／损坏／不可读项显示失败，其他成功项保留。
4. 详情首次导出请求add-only权限；拒绝不丢App作品。允许后在系统照片中确认真实格式及画面；反复点击忙时不重复导出，一次完成后再次明确导出可创建另一份。
5. 确认删除仅影响App及关联历史图片，不删除Photos副本；删除清理失败显示真实状态，重启恢复后不重新出现。
6. 导入／导出中返回页面，结果仍由根收尾；前后台、权限弹窗、存储不足及App退出后保持已提交产物，不重放导出。

以上均为待验收步骤；构建和替身测试不等于原生选择器、系统相册事务、真实摄影Skill模型或物理设备验收。

## 真机安装（2026-10-25）

当前工作区使用完整Xcode、锁定Package.resolved完成MobileHarness Debug iPhoneOS签名构建，退出码0；最终App的25项Agent／Skill资源校验通过。覆盖安装至已连接的iPhone 17 Pro，bundle为dev.mobileharness.app，安装数据库序号4848；随后启动成功。未卸载旧App，未主动清除其数据。

本机日志：`/tmp/album-device-build.log`、`/tmp/album-device-install.log`、`/tmp/album-device-launch.log`。安装和启动不代表上述相册交互、系统Photos事务或真实模型验收通过。

## 对话打开相册修复（2026-10-25）

UI.Navigation.open的目标白名单与参数说明补齐album；application-control Skill增加App相册打开示例，revision更新为10。沿用原有会话／权限校验与UI导航路径，不开放相册搜索、删除或导出给模型。

新增回归通过生产Skill目录解析截图中的XML，经NavigationModule、ActionExecutor与真实ResourcePresentationAdapter确认presented回执及settings → album路径；覆盖非法目标（含memory占位项）、多余参数、无效会话与非允许角色不改变路径。XML为注入测试输入，不等于真实LLM或手机交互验收。初次测试缺少执行契约模块import导致编译失败，补齐后专项回归通过；首次失败不记录为通过。最终 `./scripts/check.sh` 退出码0，边界、Python、严格格式、全部普通／原生测试及plist检查通过；`./scripts/build-ios.sh` 四个目标全部通过，App打包资源校验通过。

本次修复尚未安装到手机；前述安装记录不涵盖此节变更。
