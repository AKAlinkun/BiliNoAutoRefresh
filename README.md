# BiliNoAutoRefresh

禁止**哔哩哔哩 iOS 客户端**「首页 / 推荐流」自动刷新，**完整保留**手动下拉刷新和上拉加载更多。

- 目标 App 包名：`tv.danmaku.bilianime`
- 适用环境：iOS 14 ~ 17.0 + TrollStore（巨魔）
- 注入方式：TrollFools 原位注入 dylib（无需越狱、无需重签名整个 App）

---

## 一、原理（一句话）

B站的下拉刷新基于 MJRefresh。**手动下拉**会先把 header 状态置为 `Pulling`，**自动刷新**则是 App 直接调 `beginRefreshing` 或把状态置为 `Refreshing`（此时用户并没有在拖屏幕）。

插件在 `beginRefreshing` / `setState:` 上加一道闸门：判定「不是用户自己拉的」就直接返回、不执行原方法。
所以自动刷新被吃掉，手动下拉完全不受影响。附带拦截系统原生 `UIRefreshControl` 的程序化刷新。

---

## 二、需要改的地方（就一处）

打开 `Tweak.x`，顶部四个开关：

| 变量 | 默认 | 作用 |
|---|---|---|
| `kEnabled` | `YES` | 总开关 |
| `kBlockUIRefresh` | `YES` | 是否同时拦原生 UIRefreshControl |
| `kDebugLog` | `NO` | 打开后把每次拦截写到日志文件 |
| `kProbe` | `NO` | 打印首页相关页面出现记录 |

---

## 三、编译（二选一）

### 方案 A：GitHub Actions（推荐，不需要 Mac）

1. 在 GitHub 新建一个仓库，把本文件夹（**含 `.github` 目录**）整体传上去。
2. 上传后 Actions 会自动跑；也可以到 Actions 页面手动 `Run workflow`。
3. 跑完在对应 run 页面底部 **Artifacts** 下载 `BiliNoAutoRefresh.zip`。
4. 解压后里面有两样东西，**只需要 `.dylib`**：
   - `BiliNoAutoRefresh.dylib` ← 手机注入用这个
   - `com.workbuddy.bilinoautorefresh_1.0.0_iphoneos-arm.deb`（越狱用户走 Sileo 装）

### 方案 B：本地 Theos

需要 macOS 或 Linux（Windows 不支持）：

```bash
export THEOS=~/theos
git clone --recursive https://github.com/theos/theos.git "$THEOS"

make clean package FINALPACKAGE=1
```

产物位置：
- `packages/*.deb`
- `.theos/obj/BiliNoAutoRefresh.dylib`（rootless 方案下在 `.theos/obj/arm64/BiliNoAutoRefresh.dylib`）

---

## 四、装到手机（TrollFools）

1. 手机已装 **TrollStore（巨魔）**。
2. 用巨魔装 **TrollFools**（巨魔注入器）。
3. 把编译好的 `BiliNoAutoRefresh.dylib` 传到手机（隔空投送 / 文件 App / iCloud 都行）。
4. 打开 TrollFools → 在应用列表里点 **哔哩哔哩** → 点添加 → 选中那个 `.dylib` → 点**注入**。
5. 等进度走完，彻底杀掉 B站后台再重开，即生效。
6. 想卸载：TrollFools 里同页面左滑那个 dylib → 删除（或「全部推出」），重启 App 即恢复原状。

> TrollFools 会把 CydiaSubstrate 一起注入，所以普通巨魔设备不用额外装 EileKit/ElleKit。

---

## 五、验证与排障

### 正常效果
- 首页推荐流：切走再回来 / 从后台回到前台 / 停留一段时间 —— **列表不再自己刷新**，滚动位置保留。
- 手动下拉：照常刷新。
- 继续上滑：照常加载更多。

### 如果没生效

1. 把 `kDebugLog` 改成 `YES` 重新编译注入。
2. 用 **Filza** 打开 B站沙盒：`文件系统 → var/mobile/Containers/Data/Application/<随机串>/Documents/BiliNoRefresh.log`，
   也可以直接搜索文件名 `BiliNoRefresh.log`。
3. 看日志内容：
   - `✅ MJRefreshHeader 闸门已启用` → 钩子挂上了，但可能**目标不是 MJRefresh 实现的刷新**；
   - `⚠️ 未发现 MJRefresh` → B站换了自研刷新控件，需要把 `kProbe` 也打开，抓出首页 VC 类名后再补钩子。
4. 把日志内容发回来，据此改 `Tweak.x`。

---

## 六、已知限制

- MJRefresh **自动上拉加载更多**（MJRefreshAutoFooter）未做处理，仍按原逻辑工作；若也想禁掉，说一声。
- 若 B站某些版本首页是**自研刷新视图**而非 MJRefresh，需要补一轮针对性 hook。
- 本插件只改本机 App 的交互行为，不修改服务端逻辑，不影响账号。
