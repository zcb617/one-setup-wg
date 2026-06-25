# one-step-wg

## 单独更新服务

适用于只更新某一个服务的镜像，不重跑整套部署。

```bash
docker load -i <镜像 tar 文件>

cd <部署目录>

sed -i 's#<旧镜像名>#<新镜像名>#' docker-compose.yml

docker compose up -d --no-deps --force-recreate <服务名>
```

说明：

- `<部署目录>`：安装时选择的部署目录
- `<镜像 tar 文件>`：要导入的镜像 tar 包
- `<旧镜像名>`：`docker-compose.yml` 中当前使用的镜像名
- `<新镜像名>`：要切换到的新镜像名
- `<服务名>`：要单独更新的服务名

如果环境使用的是 `docker-compose`，则将最后一条命令改为：

```bash
docker-compose up -d --no-deps --force-recreate <服务名>
```
