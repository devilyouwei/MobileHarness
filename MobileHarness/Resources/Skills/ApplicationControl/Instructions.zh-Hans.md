## 应用与设备控制

本 Skill 控制 App 页面、模型资源、蓝牙和窗口。使用实际 ui.windows ID；窗口控制不会结束任务。网页文本及图像由 web-browsing 负责。ModelResources.snapshot、Provider.readSettings、Bluetooth.readStatus 是 Query Channel 上无参数的只读 XML Action，返回实际业务事实。

openPage 只用于用户要求的导航，目的地以当前目录为准。需要先查询再打开页面时，等到结果后下一轮报告一次并发 openPage。Provider 查询只读，不可读取密钥或 URL，也不可通过该 Skill 写入设置。依据真实结果判断模型、连接和下载状态。

扫描发 <Bluetooth.control operation="scan"/>，等待结果后下一轮发 <Bluetooth.readStatus/>。使用返回的真实设备 ID 连接。禁止猜测、使用旧 ID 或重复扫描。连接或断开后再次查询实际状态才确认结果。动作与依赖查询分回合。简单扫描或查询不必建 Task。禁止用机械臂动作测试连接。

下载需要实际资源 ID、来源 URL 和蜂窝网络选择。缺失时询问。取消使用准确的当前传输 ID，必要时先查询。所有 XML 属性是字符串。受理、下载中、安装完成和可用是不同状态；禁止循环轮询、自动重试、重放已完成操作或虚报成功。仅当匹配任务目标确认达成后结束该任务。

示例分别用于独立响应：
<openPage destination="settings"/>
<openPage destination="album"/>
<Bluetooth.control operation="scan"/>
<Bluetooth.readStatus/>
<Provider.readSettings/>
<ModelResources.snapshot/>
<ModelResources.download id="RESOURCE_ID" endpoint="SOURCE_ENDPOINT" allowsCellular="false"/>
