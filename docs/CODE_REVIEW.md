> **说明**：本文是发布前的代码评审存档，记录的是**当时**的代码状态与结论。
> 发布版已把默认接口地址改为占位符 `https://your-domain.example/coin.php`（属性 `apiUrl`，手机端可改），
> 因此文中「私人域名硬编码」一项已关闭；其余条目的取舍思路仍然适用。

# 代码审查与发布前 Checklist

审查对象：`TTCoin` 全部源码（Monkey C + PHP）。
结论：功能可用。**公开前只剩 #1（私人接口域名）一项**。原始共 15 项，已修复 14 项： #2 #3 #4 #5 #6 #7 #8 #9 #10 #11 #12 #13 #14 #15。

## 一、总览

| # | 位置 | 问题 | 严重度 |
| --- | --- | --- | --- |
| 1 | `TTCoinView.mc:10` | 硬编码作者私人接口域名 | 🔴 高 |
| 2 | `TTCoinView.mc:193-227` | `onReceive` 类型标注与实际 Array 数据不符 | ✅ 已修复 |
| 3 | 仓库根目录 | 缺少 `README` / `.gitignore` / `LICENSE` | ✅ 已修复 |
| 4 | `TTCoinView.mc:107-141` | 硬编码数组索引，返回条数不足即崩溃 | ✅ 已修复 |
| 5 | `TTCoinView.mc:13-26` + `onUpdate` | 像素坐标写死，仅适配 176×176 | ✅ 已修复 |
| 6 | `TTCoinView.mc:52-105` | 失败时永久停留 `Loading...`，无错误状态 | ✅ 已修复 |
| 7 | `TTCoinView.mc:42-50` | Timer 未在 `onHide()` 释放 | ✅ 已修复 |
| 8 | `TTCoinView.mc:244-326` | 无本地缓存，离线/断网时全黑屏 | ✅ 已修复 |
| 9 | `lib.php` `TTCOIN_CACHE_TTL` | 缓存 TTL 1 秒，缓存形同虚设 | ✅ 已修复 |
| 10 | `api/lib.php` | `coin.php` / `update_price.php` 约 90% 逻辑重复 | ✅ 已修复 |
| 11 | `lib.php` `ttcoin_cache_file()` | 缓存文件落在 Web 根目录，可被直接访问 | ✅ 已修复 |
| 12 | `TTCoinView.mc:198` | `data == null` 在非空类型上永远为假 | ✅ 随 #2 修复 |
| 13 | `TTCoinView.mc:23-26` | 变量无类型声明 | ✅ 已修复 |
| 14 | `resources/layouts/` | 空模板残留 | ✅ 已修复 |
| 15 | `lib.php` `ttcoin_fetch()` | 未校验 `price` 是否为数字 | ✅ 已修复 |

---

## 二、详细说明

### 1. 🔴 私人接口地址硬编码

```monkey-c
// TTCoinView.mc:10
const PRICE_API = "https://your-domain.example/coin.php";
```

公开仓库后，任何人下载代码都会打到你的服务器上：带宽、流量、被滥用的风险都由你承担，而对方一旦断网或你的域名过期，会认为"这个插件是坏的"。

**建议**

- 把域名替换为占位符，并让编译期就能发现未配置：

```monkey-c
const PRICE_API = "https://example.com/coin.php";  // TODO: 替换为你自己的接口
```

- README 中显著标注"必须自建后端"（已完成）。
- 若确实想提供公共服务，单独在 Issue 中说明可用性无承诺，不要写死在代码里。

### 2. ✅ 类型标注与实际数据不符（已修复）

```monkey-c
// 修复前：签名写 Dictionary
function onReceive(responseCode as Lang.Number, data as Lang.Dictionary) as Void {
    ...
    marketData = data; // 注释：实际运行时是 Array
}
```

`coin.php` 返回的是 JSON 数组，Monkey C 会解码成 `Lang.Array`。作者注释已经说明了这一点，说明当时遇到过问题，靠运行时类型检查不严格才跑通。

**调查结论（SDK 9.2.0 实测）**：`makeWebRequest` 的回调类型在 SDK 里被声明为

```
Method(responseCode as Number, data as Null or Dictionary or String or PersistedContent.Iterator) as Void
```

**这个联合类型里没有 Array** —— 这才是"签名与实际数据不符"的真正根源，属于 SDK 声明本身的缺口，不是写法问题。

因此**不能**把参数直接改成 `Lang.Object`，实测会在 `-l 1`（渐进模式，VS Code 默认）下编译失败：

```
ERROR: TTCoinView.mc:79: Invalid 'Method(responseCode as Number, data as Null or Object) as Void'
       passed as parameter 4 of type 'PolyType<(Method(... data as Null or Dictionary or String or ...)'
```

**最终采用的写法**——签名留在 SDK 允许的类型内，进函数后立即宽化为 `Object` 再用 `instanceof` 收敛：

```monkey-c
function onReceive(
    responseCode as Lang.Number,
    data as Lang.Dictionary?      // ① 满足 SDK 的回调签名约束
) as Void {

    if (responseCode != 200 || data == null) {   // ② 先排除 null
        hasData = false;
        WatchUi.requestUpdate();
        return;
    }

    var payload = data as Lang.Object;           // ③ 宽化，摆脱名义类型

    if (payload instanceof Lang.Array) {         // ④ 按真实类型判断
        marketData = payload as Lang.Array;
        hasData = true;
    } else {
        hasData = false;                         // 非数组结构（错误体）按无数据处理
    }

    WatchUi.requestUpdate();
}
```

四点改进：

| 改动 | 作用 |
| --- | --- |
| `Lang.Dictionary` → `Lang.Dictionary?` | 如实反映"错误响应时 SDK 会传 null" |
| 先判 null 再 `as Object` | 避免 `null as Object` 在运行时踩空（Monkey C 不允许局部变量显式标注类型，只能靠顺序保证） |
| `instanceof Lang.Array` | 服务端若返回 `{"error": ...}` 且 HTTP 200，以前会直接赋给 `marketData` 然后在 `marketData[0]` 崩溃，现在能拦住 |
| 去掉误导性注释 | 原注释"data 必须写成 Dictionary"是结论而非原因，会带偏后来的人 |

**编译验证**（SDK 9.2.0，临时密钥）：`-l 0/1/2` 均 `BUILD SUCCESSFUL`，0 error，警告数不高于改动前。

> 遗留风险：若某天 Garmin 真的在回调边界对 `Dictionary` 做强制校验，客户端无法自救——因为合法的联合类型里根本没有 Array。只能等 SDK 侧把 Array 补进去。

### 3. ✅ 仓库缺少基础设施文件（已修复）

三件套已齐：

- `README.md` —— 项目说明、部署、接口约定、排错；
- `.gitignore` —— 重点排除 `bin/`（其中的 `TTCoin.prg.debug.xml` 会写入**本机绝对路径与源码行号映射**，属于不该公开的本地信息）、`*.der`、缓存文件；
- `LICENSE` —— **PolyForm Noncommercial 1.0.0**，版权行署名 `TTCoin contributors`。非商业可自由使用、修改、分发；**商用须另行授权**。

### 4. ✅ 硬编码索引（已修复）

```monkey-c
// 修复前
var coin1 = marketData[0]["symbol"] + ": " + marketData[0]["price"].format("%0.2f");
var coin2 = marketData[1]["symbol"] + ...
var coin3 = marketData[2]["symbol"] + ...
```

服务端虽然做了完整性校验（`coin.php:131`），但客户端不该信任远端一定返回 3 条。只要返回 2 条就是数组越界，Widget 直接异常退出；返回 4 条则第 4 条永远看不到。

**修复方式**：把"按下标取三条"改成"遍历 + 逐条校验 + 最多 3 行"，渲染逻辑与数据结构解耦。

```monkey-c
const MAX_ROWS = 3;      // 一屏最多显示几行行情
const REF_ROW = 30;      // 参考行距（按屏幕高度等比缩放）

function buildRows() as Lang.Array {
    var rows = [] as Lang.Array;

    if (!(marketData instanceof Lang.Array)) {
        return rows;
    }

    var list = marketData as Lang.Array;

    for (var i = 0; i < list.size() && rows.size() < MAX_ROWS; i++) {

        var item = list[i];
        if (!(item instanceof Lang.Dictionary)) { continue; }   // 不是 {symbol, price} 结构

        var dict   = item as Lang.Dictionary;
        var symbol = dict["symbol"];
        var price  = dict["price"];

        if (!(symbol instanceof Lang.String)) {
            continue;                                            // 字段缺失或类型不符
        }

        var text = priceText(price);                             // 服务端已定好小数位
        if (text == null) {
            continue;                                            // 价格既不是字符串也不是数字
        }

        rows.add((symbol as Lang.String) + ": " + text);
    }

    return rows;
}
```

配套的三处改动：

| 改动 | 作用 |
| --- | --- |
| `onUpdate()` 改为遍历 `rows` 逐行 `drawText` | 行数 1~3 都能正确渲染，不再有 `[0]/[1]/[2]` |
| 价格改为服务端下发**字符串**，客户端只拼接 | 原来靠"第 3 个币种用 4 位"这种位置约定，加一个币种就全乱；后来发现在客户端格式化本身有精度问题（见第六节） |
| `rows.size() == 0` 时显示 `No Data` | 数据到了但结构不对，不再画一片空白 |

> 这段代码后来改过两次：先是 `price instanceof Lang.Number` 判类型，编译期零警告但真机一直 `No Data`（第五节）；再之后客户端彻底不再做数值格式化，改为直接显示服务端下发的字符串（第六节）。上面的写法是最终形态。

**两个附带收益**：

- 行数不足 3 时整体下移半个行高，价格块保持垂直居中；
- 编译器警告从 14 条降到 5 条——因为 `drawText` 的实参不再是 `Any`，`Cannot determine if container access is using container type` 一类推断警告随之消失。

> 注意：这只解决了"结构异常不崩溃"。网络失败仍会停在 `Loading...`（见第 6 条），因为 `hasData` 与"是否超时"没有区分。

### 5. ✅ 坐标写死（已修复）

```monkey-c
// 修复前
dc.drawText(dc.getWidth()/2 + 56, dc.getHeight()/2 - 68, ...)  // "TT"
dc.drawText(dc.getWidth()/2 - 16, dc.getHeight()/2 - 50, ...)  // "- Coin -"
var top = dc.getHeight()/2 - 20 + (MAX_ROWS - rows.size()) * ROW_HEIGHT / 2;
```

`+56 / -16 / -68 / -50 / 30` 全部是按 176×176 试出来的，换机型（如 240×240 的 fenix 系列）会明显偏位。

**修复**：以 176×176 为设计基准（`REF_WIDTH` / `REF_HEIGHT`），所有偏移改成常量语义值，绘制时按实际屏幕宽高**等比例缩放**：

```monkey-c
const REF_WIDTH = 176;
const REF_HEIGHT = 176;

const TT_DX = 56;      // "TT" 角标相对水平中心的偏移
const TT_UP = 68;      // "TT" 角标相对垂直中心的偏移
const SUB_DX = 16;     // 副标题相对水平中心的偏移
const SUB_UP = 50;     // 副标题相对垂直中心的偏移
const BLOCK_UP = 20;   // 价格块首行相对垂直中心的偏移
const REF_ROW = 30;    // 参考行距

// onUpdate 里
var rowH = h * REF_ROW / REF_HEIGHT;
dc.drawText(cx + w * TT_DX / REF_WIDTH, cy - h * TT_UP / REF_HEIGHT, ...);
```

要点：

- `w * n / REF_WIDTH` 从左到右结合（先乘后除），整数运算不丢精度；176×176 上所有换算结果与旧版**逐像素一致**，真机看不出任何变化；
- 240×240 换算后角标 (196, 28)、行距 40、首行 y=93，比例关系与 176 完全相同；
- 行距跟随屏幕高度缩放后，`MAX_ROWS` 行文本在 taller/wider 的屏上依然保持原有密度。

**遗留**：这只是矩形屏的比例适配。圆屏（弧边会裁掉左上角）需要 `resources-round/` 资源目录留白，或改用 layout.xml + Drawable 的标准做法——见方案对比（本节上方）。

### 6. ✅ 无错误状态（已修复）

```monkey-c
// 修复前
if (!hasData || marketData == null) {
    dc.drawText(..., "Loading...", ...);
    return;
}
```

请求失败后 `hasData = false`，界面回到 `Loading...` 并**永远停在那里**，用户无法区分"正在加载"和"已经失败"。

**修复方式**：把布尔量 `hasData` 换成显式状态常量 + 一句副标题文案，绘制时按"有无可显示数据 × 当前状态"两个维度分支：

```monkey-c
const STATE_LOADING = 0;
const STATE_OK = 1;
const STATE_ERROR = 2;

var state as Lang.Number = STATE_LOADING;
var subtitle as Lang.String = "- Coin -";
```

| 显示 | 触发条件 |
| --- | --- |
| `Loading...` | 无数据 + `STATE_LOADING` |
| `No Net` | 无数据 + `STATE_ERROR`（请求失败且无缓存） |
| `No Data` | 无数据 + `STATE_OK`（响应到了但结构不对） |
| `- Coin -` | 有数据且是实时数据 |
| `- Cache -` | 有数据但来自本地缓存 |
| `- Offline -` | 有数据但本次请求失败 |

比"加三个状态枚举"更省事的地方在于：状态只决定文案，绘制逻辑仍然是一条 `rows.size() == 0 ?` 分支，没有把 UI 拆成三套。

### 7. ✅ Timer 未释放（已修复）

```monkey-c
// 修复前：initialize 里起表，从不停止
timer = new Timer.Timer();
timer.start(method(:onTimer), 60000, true);
```

Widget 被反复进出时，旧定时器可能仍在运行并回调已失效的 View。

**修复方式**：把定时器的生命周期交给 `onShow` / `onHide`，并用 `null` 判断防重入：

```monkey-c
function initialize() {
    View.initialize();
    loadCache();          // 只做缓存恢复，不再发请求
}

function onShow() as Void {
    startTimer();
    fetchPrice();
}

function onHide() as Void {
    stopTimer();
}

function startTimer() as Void {
    if (timer != null) { return; }        // 已在跑，避免重复创建
    timer = new Timer.Timer();
    timer.start(method(:onTimer), REFRESH_MS, true);
}

function stopTimer() as Void {
    if (timer != null) {
        timer.stop();
        timer = null;
    }
}
```

顺带解决了原方案里"首刷放在 `initialize`"的语义问题：Widget 里 `onShow` 才是"被用户看到"的时机，`initialize` 只跑一次，反复进出不会重新拉数据。现在每次进入都会刷新。

### 8. ✅ 无离线缓存（已修复）

断网 / 请求失败时界面完全空白。手表最需要"最后已知价格"。

**修复方式**：成功响应时写入 `Application.Storage`，初始化时先读缓存再发请求。

存储结构刻意用了**两个平行数组**而不是嵌套字典：

```monkey-c
{ "time" => 秒级时间戳, "symbols" => ["BTC", "ETH", ...], "prices" => [101234.5, ...] }
```

原因是 `Application.Storage` 在不同设备 / 固件上对嵌套 Dictionary 的支持存在差异（`ValueType` 白名单），扁平结构最稳，也省空间——三币种大约 120 字节。

写入套了 `try/catch`：

```monkey-c
try {
    Application.Storage.setValue(CACHE_KEY, { ... });
} catch (e) {
    // 存储不可用或配额不足时静默失败：缓存只是锦上添花，不该影响主流程
}
```

否则一旦遇到存储配额满的设备，每次成功抓价都会抛异常，反而把主流程搞崩。

**遗留取舍**：缓存没有过期判断（见 README「已知限制」第 3 条），几天后打开仍会先显示旧价，只能靠副标题 `- Cache -` 区分。加时间戳成本很低，但"过期后显示什么"需要产品决策，暂不处理。

### 9. ✅ `$cacheTime = 1`（已修复）

```php
// 修复前
$cacheTime = 1;
```

1 秒的 TTL 意味着几乎每次手表请求都会穿透到 Binance，缓存只剩"并发去重"作用。

**修复**：改为 10 秒，并补上取值依据的注释（重构后挪到了 `lib.php`，成为常量 `TTCOIN_CACHE_TTL`）。

```php
// 缓存有效期（秒）。
// 手表 60 秒才请求一次，10 秒足够吸收多设备并发与突发重试；
// 若用 cron 预热（update_price.php），cron 间隔应 <= 此值，
// 让手表请求基本都命中缓存、完全不触发上游调用。
define('TTCOIN_CACHE_TTL', 10);
```

原先遗留的 `json_encode()` 失败问题已在第 15 条一并解决：`ttcoin_encode()` 检查返回值，失败时两个入口各自报错，不会再把空内容写进缓存。

### 10. ✅ 两个 PHP 文件逻辑重复（已修复）

`coin.php`（191 行）与 `update_price.php`（104 行）的抓取、解析、校验、写缓存几乎逐行相同，唯一的差异是"读不读缓存"和"输出 JSON 还是日志"。改一次币种要同步动三处：`$symbols`、完整性校验、`$result`。

**修复方式**：抽出 `api/lib.php`，两个入口变成薄壳。

| 函数 | 职责 |
| --- | --- |
| `ttcoin_symbols()` | 币种表（Binance 符号 → 显示简称），**唯一需要改的地方** |
| `ttcoin_fetch($t, $ct)` | 请求 + 解析 + 校验，返回 `['ok'=>bool,'data'=>array,'error'=>string]` |
| `ttcoin_cache_file()` | 缓存路径解析（含不可写时的回退） |
| `ttcoin_cache_read($maxAge)` | 读缓存；`$maxAge = null` 表示不检查年龄 |
| `ttcoin_cache_write($json)` | 写缓存，失败静默 |
| `ttcoin_encode($data)` | 统一 `json_encode` 参数，失败返回 `null` |

行数变化：

```
coin.php           191 → 53
update_price.php   104 → 33
lib.php             —  → 201
```

总量减少了约 8 行，但**重复的 90% 消失了**——两个入口现在只剩下"缓存策略 + 输出方式"的差异，读一遍就能看出各自在做什么。以后加币种只改 `ttcoin_symbols()` 一处，`$result` 的拼装由 `foreach` 自动完成，不再需要三处同步。

顺带把 `update_price.php` 的失败路径改成 `exit(1)`：原来只是 `echo` 一行日志就 `exit`（退出码 0），cron 邮件和监控都看不出失败。

### 11. ✅ 缓存文件在 Web 根目录（已修复）

`coin_cache.json` 与 `coin.php` 同级，可被外网直接 `GET`：虽无敏感信息，但绕过了接口逻辑，还把抓取节奏变成了公开信息。

**修复**：默认写 `<站点目录>/../cache/coin.json`，加三层防护：

```php
$dir = dirname(__DIR__) . '/cache';

if (!is_dir($dir)) {
    @mkdir($dir, 0755, true);
}

if (is_dir($dir) && is_writable($dir)) {
    $file = $dir . '/coin.json';
} else {
    $file = __DIR__ . '/coin_cache.json';   // 父目录不可写时回退
}
```

1. **位置**：移出站点目录，直接 `GET /coin.php` 的兄弟路径访问不到；
2. **`cache/.htaccess`**：`Require all denied`，兼带 Apache 2.2 的 `Order allow,deny` 分支；
3. **`api/.htaccess`**：`FilesMatch` 拒绝 `coin_cache.json` 与 `lib.php`，覆盖"回退到站点目录"的情况。

为什么保留回退而不是硬失败：不少虚拟主机的站点目录就是用户家目录根（`~/public_html`），父目录 `~` 未必可写。这种情况下让插件继续能跑，比坚持一个更好的目录结构更重要——`.htaccess` 已经把这个折衷的风险压到最低。

`.gitignore` 相应改成 `cache/*` + `!cache/.htaccess`，缓存内容不会进仓库，但目录和防护规则会。

### 12. ✅ `data == null` 无效判断

`data as Lang.Dictionary` 非空标注下 `data == null` 恒为假，异常永远不会命中这个分支。已在第 2 条中改为 `Lang.Dictionary?` 并保留 null 判断（此时它才真的可能成立）。

### 13. ✅ 变量无类型声明

`var timer; var marketData = null; var hasData = false;` 全部补上类型：`var timer as Timer.Timer?`、`var marketData as Lang.Array?`、`var state as Lang.Number`、`var subtitle as Lang.String`。成员类型确定后，`-l 1/-l 2` 的警告从 15 条降到 0 / 2。

### 14. ✅ `layout.xml` 空模板残留（已修复）

```xml
<layout id="MainLayout">

</layout>
```

全项目没有一处引用 `MainLayout`——视图是纯 `drawText` 画的。留着只会让读代码的人以为有 XML 布局参与渲染，每次改界面都得先去确认一遍"这个到底用不用"。

已删除 `resources/layouts/layout.xml` 及空目录 `resources/layouts/`，编译验证仍然 `BUILD SUCCESSFUL`。

### 15. ✅ 未校验 `price` 是否为数字（已修复）

```php
// 修复前：上游给什么就转什么
$prices[$item['symbol']] = (float)$item['price'];
```

`(float)` 对 `'abc'` 得到 `0.0`、对 `'1e400'` 得到 `INF`、对 `'NaN'` 得到 `NAN`。后面两个会让 `json_encode()` 返回 `false`（旧代码没检查返回值），最终把**空内容写进缓存文件**，手表端则表现为一直 `No Data`。

**修复**：不再转 `float`，改成"能格式化成可显示文本才收"，非法值直接跳过该条：

```php
$display = ttcoin_format_price($item['price']);

if ($display === null) {
    continue;                       // 'NaN' / 'INF' / '' / 'abc' / 对象
}

$prices[$item['symbol']] = $display;
```

`ttcoin_format_price()` 内部先用 `/^-?\d+(\.\d+)?$/` 匹配常规十进制字面量，按字符串逐位处理；不匹配的再走 `is_numeric()` + `is_finite()` 兜底（`'1e400'` 是合法数字字面量，但会溢出成 `INF`，用 `number_format` 之后仍得到有限值才会被接受）。

顺带完成的另一件事：**`price` 从数字改成了字符串**。原来看起来只是"校验变严"，实际上顺手解决了客户端小数位失真——见第六节。同时 `ttcoin_encode()` 检查 `json_encode` 的返回值，编码失败返回 `null`，两个入口各自报错而不再写脏缓存（第 9 条里"`json_encode()` 失败"那个遗留项也就关了）。

---

## 三、发布前 Checklist

- [x] 补充 `README.md`（含部署、接口约定、排错）
- [x] 补充 `.gitignore`（排除 `bin/`、`*.der`、服务端缓存）
- [ ] **把 `PRICE_API` 换成占位符，并确认仓库中没有你的真实域名**
- [x] 修掉 `onReceive` 的类型标注（第 2 条）
- [x] 修掉硬编码数组索引，改为遍历 + 逐条校验（第 4 条）
- [x] 补错误状态提示（第 6 条）
- [x] Timer 改由 onShow/onHide 管理（第 7 条）
- [x] 加 Application.Storage 本地缓存（第 8 条）
- [x] 服务端缓存 TTL 1s → 10s（第 9 条）
- [x] 抽出 `api/lib.php`，消除两个入口的重复逻辑（第 10 条）
- [x] 缓存移出 Web 根目录 + `.htaccess` 兜底（第 11 条）
- [x] 删除空的 `layout.xml` 模板（第 14 条）
- [x] 校验 `price` 为数字且有限（第 15 条）
- [x] 布局坐标改为按屏幕比例缩放，176×176 上逐像素一致（第 5 条）
- [ ] 确认 `git status` 里没有 `bin/`、`*.der`、`cache/coin.json`
- [ ] 确认 `cache/.htaccess` 与 `api/.htaccess` 已随提交进入仓库（`.gitignore` 里有 `!cache/.htaccess` 例外）
- [x] 补 `LICENSE`（PolyForm Noncommercial 1.0.0，署名 TTCoin contributors；1.0.2 由 MIT 收紧为禁止商用）
- [ ] 加真机截图到 `docs/screenshot.png`（README 已预留注释位）
- [ ] 仓库 About 填一句描述 + Topics：`garmin` `connect-iq` `monkey-c` `crypto` `widget`

```bash
# 建议的首次提交
git init
git add .
git status          # ← 先看这里，确认没有敏感文件
git commit -m "feat: TTCoin widget for Garmin Instinct 2X"
git branch -M main
git remote add origin https://github.com/hh1949tt/TTCoin_Widget.git
git push -u origin main
```

## 四、可以做的后续增强

1. **Glance 支持**：实现 `WatchUi.GlanceView`，让价格出现在小工具列表中，不用点进去。
2. **24h 涨跌**：把接口换成 `/api/v3/ticker/24hr`，多返回一个 `changePercent` 字段，用 `▲/▼` 表示（注意 MIP 屏无彩色，需用符号而非颜色）。
3. **多币种配置**：设备端用 `Properties` 存币种列表，通过 Garmin Connect 的 App Settings 修改。显示层已就绪：超过 3 个币种自动按页轮播（`PAGE_MS` 8 秒/页，副标题带页码），加币种仍只需改 `ttcoin_symbols()` 一处。
4. **多源容灾**：`coin.php` 里 Binance 失败时回退 OKX / Coinbase。

---

## 五、踩坑记录：Monkey C 的数值类型不是继承关系

这一条是实测踩出来的，`-l 1` 编译期**完全不会报错**，只在真机上表现为"一直 No Data"。

**错误写法**（曾经出现在 `buildRows()` / `saveCache()` / `loadCache()` 里）：

```monkey-c
if (!(price instanceof Lang.Number)) { continue; }   // ← 恒为 true，全部被跳过
```

**原因**：Monkey C 里 `Number` / `Float` / `Double` / `Long` 是四个**平级**类型，全部直接继承 `Lang.Object`，彼此没有任何继承关系。查 SDK 文档的 Inherits 字段即可确认：

| 类型 | 文档中的 Inherits | 含义 |
| --- | --- | --- |
| `Lang.Number` | `Toybox.Lang.Object` | 32 位有符号整数 |
| `Lang.Float` | `Toybox.Lang.Object` | 32 位浮点 |
| `Lang.Double` | `Toybox.Lang.Object` | 64 位浮点 |
| `Lang.Long` | `Toybox.Lang.Object` | 64 位整数 |

而 JSON 解码出来的价格是 `Float` / `Double`（32 位的 `Number` 存不下 `0.2311` 这种小数），所以 `instanceof Lang.Number` 永远为 `false`，每一条行情都被判为"非法"跳过 → `rows` 恒为空 → 状态却是 `STATE_OK` → 界面显示 `No Data`。

**正确写法**：显式覆盖四种类型，再统一转 `Float`：

```monkey-c
function isNumeric(value as Lang.Object?) as Lang.Boolean {
    return value instanceof Lang.Number
        || value instanceof Lang.Float
        || value instanceof Lang.Double
        || value instanceof Lang.Long;
}

function numericToFloat(value as Lang.Object?) as Lang.Float? {
    if (value instanceof Lang.Double) { return (value as Lang.Double).toFloat(); }
    if (value instanceof Lang.Float)  { return value as Lang.Float; }
    if (value instanceof Lang.Long)   { return (value as Lang.Long).toFloat(); }
    if (value instanceof Lang.Number) { return (value as Lang.Number).toFloat(); }
    return null;
}
```

**同类陷阱**：`Lang.String` 与 `Lang.Char` 也是平级关系，用 `instanceof Lang.String` 判断"是不是文本"时，`Char` 会漏掉；`Lang.Dictionary` 与 `Lang.Array` 同理（这也是 SDK 把 `makeWebRequest` 回调声明成 `Dictionary or String or Iterator` 却永远匹配不上 Array 的根源）。

---

## 六、踩坑记录：Float 是 32 位，价格不要在手表端格式化

现象：BTC 实际 `75678.78`，表上画出 `75678.7812`；ETH 实际 `2235.51`，画出 `2235.51`（正常）；DOGE 实际 `0.07161`，画出 `0.0716`（正常）。看起来像"只有大数字出错"。

**原因不是四舍五入，是存储精度。** Monkey C 的 `Float` 是 32 位 IEEE-754，尾数 24 位，大约只有 7 位有效数字。`75678.78` 需要 9 位有效数字，落进 float32 会变成：

```
75678.78  →  float32  →  75678.78125
```

可以手算验证：`75678.78` 落在 `[2^16, 2^17)` 区间，该区间 float32 的间隔是 `2^16 × 2^-23 = 0.0078125`；`75678.78 / 0.0078125 ≈ 9686883.84`，取最近的整数得到 `9686884 × 0.0078125 = 75678.78125`。再 `format("%0.4f")` 自然输出 `75678.7812`——后两位是纯噪声，跟真实价格无关，靠"去掉末尾 0"是去不掉的（它们不是 0）。

`-l 0/1/2` 全程不会报任何警告：类型正确、语法正确，只是数值本身已经被截断。

**修复：小数位在服务端定，客户端只显示字符串。**

`api/lib.php` 的 `ttcoin_format_price()` 全程用字符串 / 整数运算：

| 步骤 | 例子 |
| --- | --- |
| 拆成符号、整数、小数三段 | `0.07161000` → `''`, `0`, `07161000` |
| 去掉小数尾部 0 | `07161000` → `07161` |
| 超过 4 位才四舍五入：看第 5 位 | `07161` 第 5 位是 `1` → 不进位 |
| 截到 4 位，再清一次尾零 | `0716` → `0.0716` |

需要进位时把"整数部分 + 前 4 位小数"拼成一个整数串，末位 `+1` 处理连续进位（`9.99999 → 10`、`0.99995 → 1`），最后按固定宽度切回整数与小数。整数位数加 4 位小数最多 12 位，`int` 完全够用。

客户端 `TTCoinView.mc` 的 `priceText()` 只做三件事：是 `String` 就直接返回；是 `Double`（64 位，精度足够）才 `format("%0.4f")` 兜底；其余返回 `null` 让该行被跳过。`Float` 分支故意不提供——它正是问题的来源。

**通用结论**：Monkey C 里凡是"必须精确显示"的数值（价格、距离、金额），一律以字符串传递。`Float` 只适合做比较、做进度条这类允许误差的场合。

---

## 七、多交易对的显示：自动轮播

Widget **不支持按键输入**（这是 Connect IQ 的形态限制，不是代码问题），所以"手动翻页"在 Widget 里做不到，只有两条路：压缩行距塞满一屏，或定时轮播。本项目选择后者，保持每屏 3 行的字号与呼吸感。

### 实现

| 常量 | 值 | 作用 |
| --- | --- | --- |
| `PAGE_ROWS` | 3 | 每屏行数 |
| `PAGE_MS` | 8000 | 每页停留时长 |
| `FETCH_TICKS` | 8 | 每 N 拍抓一次行情（8 × 8s ≈ 64s） |

关键取舍：**轮播和抓取共用一个 Timer**。Timer 每 8 秒走一拍，多数拍只翻页 + `requestUpdate()`，每逢第 8 拍才发 HTTP 请求——避免了第二个定时器实例，也把刷新节奏从固定 60 秒变成约 64 秒（对行情场景无感知差异）。

行为矩阵：

| 币种数 | 页数 | 显示 |
| --- | --- | --- |
| 1~3 | 1 | 一屏显示完，不翻页 |
| 4~6 | 2 | 每 8 秒翻页 |
| 7~9 | 3 | 同上 |
| N | ⌈N/3⌉ | `pageIndex = (pageIndex + 1) % ⌈N/3⌉` |

> 页码（`1/2` 这种）在第八节里被去掉了，理由见那一节：左上角空档放不下、翻页时标题长度还会变。

`buildRows()` 不再截断到 3 行（返回全部合法行），截断职责移到 `onUpdate()` 的按页切片。币种减少导致页码越界时，`pageIndex >= pages` 分支回卷到首页，不会画出空页。

### 已知代价（如实记录）

1. **Widget 生命周期短**：进入小工具页几秒后就被系统回收，8 秒/页的轮播多数时候翻不到第二页。轮播对"停留较久"的场景（抬腕不放下）才真正有意义。
2. **翻页瞬间会整屏重绘**：`requestUpdate()` 触发的 `onUpdate` 会重画全部元素，MIP 屏上可能看到轻微闪烁。若介意，可改成只请求局部更新（`requestUpdate()` 无局部参数，需用 `WatchUi.requestUpdate` 之外的低层 API，收益不大）。
3. 需要**按键手动翻页 / 菜单选币种**时，唯一出路是把项目改成 Watch App（`manifest` 的 `type` 从 `widget` 改 `app`，生命周期与入口全部重做）。


## 八、翻页后只剩屏幕最下沿半行字：行位移用了绝对下标

### 现象

真机截图：第一页正常，第二页整块消失，只有屏幕最底部露出半截字；副标题还挂着 `2/4`。

### 根因

`onUpdate()` 里按页切片后是这么算行位置的：

```monkey
for (var i = start; i < end; i++) {
    drawRow(dc, cx, top + i * rowH, rows[i]);   // ❌ i 是绝对下标
}
```

`i` 是**绝对**下标，第一页 `start = 0` 时恰好等价于相对下标，所以第一页看不出问题；第二页 `start = 3`，每一行都被多推 `3 × rowH = 90px`，`top + 90` 已经落在 176px 屏幕之外，只剩 `top + 3 × rowH ≈ 158` 那一行的字头露在窗口下沿。

正确写法（与 App 版一致）：

```monkey
drawRow(dc, cx, top + (i - start) * rowH, rows[i]);   // ✅ 相对下标
```

这个 bug 只在"有多页"时才暴露：币种 ≤ 3 个时 `start` 恒为 0，怎么看都是对的。所以第一版自测（3 个币种）没发现，服务端加到 10 个币种上真机就现形了。

### 顺带修掉的两件事

1. **页码去掉**：八边形左上角的空档宽度只够放 `- Coin -`，再拼 `2/4` 就会顶到灯孔外环；单独占一行又会把首行行情往下推。轮播本身就是每 8 秒自动翻，页码对看表的人是噪音。
2. **行字体从 `FONT_GLANCE_NUMBER` 换成 `FONT_MEDIUM`**：`FONT_GLANCE_NUMBER` 是给 glance 用的超大号数字，字面接近 40px，三行根本塞不进灯孔下沿到八边形斜边之间那段 ~84px 的有效高度。换成 `FONT_MEDIUM`（字面 16px、cell 31）后，三行按 26px 行距排，字面落在 82..97 / 108..123 / 134..149，都在可用宽度内。

### 版式依据（逐像素量真机截图得到）

八边形窗口在各高度的可用宽度：

| screen y | 可用宽度 |
| --- | --- |
| 80 ~ 130 | 176（整宽） |
| 136 | 172 |
| 144 | 162 |
| 152 | 148 |
| 160 | 134 |

所以：首行 `ROW_TOP = 75`（再往上会被灯孔外圈压住，见第九节）、`ROW_PITCH = 26`、单行上限 `MAX_ROW_W = 150`（第三行字面到 149，此时宽度还有 154，留 2px 余量）。

另外新增 `chooseRowFont()`：整页最宽的一行 + 箭头仍放不下时，整页降到 `FONT_SMALL`，再放不下用 `FONT_TINY`，避免长价格顶出斜边。这一条与 App 版的 `choosePriceFont()` 同思路，只是 Widget 里每行只有一句文本，判断更简单。


## 九、首行的末位小数被手电筒灯孔外圈"啃"掉

### 现象

真机截图：三行行情里第一行最右边的末位小数和涨跌箭头，被右上角那个装着"TT"的圆的下边缘压住一角，看着像数字缺了一块；第二、三行完全正常。

### 根因

灯孔不是只有一个 r=31 的可绘圆。屏幕坐标系里它实际是三层：

| 层 | 半径 | 说明 |
| --- | --- | --- |
| 内部可绘圆 | r≈31 | 唯一能画字的区域（"TT"就放这里，圆心约 (144, 32)） |
| 金属环带 | 31→37 | 画不上东西，但**不遮挡**已有内容 |
| 凸起外圈（表壳） | 约到 r≈43 | 实体遮挡，下沿到 **y≈75**，在 y 71..75 这段横跨 x≈127..161 |

上一版的 `ROW_TOP = 64` 让首行字面落在 71..86，右半边（末位小数 + 箭头，x 到 152 左右）正好撞在 y 71..75、x 127..161 这块外圈上——**只有第一行的右端会中招**，所以看起来像"排版没对齐"，实际上是几何遮挡。

### 修复

首行 cell 下移到 75（字面 82..97，离外圈下沿留 6px），行距从 28 收到 26，三行整体落 82..97 / 108..123 / 134..149：

- 首行右端 x≈149，此时 y≥82 已经在外圈之外，末位小数和箭头都露得出来；
- 末行字面到 149，八边形在此处还有 154px 可用宽度（实测剖面：y 148→156、y 152→148），所以把 `MAX_ROW_W` 从 158 收到 150，保证最长的一行（如 `BTC: 756078.49 ▶`）也不会被下斜边切到；
- 行距收 2px 后三行仍在 82..149 这段 67px 里铺满，视觉密度和之前基本一致。

### 怎么量出来的

模拟器 1:1 渲染（176 逻辑像素 = 176 截图像素），逐行扫非黑像素得到外圈下沿：y 70 时 x 125..162、y 72 时 x 129..158、y 74 时 x 137..150、y 75 之后归零——外圈底部就在 x≈144、y≈75。改完后再扫文字带，首行 82..97、末行 134..149，与设计值逐像素一致。

## 十、首行的箭头整个不见了：一刀切的宽度上限

### 现象

真机截图：`10000*SHIB: 0.0447` 这一行只有价格、没有涨跌箭头，下面 `SOL: 89.33 ▼`、`BNB: 695.43 ▲` 两行都正常。箭头不是被裁掉半截，是**完全没画**。

### 定位

按 1:1 扫截图（屏幕区 x99..274、y164..339，正好 176×176）得到三行的白色像素范围：

| 行 | x 范围 | 宽度 | 中心 |
| --- | --- | --- | --- |
| `10000*SHIB: 0.0447` | 15..160 | 146 | 87.5 = cx |
| `SOL: 89.33 ▼` | 49..139 | 91 | 94 ≈ cx+6 |
| `BNB: 695.43 ▲` | 44..144 | 101 | 94 ≈ cx+6 |

第一行中心正好在 cx（说明只画了文本、文本居中）、没有箭头；后两行中心偏右 6px（文本居中后箭头挂右侧）。宽度 146 + 间距 4 + 箭头 7 = 157 > 旧的 `MAX_ROW_W = 150`，`drawRow()` 里"放不下就只画价格"的分支直接 return —— 和观测完全对上。

### 根因（两层）

1. **宽度上限是个常数 150，但八边形的可用宽度随 y 变化**：首行字面落在 82..97，这里是八边形直边段，有整整 176px；末行 134..149 才收到约 154px。用一个 150 卡所有行，首行明明放得下也被判超宽。
2. **排版方式把文本居中、箭头往右挂**：即使箭头画出来，长行右端也会越过斜边；而"超宽就 return"的判断又把箭头整个吞掉，于是表现为"只有首行缺箭头"。

小额价格放大（`10000*SHIB`）把显示名从 4 个字符拉到 5 个字符 + 5 位倍数，`SHIB: 0.00000448` 变成 `10000*SHIB: 0.0447`，正好把行宽顶过 150 —— 之前 3 个币种自测发现不了，因为最长的 `BTC: 756078.49` 是 14 字符。

### 修复

- 新增 `rowLimit(dc, cellY, font)`：按"文本带下沿"落在剖面表的哪一段取宽度（176 / 172 / 162 / 156 / 148，再减去 `EDGE_MARGIN = 4`），上限 `MAX_ROW_W` 从 150 放到 168（只作为总闸，不再卡首行）；
- `drawRow()` 改为**文本 + 箭头作为一个整体居中**：`left = cx - (tw + gap + arrowW) / 2`，箭头接在 `left + tw + gap`。这样长行整体左移，`10000*SHIB: 0.0447`（146 + 11 = 157）落在 x 9.5..166.5，两侧各留 9px；
- `chooseRowFont()` 改成逐行判断：每行用自己那一行的 `rowLimit` 检查"文本 + 箭头"，全部通过才用这个字号。原来是取全页最大宽度统一卡，会为了照顾末行把首行也一起降档。

### 验证

- 8.1.0 与 9.2.0 两个 SDK `-l 2` 编译通过，新增无告警（仍只有既有的 poly type 5 条）；
- 算式核验（用截图实测的字宽）：首行 146 + 4 + 7 = 157 ≤ 168 ✓，箭头落在 160..167，屏宽 176 内，行内 y 81..93 早已在灯孔外圈（下沿 75）之下；
- 短行视觉上会整体左移约 5px（箭头宽的一半），比"文本居中、箭头外挂"更对称，属于预期变化；
- ⚠️ 本轮模拟器部署失败：`monkeydo` 报 `Unable to connect to simulator.`，`1234` 端口 `LISTENING` 但 loopback 连接被拒（`netstat` 有 socket、`connect` 报 10061），与之前 Hyper-V/WinNAT 保留端口那次同源，需要管理员 `net stop winnat && net start winnat` 后重试，故未取到本轮真机截图。

## 十一、两个 .prg 都装进手表，却只显示 Widget

### 现象

`TTCoin.prg`（watch-app）和 `TTCoinWidget.prg`（widget）一起装机，手表应用列表里找不到 TTCoin，小工具列表里却有；或者反过来——**永远只剩后装的那一个**。

### 定位

两个项目的 `manifest.xml` 里 `iq:application@id` 完全相同：

```
TTCoin_APP/manifest.xml     id="1d087cf1-27ae-4c64-a653-42e113497d07"  type="watch-app"
TTCoin_Widget/manifest.xml  id="1d087cf1-27ae-4c64-a653-42e113497d07"  type="widget"
```

Widget 工程是从 App 工程复制出来的（只改了 `type` 和源码），id 一起被复制了过来。

Connect IQ 的 `id` 是**应用身份**，不是"项目"身份：设备上一条记录 = 一个 id，`type` 只是这条记录的属性。装第二个同 id 的 `.prg` 时，系统认定"这个应用要升级"，于是替换掉原记录、连同 `type` 一起改写。结果就是后装的形态吃掉先装的形态——App 列表里没了，或者小工具列表里没了。**没有任何报错**，症状很像"安装失败"或"没装进去"。

另一个连带问题：两边 `AppName` 都叫 `TTCoin`，即使 id 分开了，在列表里也分不清哪个是哪个。

### 修复

1. `TTCoin_Widget/manifest.xml` 换成独立 id `e8dab0f9-d9a8-4ef5-8bab-fd05bcf135f5`（新生成的 UUID v4），并在文件里加注释说明**不得与 App 相同**；
2. `TTCoin_Widget/resources/strings/strings.xml` 的 `AppName` 改为 `TTCoin Widget`，App 保持 `TTCoin`；
3. 两个工程都重新编译（改 id / 改资源都要重编，`.prg` 里的 id 是编译期写死的）。

### 验证

id 确实进了产物——直接按字节在 `.prg` 里找 UUID：

```bash
python - TTCoin_APP/bin/TTCoin.prg TTCoin_Widget/bin/TTCoinWidget.prg <<'PY'
import sys
for p, hexs in [(sys.argv[1], '1d087cf127ae4c64a65342e113497d07'),
                (sys.argv[2], 'e8dab0f9d9a84ef58babfd05bcf135f5')]:
    print(p, 'HIT' if bytes.fromhex(hexs) in open(p, 'rb').read() else 'MISS')
PY
```

实测：`TTCoin.prg` 只含旧 id、`TTCoinWidget.prg` 只含新 id，交叉为零，说明不是"改在源码里、编出来还是旧值"。

### 已装过旧版本的表怎么清

旧 Widget 是以旧 id 存进去的，现在这个 id 要留给 App 用。最稳的顺序：

1. 手表 `设置 → 应用`（或长按 MENU 进应用/小工具列表）删掉现有的 TTCoin 条目；
2. 分别安装新的 `TTCoin.prg` 与 `TTCoinWidget.prg`；
3. 应用列表应出现 **TTCoin**，小工具列表应出现 **TTCoin Widget**。

如果只装新的不删旧的，会出现"App 和小工具各一条、其中一条是旧版本残留"的假象。
