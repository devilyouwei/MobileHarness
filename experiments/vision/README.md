# Vision experiments

[evaluate_vision.py](evaluate_vision.py) 使用 Pillow 准备图片，调用 Python `coremltools.models.MLModel.predict`。输入图片路径、图像输入名、目标尺寸、计算单元和迭代次数由参数指定；结果保存预处理时间、预热后的逐次推理时间、原始输出和失败。

```bash
python3 experiments/vision/evaluate_vision.py --model /path/to/model.mlpackage \
  --input-name image --images /path/to/case.png --output /path/to/new-result.json
```

这是 Python 模型推理测量，不复刻旧 Swift vImage、Vision 或张量桥接开销；报告明确执行路径。App 的视觉模型链路验证归 [Tests/ModelKit/Vision](../../Tests/ModelKit/vision/README.md)。
