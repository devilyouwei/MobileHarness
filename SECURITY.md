# 安全与隐私

安全问题不要附带密钥、个人数据或真实设备控制凭证发布到公开 issue。仓库尚未配置公开安全报告渠道；首次发布前由维护者设置私密报告入口。

Agent 输出不等于执行授权。ResponseGateway 先校验能力白名单，实际平台适配器再验证系统权限和动作参数。外部机器人接入前必须具备独立硬件急停、断连停机与指令有效期。

## Data handling and runtime privacy

The default inference configuration uses on-device speech and local chat; no cloud inference key is required for that mode. Model acquisition and Apple language-asset installation are separate network operations. Explicit cloud chat sends the selected request context, messages and any authorized attached photo content to the configured provider. Microphone processing, synthesis and YOLO pose inference remain local. The cloud adapter requests `store=false`; provider retention remains governed by that provider's policy.

Credentials are retained in device Keychain; preferences, role contexts and captured-photo evidence use device-local storage. Provider drafts/keys are staged privately rather than inserted into model arguments or histories. Microphone, camera, Photos and Bluetooth operations check their actual platform capability/permissions. User consent controls listening; immediate native lifecycle fences do not wait for model decisions.

Do not commit or post credentials, signing settings, model weights, recordings or private media. The repository has no configured private reporting channel yet. Physical control requires independent hardware protections and cannot rely on iOS background execution.
