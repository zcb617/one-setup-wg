# one-step-wg

用于在 Linux 服务器上一键部署 WireGuard、wg-api 与 wg-gen-web。安装过程为交互式：按提示填写 WireGuard 监听端口、Web UI 端口、管理员账号和密码，以及是否启用 Phantun、DNSCrypt。

## 开源协议

本项目的原创代码采用 [Apache License 2.0](LICENSE)。第三方组件仍按各自许可证发布，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 默认信息

| 项目 | 默认值 |
| --- | --- |
| WireGuard 端口 | `25111/udp` |
| wg-api 端口 | `25112` |
| Web UI 端口 | `25113/tcp` |
| Web UI 地址 | `http://<服务器公网 IP>:25113` |
| Web UI 初始账号 | `admin` |
| Web UI 初始密码 | `admin` |
| 部署目录 | `/opt/one-step-wg` |

请在安装时修改默认管理员密码，并按实际端口配置云安全组或防火墙。再次运行 `setup.sh` 会先清理已有的 one-step-wg 部署状态；已有配置需要保留时，请先备份部署目录。

## 安装前说明

- 必须使用 `root` 或 `sudo` 运行安装脚本。
- 脚本会检测 Docker 与 Docker Compose；缺失时会尝试安装。
- 安装时可直接使用本地镜像 tar。脚本会优先从“镜像 tar 文件目录”加载镜像，只有缺失时才尝试从 Docker Hub 拉取。
- 默认不启用 Phantun 与 DNSCrypt；启用后需要额外准备对应镜像包。

### 镜像包清单

| 功能 | 镜像 | tar 文件 |
| --- | --- | --- |
| 基础安装 | `james/wg-api:latest` | `wg-api.tar` |
| 基础安装 | `zcb617/wg-gen-web:0.0.4` | `wg-gen-web.tar` |
| 基础安装 | `zcb617/one-step-wg:0.0.6` | `one-step-wg-0.0.6.tar` |
| 启用 Phantun 时 | `zcb617/phantun:0.8.1` | `phantun.tar` |
| 启用 DNSCrypt 时 | `jedisct1/dnscrypt-server:latest` | `dnscrypt-server.tar` |

## 方式一：一键下载安装

适用于服务器可以访问 GitHub 和 Docker 相关软件源的场景。

```bash
curl -fsSL https://raw.githubusercontent.com/zcb617/one-setup-wg/master/setup.sh -o /tmp/setup.sh && sudo bash /tmp/setup.sh
```

脚本会按交互提示完成 Docker、Docker Compose 与服务部署。没有本地 tar 时，所需镜像会尝试从 Docker Hub 拉取。

## 方式二：GitHub Clone + 项目内 tar 镜像包安装

适用于希望先取得完整仓库、并使用仓库根目录内备份镜像安装的场景。

```bash
git clone --recurse-submodules https://github.com/zcb617/one-setup-wg.git
cd one-setup-wg
sudo bash setup.sh
```

在 `镜像 tar 文件目录` 提示处直接回车，即使用当前目录。基础安装会读取 `wg-api.tar`、`wg-gen-web.tar` 与 `one-step-wg-0.0.6.tar`；如在交互中启用 Phantun 或 DNSCrypt，还需要当前目录存在对应的可选 tar 文件。

## 方式三：网络受限时使用百度网盘离线包

下载地址：[百度网盘离线安装包](https://pan.baidu.com/s/1etOiZv-lxH7ScECAdvIo7A?pwd=xnqu)
提取码：`xnqu`

离线包包含 `setup.sh`、`uninstall.sh` 和全部镜像 tar。将它们解压到同一目录后执行：

```bash
cd <离线包解压目录>
sudo bash setup.sh
```

在 `镜像 tar 文件目录` 提示处输入该解压目录，或在当前目录执行时直接回车。基础安装需要前三个基础 tar；启用可选功能时，保留 `phantun.tar` 或 `dnscrypt-server.tar`。

离线 tar 仅解决镜像下载问题。若服务器尚未安装 Docker 或 Docker Compose，`setup.sh` 仍会尝试安装它们；请先确保服务器具备相应的软件源或已预装 Docker 与 Docker Compose。

## 方式四：自行制作 Docker 镜像后安装

适用于需要修改源代码或使用私有镜像仓库的场景。此模式直接使用本机已经构建好的镜像，不需要导出 tar；`setup.sh` 会优先检测本地镜像标签。

先克隆含子模块的仓库：

```bash
git clone --recurse-submodules https://github.com/zcb617/one-setup-wg.git
cd one-setup-wg
```

构建本项目维护的两个镜像：

```bash
docker build -t zcb617/one-step-wg:0.0.6 -f docker-build/Dockerfile docker-build
docker build --build-arg COMMIT=0.0.4 -t zcb617/wg-gen-web:0.0.4 vendor/wg-gen-web
```

`wg-api` 与 DNSCrypt 是第三方镜像；当前仓库没有它们的 Dockerfile。基础安装还需要在本机存在 `james/wg-api:latest`：

```bash
docker pull james/wg-api:latest

# 仅在安装时启用 DNSCrypt 才需要
docker pull jedisct1/dnscrypt-server:latest
```

当前仓库的 Phantun 子模块不包含 `docker/Dockerfile`，不能据此复现 `zcb617/phantun:0.8.1`。如安装时启用 Phantun，请自行补齐 Dockerfile 后构建，并使用该准确标签：

```bash
docker build -t zcb617/phantun:0.8.1 -f <Phantun Dockerfile> <构建上下文>
```

所需镜像均已存在后，在仓库根目录执行：

```bash
sudo bash setup.sh
```

## 卸载

在包含 `uninstall.sh` 的目录执行：

```bash
sudo bash uninstall.sh
```

脚本会删除容器、`wg0` 接口、相关路由/iptables 规则和部署目录。非交互执行可使用：

```bash
sudo bash uninstall.sh --force
```

如需保留部署目录，使用：

```bash
sudo bash uninstall.sh --keep-dir
```

## 单独更新服务

适用于只更新某一个服务的镜像，不重跑整套部署。

```bash
docker load -i <镜像 tar 文件>

cd <部署目录>

sed -i 's#<旧镜像名>#<新镜像名>#' docker-compose.yml

docker compose up -d --no-deps --force-recreate <服务名>
```

说明：

- `<部署目录>`：安装时选择的部署目录。
- `<镜像 tar 文件>`：要导入的镜像 tar 包。
- `<旧镜像名>`：`docker-compose.yml` 中当前使用的镜像名。
- `<新镜像名>`：要切换到的新镜像名。
- `<服务名>`：要单独更新的服务名，例如 `wg-gen-web`。

如果环境使用的是 `docker-compose`，则将最后一条命令改为：

```bash
docker-compose up -d --no-deps --force-recreate <服务名>
```
