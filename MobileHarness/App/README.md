# App — 应用入口与组合根

## 职责与边界

✅ App 创建并持有唯一模块根，注入公开窄接口，连接页面与系统回调，编排应用生命周期及首页模型准备。业务策略、请求消费、数据转换、执行和错误呈现由所属模块负责；业务消费者不查询注册容器。

## 直接上下游

| 相邻模块／来源 | 接口与关系 |
| --- | --- |
| iOS／Scene | 应用入口接收活动状态及后台 URLSession 回调 |
| Storage／PlatformKit／UI／ModelKit | 注册同一作用域的基础根、子能力和公开生命周期接口 |
| Agents | 创建并缓存 AgentContainer，注入基础能力、领域仓库提供器及执行工厂；读取角色公开呈现能力 |
| Actions | 创建相机等执行服务并连接公开端口；转交模型下载后台回调 |
| AppLifecycle | 将模块方法绑定为 ManagedService，等待启动、前后台切换与停止 |

完整业务执行链见[总体设计](../README.md)。App 不订阅 UI 业务输入，不逐帧转发媒体，也不编码外部 Signal。

## 内部结构与数据流

| 目录／文件 | 职责 |
| --- | --- |
| MobileHarnessApp.swift | 挂载 UI.ApplicationRootView，转交 Scene 状态 |
| [Composition](Composition/README.md) | 注册根、显式装配服务、组合 UI 协议及安装静态依赖图 |
| [Lifecycle](Lifecycle/README.md) | 通用服务图、启动回滚、前台屏障、根拥有的准备任务及系统回调适配 |

入口 → AppComposition → ServiceFactories 创建 Services → ModuleRegistration 安装生命周期。ApplicationPresentation 组合 UI 页面和角色公开状态／请求端口；角色任务独立于页面存在。

## 生命周期与失败

✅ 静态依赖为 diagnostics → storage → model，diagnostics → platform／ui，storage／platform／ui／model → agents → homePreparation。App 只调用 Agent 根的 start／invalidate／setForeground／stop；角色与原生会话的内部顺序由 Agents 负责。

初始 inactive 等待 active；失活先同步关闭接纳，再加入异步暂停。快速 inactive → active 仍完成必要暂停。启动中由系统失活触发的取消，在清理成功后等待下一次 active 重建作用域；业务错误与清理失败保留原值。

重试合并为一个替换任务，旧图与准备工作停止成功后才创建新根。清理失败阻止替代原生所有者启动。持久化记录和媒体保留，业务效果不重放。后台制品恢复可先于前台业务图使用模型／存储根，替换时仍须加入其停止。

首页模型准备是根拥有的宿主编排：仅在前台首页激活，使用 ModelKit 公开 readiness／prepare 接口；实际加载事实经 Agents 决定呈现。具体顺序和连接见 [Composition](Composition/README.md)。

## 待实现

❌ 多窗口独立运行命名空间、非合作依赖的强制中断。真实模型、原生 UI 和设备验收范围见 [验证入口](../../docs/validation/README.md)。
