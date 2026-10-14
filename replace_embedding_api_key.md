# 更换知识库向量模型 Key

此脚本只更新当前数据库 `system_config` 表中 `embedding_model` 的 `api_key`，保留模型、接口地址、维度及其他配置。它不执行数据库结构迁移，也不重建索引。

在内网 `pg` 仓库目录执行 `git pull --ff-only`，然后运行下面这一整行命令（连接参数沿用本仓库内网盘点脚本；实际部署不同则调整）：

```bash
psql -X -h /tmp -p 5433 -U haier_user -d haier_db -W -f replace_embedding_api_key.sql
```

1. `Password` 提示输入的是数据库密码。
2. `New embedding API Key:` 提示出现后，粘贴新向量模型 Key 并回车。Key 不需要加引号；输入可能在终端显示，不要截屏传播。
3. 看到 `COMMIT`，且结果包含 `status=ok`、`key_configured=t`，表示替换成功。
4. 在客户端重新执行一次知识库检索。当前服务端按请求读取配置，无需重启；已经开始的请求可能仍使用旧配置。

Key 格式错误、配置不存在或配置不是 JSON 对象时，脚本停止，事务不会提交。成功后可以重复执行；需要回退时重新运行并输入原 Key。

脚本不包含任何真实 Key，可以保留在 Git 中。执行成功表示配置已保存，不代表供应商余额、权限或网络已通过验证。
