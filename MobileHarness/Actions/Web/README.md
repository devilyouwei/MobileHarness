# Web — 浏览与图形开发

Actions 拥有网页浏览、工作区内容和独立模型编辑请求。Gateway 调用 Web.Page 函数；本目录消费 UI.WebPagePresenting、UI.WindowState、ModelKit.ChatCapability 和 StorageFiles，装配注入截图存储闭包。无 Agents 或 Gateway 实现依赖。

WebActions 定义 browse/snapshot/inspect/navigate/develop/open/projects/delete；均为 direct returning。develop 只接收文字 task、可选 projectID/title，内部模型输出不会进入主 Assistant 协议解析。WebExecutionService 根持有最多一个工作，零等待队列，重叠拒绝；取消、关闭和停止取消并加入任务。窗口关闭不删除作品。

WebEditor 每次任务最多24个独立模型请求，沿用注入模型配置和独立 scope。内部单对象 JSON 协议提供 list/read/create/replace/delete/render/finish。读取后唯一字符串替换，歧义与未知命令返回可恢复反馈；模型传输、保存与渲染失败显式抛出。输出每轮32KiB，历史最多8条，连同任务指令共60,000 UTF-8字节；协议、任务和当前文件清单放入最新user观察，兼容本地模型的末尾消息裁剪，历史不重复保存提示词。读取每页2500字符并返回nextOffset。finish要求当前草稿已经render。支持图像的模型在render后收到真实截图，历史最多保留一张当前渲染图。此协议不是原生工具调用，不要求模型支持 native tools。

WebDraft 拥有路径、文件与编辑验证，拒绝绝对路径、隐藏路径、穿越与不支持扩展名；仅 HTML/CSS/JS/SVG/JSON/TXT。每项目32文件、单文件64KiB、合计256KiB源码。HTML发布时加UTF-8 BOM，入口读取预算额外容纳3字节，避免无charset的中文乱码。WebWorkspace 使用 StorageFiles 独立命名空间，逐文件不可变版本写入后 CAS 更新索引；失败清理新版本，清理失败保留双重错误。最多8项目、每项目16版本，超限拒绝。版本保留确保已挂载WebKit读取不被覆盖；删除项目显式删除全部版本。索引先写入待删除身份并移除可见项目，再清理目录及标记；清理失败不声称完成，同一ID可重试。待清理项目仍计入8项目容量。

截图通过既有 StorageMedia 受 source/session/input 约束的 JPEG 记录存储，并在结果返回 mediaID；Assistant 图像观察消费真实字节。标题、页面文字与诊断均为不可信数据。保存完成与渲染完成独立；渲染失败仍保留已发布版本供 projects/open恢复。原生实现与安全边界见 [UI Web](../../UI/Components/Web/README.md)。

WebExecutionService创建“网页与绘图”窗口时提供🌐 emoji图标；窗口外观由UI拥有，业务不计算卡片宽度，图标不读取网页favicon或外部图片。
