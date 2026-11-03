# Island — 通用灵动岛组件

## 职责与接口

UIContainer持有唯一IslandState。上游提交UI自有IslandContent、身份/版本、图片引用和真实频带；组件拥有呈现状态、资源、布局、交互和两端回执，不执行相机、语音、Task或导航业务。依赖UI根的UIStateSnapshot及Shared机制；系统扩展只编译本目录的共享内容、指标和Widget入口。

| 文件 | 职责 |
| --- | --- |
| IslandActivityAttributes.swift | 共享内容、详情、指标、错误、系统快照及必要兼容解码；不包含View |
| IslandState.swift | 活动排序、版本围栏、展开偏好、图片资源、根生命周期与ui.island事实 |
| IslandHost.swift | App宿主、几何、动画回执、紧凑/展开内容布局与手势 |
| IslandIndicators.swift | 两端共用图标、进度、计时、频谱投影和尺寸常量 |
| IslandStatusBar.swift | 默认系统状态读取端口、可见期间刷新、边缘避让及状态条绘制 |
| IslandSystemPresentation.swift | 系统写入队列、心跳、阶段提醒及ActivityKit驱动/进程退出适配 |
| IslandActivityWidget.swift | 系统compact/minimal/expanded与锁屏视图 |

不按View/Model技术类型拆散组件；几何、手势和电池绘制算法与其宿主同文件，供纯单元测试使用。外部调用不接触UIKit容器、原生活动句柄或动画参数。

## 内容与展开规则

IslandContent的primary/secondary分别表示左右IslandIndicator，支持symbol(name,effect)、loading、spectrum、progress和elapsed。符号效果none/pulse/bounce/variableColor由组件统一实现。title/subtitle用于无障碍、记录和锁屏摘要，不在紧凑区显示描述文字；elapsed是专用计时附件。detail仅包含可选text/thumbnail；展开图标复用详情活动primary。

有效文字或图片即支持展开，首次出现或明确新expansionID默认展开。空白文字且无图归一化为无详情。每个活动独立保存手动收起偏好，普通更新不重新展开，清空详情立即收起。无详情内容不可强制展开；收起只改变偏好，不清除内容或停止业务。

有详情活动与无详情实时活动分别按rank优先、同级最新选择。展开正文持续显示所选详情，顶部独立切换实时状态；无实时状态时展开顶部不重复详情图标。紧凑态选择实时状态，没有实时状态才回退详情身份。系统投影先过滤liveActivity=false，再遵循同一选择规则。ui.island的detailID/statusID分别表示两组选择，selectedID表示系统快照身份锚点；组件不识别业务owner名称。

```json
{
  "title": "任务目标",
  "primary": {"kind": "symbol", "symbol": "scope", "effect": "pulse"},
  "secondary": {"kind": "loading"},
  "detail": {"text": "拍摄一张照片"}
}
```

progress.value范围0...1；elapsed.startedAt为默认Swift Codable Date，即2001-01-01 UTC起的秒数。detail.thumbnail只能是已注册UUID，不能传路径、URL或Base64。内容不携带导航目的地/按钮，整个系统岛点击固定mobileharness://island，只恢复App已有场景，不改变页面或启动设备。

## 导航遮挡与恢复

UI模块根通过setLocalPresentationVisible提供本地可见性，Island不读取导航路径。首次离开首页保存当前最多8活动的展开偏好，并停止本地宿主、命中、状态条刷新与布局占位；expanded/detail反映本地收起态，原生活动内容、系统摘要和业务生命周期继续。多级push/pop不重复保存，只有回首页才恢复仍存在且有详情的活动偏好；活动结束立即移除对应保存值，新活动使用自身默认偏好，不复活旧活动。根失活清理保存值，前后台切换不会解除导航遮挡。

本地挂载、布局预留和完成回执均检查本地可见性；导航期间迟到回执不得恢复状态栏接管。组件保留根拥有的内容与资源，普通导航不调用setAvailable(false)或结束Live Activity。

## 本地容器、布局与交互

IslandHost使用场景非key透明UIWindow，挂载前设公开UIWindow.Level.alert并保持到拆卸。覆盖控制器固定深色外观；Root根据replacesSystemStatusBar隐藏原状态栏，由同组件时间/网络/电池接管。关闭动画完成才恢复系统状态栏，后台/根失活立即恢复。系统隐私指示器不由组件控制。

IslandPlacement.frame是左右留16pt、最大宽420pt的统一内容容器，compact是中央业务区域，background是黑色背景范围。紧凑background仅覆盖compact，系统状态保留在两端透明区域；展开background覆盖完整容器及详情。透明surface统一承载背景、正文、顶部业务和状态条，裁剪与坐标转换随同一动画变化。黑色背景圆角外及透明系统状态区域触摸透传。

IslandCompactMetrics统一紧凑高度110/3pt、中央硬件保护区376/3pt、图标槽22pt、符号18pt。计时使用44pt槽、16pt等宽数字，仅增宽不增高；内容槽紧邻中央保护区，无内侧padding，仅外侧8pt。顶部按safeTop−48校准；受测402×874pt设备为14pt。非适配竖屏使用无硬件保护区的安全区备用布局。隐藏状态栏暂时使安全区归零时保留同视口基准，旋转重算。

公开SDK不提供App读取完整系统岛frame的接口；上述硬件估算依据Apple HIG及受测截图，不保证所有未来设备。系统Widget保留iOS外壳/默认边距，仅共享指标语义和18pt符号尺寸。

展开顶部相对紧凑态下移6pt；正文从紧凑高度加10pt处开始，距顶部槽4pt，正文横边24pt、底边18pt。主图标24pt、文字15pt按subheadline缩放、缩略图56pt等比适配；图标、自然高度短文、图片与44pt收起按钮共享垂直中线。长文经ViewThatFits选择滚动容器，纯图片不留空文字占位。

点击展开区/箭头或向上滑动收起，点击紧凑业务区再展开。上滑至少36pt且垂直位移大于水平1.5倍；滚动与点击互斥。中央黑色硬件区域属于组件命中范围；透明外侧系统状态不拦截触摸。交互只修改显示偏好。

## 动画与呈现生命周期

UIViewPropertyAnimator拥有可中断的frame/corner过渡，捕获当前presentation值后接续。首次紧凑显示先用300ms、阻尼0.76展开至全宽，再仅将黑色背景以520ms、阻尼0.72收回中央；两端系统状态位置不变。展开/收起620ms、阻尼0.76，退出220ms。Reduce Motion直接设置目标背景，使用120ms短淡入并停用循环符号效果。

两段开场共享动画身份与generation/localRevision，最后一段实际完成才回执；新目标、关闭、失活均取消或接续当前段，不以固定延时伪造完成。submitted是接纳状态，不表示实际settled或业务成功。顶部hosting直接观察频带与活跃标志，音频帧不推进localRevision，不重启外壳动画。

localFrame只读发布scene窗口坐标的目标占用矩形，布局变化不推进内容revision或系统摘要。Root把底边适配成Window的通用topBoundary，Island不持有WindowState，Actions不能设置几何。真实拆卸/后台清空该占用。

Scene后台仅拆本地宿主、停止可见刷新，保留内容、图片、手动偏好与generation，系统摘要继续反映真实运行状态。根失活清空活动、图片和旧代内容，停止频谱并提交暂停摘要；stop加入图片解码和系统结束。每代最多8活动、256个owner/revision身份账本；版本/owner/代际不符明确拒绝。

## 图片与频谱资源

IslandState提供Data→IslandThumbnailID注册与释放接口，保存owner/generation。注册后首次发布绑定一个活动，跨owner或重复绑定拒绝；替换、清空详情、活动结束、根失活释放绑定图片。未绑定图片由调用方释放；进入后台不清空内容资源。

输入最多4MiB、源图单边8192且总像素4000万以内；ImageIO后台解码应用EXIF方向、最长边缩至256并重编码PNG。最多8资源、一个在途解码，满载capacity/busy，不排队；取消与迟到回执受代际围栏保护，stop加入真实完成。不访问文件、网络、Storage或PlatformKit。显示View仅解码已缩小数据，收起时不挂载图片View。系统快照不传图片。

IslandCompactView/IslandExpandedView复用IslandIndicatorView。App频谱将32个实测频带聚合为5柱，Reduce Motion静态显示，不制造音频数据或逐帧业务任务；系统Widget只显示频谱状态符号。elapsed使用SwiftUI原生计时文字，不要求调用方每秒发布。

## 默认系统状态

系统状态不属于IslandContent或Action JSON。UIContainer接收只读IslandDeviceStatusReading，App逐字段适配PlatformKit驻留power/network事实；UI不采设备、不探测网络或请求权限。IslandStatusBarState只在本地实际挂载时持有一个刷新任务，每5秒读取缓存，分钟边界提前刷新时间，退出/后台/根失活取消。读取失败清为未知，同一失败周期只报告一次。

左侧时间16pt，右侧网络18×18pt、电池28×14pt，与业务区域共用垂直中线。电池含轮廓、端帽、真实比例填充和等宽数字；充电bolt、低电量红色、低电量模式黄色、充电绿色，未知显示横线。网络仅表示系统路径类型，不表示信号强度或服务可达。

两端内边距统一16pt，空间不足先同步压缩到10pt，再隐藏靠近业务的网络、随后电池；时间无法容纳才隐藏。业务尺寸不受系统状态挤压。状态条不接收触摸；挂载/恢复系统状态栏及模态页面行为须真机验收。

## 系统呈现、兼容与结束

IslandActivityWidget由ActivityKit/WidgetKit决定原生外壳、compact/minimal/expanded及锁屏位置、动画和展开时机。系统摘要以详情活动为身份锚点，primary/secondary消费实时状态，detailPrimary/detailTone独立保留详情语义，hasStatus控制顶部。紧凑区不放描述文字；不能承诺连续频谱或任意循环动效。参考[1998code Demo](https://github.com/1998code/iOS16-Live-Activities/blob/main/WidgetDemo/WidgetDemo.swift)。

IslandSystemPresentation仅有一个在途写入、一个可替换最新值，30秒心跳、60秒staleDate。禁用/被用户移除/失败停止心跳；系统失败独立于本地呈现，错误保留在ui.island。每阶段提醒账本最多256项。驱动安装主动提交空快照，清理上次进程活动；根停止串行加入结束操作。

共享快照限制3500字节，指标使用kind/symbol/effect/value/startedAt编码。旧symbol/trailing/progress仅在解码边界转换，旧detail.symbol和destination/linkTitle忽略，不存储或再次编码。缺少detailPrimary时渲染回退primary，缺少hasStatus时按旧详情规则兼容，不保留第二套渲染器。

系统isStale/paused/ended投影明确的过期/暂停/结束状态，去掉运行指标、计时和旧目标；stale不表示实际结束。App原生终止回调调用IslandProcessLifecycle.endBeforeTermination，在独立任务执行ActivityKit.end(.immediate)，最多同步等待1秒，超时返回false由App记录。这仅用于进程退出，不用于普通Scene切换或后台保活。

iOS可能直接结束挂起进程且不发送终止回调；本地代码不能保证划掉App后立即移除系统活动。过期外观与下次启动清理是兜底，不是自动end。正常根stop使用异步串行清理。

[UI模块](../../README.md) · [公共组件](../README.md)
