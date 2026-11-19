# Writer experiments

[evaluate_writer.py](evaluate_writer.py) 通过 Python 直接评估写作与文件操作 case。模型每轮返回一个 JSON command；[workspace.py](workspace.py) 执行内存工作区的 search/create/read/edit/replace/render/ask/finish 等合成工具并评分，不启动 App、Gateway、SQLite 或原生窗口。

- [writer-evaluation.json](writer-evaluation.json)：独立实验提示词与默认矩阵配置。
- [datasets](datasets/README.md)：目标、初始工作区、标签和断言。模型只看到目标和初始事实，不看到预期命令或答案。
- [results](results/README.md)：原始模型响应、工具反馈、文件内容与逐 case 结果。
- [render_review.py](render_review.py)：Python Playwright/Chromium 检查 DOM、脚本错误、图形及计数器。缺少浏览器依赖时相关 case 明确失败；不是 App WebKit/UI 验收。

```bash
python3 experiments/writer/evaluate_writer.py --config /path/to/model-config.json \
  --cases C03-text-notice --output experiments/writer/results/text-new.json
```

默认每 case 最多24次请求、300秒。所有文件仅存于实验内存或渲染临时目录，不读写真实用户工作区。窗口/取消类场景使用合成反馈，不能证明原生窗口生命周期。App 链路、渲染、单次 delegate smoke 归 [Tests/Agents/Writer](../../Tests/Agents/writer/README.md)。

本任务运行器的离线回归由 test_writer_evaluation.py 拥有，使用 `python3 -m unittest discover -s experiments/writer -p "test_*.py"` 独立执行，不依赖工程 Tests。
