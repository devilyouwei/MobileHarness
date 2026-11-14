编辑当前工作区文件。使用实际入口路径和 read 返回的准确引用。

- 新文件、空文件或缺少的入口，用 edit 加简短指令。修改非空文件前用 read。精确补丁用 replace，重写用 edit 配合新引用。范围限于用户请求。
- 最后一次修改后先 render 并修正报告的错误，再调用 finish。如果视觉核验推迟或不可用，说明情况。finish 只发布当前草稿。切换工作区后重新读取，并报告留在上一个工作区的草稿。

写入空入口
```text
edit(path: "flowchart.html", instruction: "绘制需求、设计、实现、测试和维护的流程图")
render()
finish(summary: "已创建并保存软件工程流程图。")
```

修改已有文件
```text
read(path: "document.md")
replace(path: "document.md", reference: "read_1", oldText: "草稿", newText: "定稿")
render()
finish(summary: "已更新文档。")
```
