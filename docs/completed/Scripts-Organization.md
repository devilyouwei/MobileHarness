# scripts 职责整理

按业务归档仓库工具；根目录保留 check.sh、build-ios.sh 和 README.md。

- checks：架构检查及 Python 工具离线回归；check.sh 显式发现该目录。
- resources：App 元数据/许可打包、图标选择、sandbox 清单和最终 Bundle 校验。
- models：模型下载、少量原生适配验收、参考结果比对及工程夹具生成。
- simulator：WebKit 与 Writer 原生 UI 验收入口。

五个仅转发模型名的下载器合并到 models/model_download.py 的位置参数入口；保持既有参数与下载策略。Nemotron/Silero 共用合成语音生成逻辑。其余工具职责不同，保留。同步修正代码、构建配置、文档命令与路径；历史 JSON 测量证据不改。scripts README 逐项说明用途，不重复 experiments 的实验设计。

验证 Python 离线回归、CLI、shell/AST、构建输入清单、引用完整性及必需的 check.sh/build-ios.sh。模型下载、真实模型和模拟器 UI 验收不在整理过程中自动执行。

## 实施结果

30个脚本整理为26个：删除5个仅转发模型名的下载包装入口，增加1个共用合成音频 helper，其余按职责归档。根目录仅 check.sh、build-ios.sh、README.md。下载器直接接收 profile（包括已有 catalog 的 d3-edge）；删除无调用者的 variants 参数及清单生成器的无效变量。

Xcode 构建阶段、scheme 预处理、sandbox 清单、文档命令和 Python import/仓库根解析已同步。逐文件职责见 [scripts 清单](../../scripts/README.md)。不删除用途不同的资源验证器或原生参考检查，不执行模型下载/付费调用/原生 UI 验收。

验证结果见 [验证记录](../validation/Scripts-Organization.md)；业务测试已有失败与停滞独立记录，不改变本次工具整理范围。
