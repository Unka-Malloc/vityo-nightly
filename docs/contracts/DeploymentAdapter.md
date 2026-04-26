# DeploymentAdapter

**Purpose:** 冻结打包、发布预检和 registry 发布接口，让前端可以围绕 package artifact 与 publishability 状态独立开发。

**Last updated:** 2026-04-21

## 1. Result Contract

### `DeploymentCommandResult`

1. `command`
2. `status = blocked | succeeded | failed`
3. `statusMessage`
4. `stdout`
5. `stderr`
6. `payload`
7. `errorPayload`

## 2. Operations

1. `packProject(projectGraph, packageName, outputPath)`
2. `preparePublish(projectGraph, packageName, outputPath)`
3. `publishToRegistry(projectGraph, registryRoot, packageName, outputPath)`

## 3. Hosted Route Mapping

当 adapter 走 cloud/hosted route 时，固定对接：

1. `POST /api/styio-hosted/v1/workspaces/{workspace_id}/deployment/pack`
2. `POST /api/styio-hosted/v1/workspaces/{workspace_id}/deployment/preflight`
3. `POST /api/styio-hosted/v1/workspaces/{workspace_id}/deployment/publish`

## 4. Required Behaviors

1. `preparePublish` 与 `publishToRegistry` 必须共享同一套 package 选择语义；只有一个 publish-ready package 时允许自动选择，多包或零包时必须返回 `blocked`。
2. 部署结果必须结构化承载 `package`、`archive_path`、`registry_root`、`mode` 等字段，不能要求前端解析命令行文案。
3. 前端不通过遍历 `dist/`、registry checkout 或本地索引目录来判定发布是否成功，一律以合同返回值为准。
4. hosted route 和 CLI route 在产品语义上必须等价；差异只能体现在 transport 和权限环境上。
