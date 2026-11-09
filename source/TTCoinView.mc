using Toybox.WatchUi;
using Toybox.Graphics;
using Toybox.Communications;
using Toybox.System;
using Toybox.Application;
using Toybox.Time;
using Toybox.Timer;
using Toybox.Lang;

class TTCoinView extends WatchUi.View {

    // 与 Watch App 版共用同一个接口（老地址 /coin.php 是旧版，不下发 change
    // 字段，画不了涨跌箭头）
    const PRICE_API = "https://api.example.com/ttcoin/api/coin.php";

    const PAGE_ROWS = 3;     // 一屏显示几行行情
    const PAGE_MS = 8000;    // 轮播间隔：币种超过一屏时每页停留时长

    // 布局基准：所有间距 / 偏移以 176×176（Instinct 2X）为参考设计，
    // 绘制时按实际屏幕宽高等比例缩放，换到 240×260 等矩形屏自动适配，
    // 不用再改代码。在 176×176 上换算结果与旧版逐像素一致。
    const REF_WIDTH = 176;
    const REF_HEIGHT = 176;

    const TT_DX = 56;        // "TT" 角标相对水平中心的偏移（落进手电筒灯孔）
    const TT_UP = 68;        // "TT" 角标相对垂直中心的偏移
    const SUB_DX = 16;       // 副标题相对水平中心的偏移（轻微左移是故意的）
    const SUB_UP = 50;       // 副标题相对垂直中心的偏移

    // 时钟：画在副标题正上方，与 "- Coin -" 共用同一条垂直轴（同 SUB_DX）。
    // 副标题 cell 顶部在 cy-50，字体高约 21px（字面 43..57），
    // 时钟 cell 顶部取 cy-76（字面 17..31），和副标题留 6px 空隙。
    // 再往上就顶到八边形左上斜边（x+y=39.6）与手电筒灯孔外环了。
    const CLOCK_UP = 76;

    // 行情行：Instinct 2X 的八边形窗口实测宽度剖面（screen y → 可用宽度）：
    //   y 80..130 → 176（整宽）  y 144 → 162   y 148 → 156   y 152 → 148
    //
    // 上方还有一个必须让开的圆：手电筒灯孔的凸起外圈（屏幕坐标圆心约
    // (144, 32)、半径约 43），它的下沿到 y≈75 为止，在 y 71..75 这段横跨
    // x≈127..161。首行如果从 y=64 起排（字面 71..86），右半边的末位小数
    // 和箭头正好压在这个外圈的左下弧上——真机看就是"数字被圆圈啃掉一块"。
    // 所以首行 cell 下移到 75（字面 82..97，离外圈下沿留 6px 空隙），
    // 行距收到 26，三行字面落在 82..97 / 108..123 / 134..149。
    const ROW_TOP = 75;      // 首行 cell 顶部（再往上第一行会蹭到手电筒外圈）
    const ROW_PITCH = 26;    // 行距

    // 涨跌方向箭头（手绘三角，紧跟在行情文本右侧）
    const ARROW_W = 7;       // 参考宽（176 基准）
    const ARROW_H = 6;       // 参考高
    const ARROW_GAP = 4;     // 文本与箭头的间距

    // 一行（文本 + 箭头）能占多宽，**按行算**，不是一个固定值。
    // 八边形窗口的宽度随 y 变化（176 基准，取"文本带下沿"处最窄的宽度）：
    //   y <= 130 → 176    y 136 → 172    y 144 → 162    y 148 → 156    y 152 → 148
    // 首行字面 82..97 有整宽可用；末行 134..149 只剩约 154。
    // 旧的 150 一刀切让首行"10000*SHIB: 0.0447"（宽 146）被判超宽，
    // drawRow 直接 return，箭头整个消失 —— 见 rowLimit()。
    const EDGE_MARGIN = 4;   // 斜边是渐变的，贴着边看太挤，再收一点
    const MAX_ROW_W = 168;   // 任何行都不超过这个宽度（176 基准）

    // 轮播与抓取共用一个 Timer：每 PAGE_MS 走一拍，
    // 每 FETCH_TICKS 拍真正发一次行情请求（8 × 8s ≈ 64s），
    // 中间的拍只用来翻页，不再需要第二个定时器实例。
    const FETCH_TICKS = 8;

    // v3：缓存结构里多了 changes 平行数组（涨跌方向），旧键自然失效
    const CACHE_KEY = "ttcoin_cache_v3";

    const STATE_LOADING = 0;   // 还没拿到过任何数据
    const STATE_OK = 1;        // 有数据可显示（可能是缓存）
    const STATE_ERROR = 2;     // 彻底失败，且无任何可显示的数据

    var timer as Timer.Timer?;
    var clockTimer as Timer.Timer?;             // 走时用，1 秒一拍
    var lastMinute as Lang.Number = -1;         // 上次画出来的"分钟序号"，相同就不重绘
    var marketData as Lang.Array? = null;
    var state as Lang.Number = STATE_LOADING;
    var subtitle as Lang.String = "- Coin -";   // 副标题：区分实时 / 缓存 / 离线
    var pageIndex as Lang.Number = 0;           // 当前轮播页码
    var tickCount as Lang.Number = 0;           // Timer 拍数计数（轮播/抓取分频用）

    var requestOptions as Lang.Dictionary = {
        :method => Communications.HTTP_REQUEST_METHOD_GET,
        :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
    };

    function initialize() {
        View.initialize();

        // 先恢复上次成功抓到的价格，避免一进页面就是空白或 Loading
        loadCache();
    }

    // Widget 每次进入小工具页都会走 onShow：
    // 在这里接管"起定时器 + 拉数据"，比放在 initialize 更符合组件语义
    function onShow() as Void {
        startTimer();
        startClock();
        fetchPrice();
    }

    // 离开时必须停掉定时器，否则反复进出会堆积多个 Timer 实例
    function onHide() as Void {
        stopTimer();
        stopClock();
    }

    function onUpdate(dc) as Void {

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();

        // 时钟：与 "- Coin -" 同一条垂直轴，画在它上方。
        // 刻意放在"有没有行情"的判断之前——断网时屏幕中间显示 "No Net"，
        // 顶上照样能看到现在几点，不至于整块界面失去意义。
        dc.drawText(
            dc.getWidth() / 2 - dc.getWidth() * SUB_DX / REF_WIDTH,
            dc.getHeight() / 2 - dc.getHeight() * CLOCK_UP / REF_HEIGHT,
            Graphics.FONT_SMALL,
            clockText(),
            Graphics.TEXT_JUSTIFY_CENTER
        );

        // 记下这一帧画的是哪一分钟，走时定时器据此判断要不要重绘
        lastMinute = minuteKey();

        var rows = buildRows();

        if (rows.size() == 0) {

            // 有数据但全部不合法 → No Data；从未拿到过数据 → No Net；否则仍在加载
            var message = "Loading...";

            if (state == STATE_ERROR) {
                message = "No Net";
            } else if (state == STATE_OK) {
                message = "No Data";
            }

            dc.drawText(
                dc.getWidth() / 2,
                dc.getHeight() / 2,
                Graphics.FONT_SMALL,
                message,
                Graphics.TEXT_JUSTIFY_CENTER
            );
            return;
        }

        // 按实际屏幕尺寸换算所有坐标（w * n / 176 从左到右结合，先乘后除不丢精度）
        var w  = dc.getWidth();
        var h  = dc.getHeight();
        var cx = w / 2;
        var cy = h / 2;

        dc.drawText(cx + w * TT_DX / REF_WIDTH, cy - h * TT_UP / REF_HEIGHT,
            Graphics.FONT_SMALL,
            "TT",
            Graphics.TEXT_JUSTIFY_CENTER);

        // 按页切片：币种超过一屏时只画当前页。
        //
        // 形态上刻意不画 "1/4" 这类页码：八边形窗口的左上角空档很窄，
        // 页码跟副标题挤在一行会顶到灯孔外环，而单独占一行又会把首行行情往下推。
        // 轮播本身每 8 秒自动翻页，页码对看表的人是噪音，直接省掉。
        var total = rows.size();
        var pages = (total + PAGE_ROWS - 1) / PAGE_ROWS;

        if (pageIndex >= pages) {
            pageIndex = 0;                   // 币种减少后页码越界，回到首页
        }

        var start = pageIndex * PAGE_ROWS;
        var end = start + PAGE_ROWS;

        if (end > total) {
            end = total;
        }

        var shown = end - start;

        dc.drawText(cx - w * SUB_DX / REF_WIDTH, cy - h * SUB_UP / REF_HEIGHT,
            Graphics.FONT_SMALL,
            subtitle,
            Graphics.TEXT_JUSTIFY_CENTER);

        // 这一页最宽的一行放不下就整体降一档字体，保证长价格不顶出斜边
        var pitch = h * ROW_PITCH / REF_HEIGHT;

        // 行数不足一屏时整体下移半个行高，保持价格块视觉居中
        var top = h * ROW_TOP / REF_HEIGHT + (PAGE_ROWS - shown) * pitch / 2;

        var font = chooseRowFont(dc, rows, start, end, top, pitch);

        for (var i = start; i < end; i++) {

            // ⚠️ 行位移必须用相对下标 (i - start)。旧的写法用绝对下标 i，
            //    第二页起每行都被多推 (start × pitch) 像素，整块直接画到屏幕外
            //    ——真机上看到的就是"翻页后只剩屏幕最下沿露出半行字"。
            drawRow(dc, cx, top + (i - start) * pitch, font, rows[i] as Lang.Dictionary);
        }
    }

    // 一行的可用宽度上限（像素）。按"文本带下沿"落在八边形的哪一段取宽度：
    // 越靠下的行，斜边收得越厉害。传入的 cellY / 返回的像素宽都按实际屏幕算。
    function rowLimit(
        dc as Graphics.Dc,
        cellY as Lang.Number,
        font as Graphics.FontType
    ) as Lang.Number {

        var w = dc.getWidth();
        var h = dc.getHeight();

        // cellY 是实际像素，先折回 176 基准再对照剖面表
        var bottom = (cellY + dc.getFontHeight(font)) * REF_HEIGHT / h;

        var avail = 140;                     // 比 152 更低：只在异常布局下取到

        if (bottom <= 130) {
            avail = 176;
        } else if (bottom <= 136) {
            avail = 172;
        } else if (bottom <= 144) {
            avail = 162;
        } else if (bottom <= 148) {
            avail = 156;
        } else if (bottom <= 152) {
            avail = 148;
        }

        avail = avail - EDGE_MARGIN;

        if (avail > MAX_ROW_W) {
            avail = MAX_ROW_W;
        }

        return w * avail / REF_WIDTH;
    }

    // 选这一页用的行字体：默认 FONT_MEDIUM（字面 16px，一行三行正好铺满窗口中部）；
    // 只要有一行"文本 + 箭头"放不进它自己那一行的可用宽度，就整体降一档，
    // 再放不下用 FONT_TINY，保证 "BTC: 756078.49 ▶" 这种长价格不会顶出八边形斜边。
    //
    // 逐行判断而不是用全页最大宽度统一卡：首行有 176px 可用、末行只有约 154px，
    // 用同一个上限会为了照顾末行把首行也一起降档（或者反过来，让首行超宽丢箭头）。
    function chooseRowFont(
        dc as Graphics.Dc,
        rows as Lang.Array,
        start as Lang.Number,
        end as Lang.Number,
        top as Lang.Number,
        pitch as Lang.Number
    ) as Graphics.FontType {

        var w = dc.getWidth();

        var gap    = w * ARROW_GAP / REF_WIDTH;
        var arrowW = w * ARROW_W / REF_WIDTH;

        var fonts = [Graphics.FONT_MEDIUM, Graphics.FONT_SMALL];

        for (var f = 0; f < fonts.size(); f++) {

            var font = fonts[f];
            var ok = true;

            for (var i = start; i < end; i++) {

                var text = (rows[i] as Lang.Dictionary)["text"] as Lang.String;
                var cellY = top + (i - start) * pitch;

                var need = dc.getTextWidthInPixels(text, font) + gap + arrowW;

                if (need > rowLimit(dc, cellY, font)) {
                    ok = false;
                    break;
                }
            }

            if (ok) {
                return font;
            }
        }

        return Graphics.FONT_TINY;           // 极端长价格兜底
    }

    // 画一行行情：涨跌方向箭头紧贴在文本右侧，**文本 + 箭头作为一个整体居中**。
    //
    // ⚠️ 不用 "↑"/"↓" 字符：App 版实测过，Garmin 内置位图字体的字符集很小，
    //    ▲/▼（U+25B2/U+25BC）缺字会被画成空心菱形 ◇，↑/↓（U+2191/U+2193）
    //    大概率同样不在字符集里，而且运行时没法检测缺字。干脆用 fillPolygon
    //    手绘三角，尺寸随字体等比缩放，任何设备上都不会缺字。
    function drawRow(
        dc as Graphics.Dc,
        cx as Lang.Number,
        cellY as Lang.Number,
        font as Graphics.FontType,
        row as Lang.Dictionary
    ) as Void {

        var text = row["text"] as Lang.String;
        var tw = dc.getTextWidthInPixels(text, font);
        var up = row["up"];

        // 平盘 / 无涨跌数据：只画行情本身
        if (!(up instanceof Lang.Boolean)) {
            dc.drawText(cx, cellY, font, text, Graphics.TEXT_JUSTIFY_CENTER);
            return;
        }

        var w = dc.getWidth();

        var arrowW = w * ARROW_W / REF_WIDTH;
        var arrowH = w * ARROW_H / REF_WIDTH;
        var gap    = w * ARROW_GAP / REF_WIDTH;

        if (arrowW < 3 || arrowH < 3) {
            arrowW = 3;                      // 极小屏兜底，保证三角还能看见
            arrowH = 3;
        }

        var group = tw + gap + arrowW;

        // 连"文本 + 箭头"都放不进这一行：宁可只画价格，也不把箭头挤到斜边外
        if (group > rowLimit(dc, cellY, font)) {
            dc.drawText(cx, cellY, font, text, Graphics.TEXT_JUSTIFY_CENTER);
            return;
        }

        // 整体居中。旧写法只把文本居中、箭头往右挂：长行右端必然越过斜边，
        // 而"放不下就 return"的判断又把箭头整个吞掉 —— 首行的
        // "10000*SHIB: 0.0447" 就是这么变成没箭头的。
        var left = cx - group / 2;

        dc.drawText(left, cellY, font, text, Graphics.TEXT_JUSTIFY_LEFT);

        var arrowY = cellY + dc.getFontHeight(font) / 2 - arrowH / 2;
        var ax     = left + tw + gap;

        if (up as Lang.Boolean) {
            dc.fillPolygon([
                [ax, arrowY + arrowH],
                [ax + arrowW, arrowY + arrowH],
                [ax + arrowW / 2, arrowY]
            ]);
        } else {
            dc.fillPolygon([
                [ax, arrowY],
                [ax + arrowW, arrowY],
                [ax + arrowW / 2, arrowY + arrowH]
            ]);
        }
    }

    // 把行情数组渲染成待绘制文本行（全部行，不截断；
    // 一屏放不下时由 onUpdate 按页切片轮播）。
    // 服务端返回的条数、字段都不该被信任：这里逐条用 instanceof 校验，
    // 结构不对的条目直接跳过，避免 marketData[0] 这类硬编码索引越界崩溃。
    function buildRows() as Lang.Array {

        var rows = [] as Lang.Array;

        if (!(marketData instanceof Lang.Array)) {
            return rows;
        }

        var list = marketData as Lang.Array;

        for (var i = 0; i < list.size(); i++) {

            var item = list[i];

            if (!(item instanceof Lang.Dictionary)) {
                continue;                    // 不是 {symbol, price} 结构
            }

            var dict = item as Lang.Dictionary;

            var symbol = dict["symbol"];
            var price  = dict["price"];

            if (!(symbol instanceof Lang.String)) {
                continue;                    // 字段缺失或类型不符
            }

            var text = priceText(price);

            if (text == null) {
                continue;                    // 价格既不是字符串也不是数字
            }

            rows.add({
                "text" => (symbol as Lang.String) + ": " + text,
                "up"   => trendUp(dict["change"])
            });
        }

        return rows;
    }

    // 24h 涨跌方向：服务端给的是带符号字符串（"2.3" / "-1.23" / "0"）。
    // 这里只需要方向：负数 → 向下，"0"/空 → 没有方向（不画箭头），
    // 字段缺失或类型不对同样按"没有方向"处理。
    function trendUp(change as Lang.Object?) as Lang.Boolean? {

        if (!(change instanceof Lang.String)) {
            return null;
        }

        var text = change as Lang.String;

        if (text.length() == 0 || text.equals("0")) {
            return null;
        }

        var at = text.find("-");

        return !((at instanceof Lang.Number) && (at as Lang.Number) == 0);
    }

    // 行情文本直接取服务端下发的字符串：
    // 小数位数由服务端按上游 API 的原始位数决定（超过 4 位才四舍五入），
    // 客户端只做拼接，不做任何数值格式化。
    //
    // ⚠️ 为什么不在客户端格式化：Monkey C 的 Float 是 32 位，75678.78 存进去
    //    实际是 75678.78125，format("%0.4f") 会画出 75678.7812 —— 后两位是
    //    精度噪声，跟真实价格无关，去掉尾部 0 也救不回来。Double 是 64 位，
    //    下面这条分支只为兼容"服务端还是旧版、返回数字"的情况。
    function priceText(price as Lang.Object?) as Lang.String? {

        if (price instanceof Lang.String) {

            var text = price as Lang.String;

            return text.length() > 0 ? text : null;
        }

        if (price instanceof Lang.Double) {
            return trimZeros((price as Lang.Double).format("%0.4f"));
        }

        if (price instanceof Lang.Long) {
            return (price as Lang.Long).format("%d");
        }

        if (price instanceof Lang.Number) {
            return (price as Lang.Number).format("%d");
        }

        return null;
    }

    // 去掉小数末尾多余的 0；整数（没有小数点）原样返回，避免 "67000" → "67"
    function trimZeros(text as Lang.String) as Lang.String {

        var dot = text.find(".");

        if (!(dot instanceof Lang.Number)) {
            return text;
        }

        var at  = dot as Lang.Number;
        var end = text.length();

        while (end > at + 1) {

            var ch = text.substring(end - 1, end) as Lang.String;

            if (!ch.equals("0")) {
                break;
            }

            end--;
        }

        if (end == at + 1) {
            return text.substring(0, at) as Lang.String;   // 只剩小数点，一起丢掉
        }

        return text.substring(0, end) as Lang.String;
    }

    // ---------------- 定时器 ----------------

    function startTimer() as Void {
        if (timer != null) {
            return;                          // 已在跑，避免重复创建
        }
        timer = new Timer.Timer();
        timer.start(method(:onTimer), PAGE_MS, true);
    }

    function stopTimer() as Void {
        if (timer != null) {
            timer.stop();
            timer = null;
        }
    }

    // 一拍 = PAGE_MS（8s）：多数拍只翻页，
    // 每 FETCH_TICKS 拍才真正发一次行情请求，维持约 1 分钟的刷新节奏。
    function onTimer() as Void {

        tickCount++;

        if (tickCount % FETCH_TICKS == 0) {
            fetchPrice();
        }

        // 页码推进用 buildRows() 的有效行数，和 onUpdate 的分页口径保持一致
        // （marketData 里可能混有字段不合法的条目，直接数它会让页数偏大）
        var total = buildRows().size();

        if (total > PAGE_ROWS) {
            pageIndex = (pageIndex + 1) % ((total + PAGE_ROWS - 1) / PAGE_ROWS);
            WatchUi.requestUpdate();
        }
    }

    // ---------------- 走时 ----------------

    // 1 秒一拍，但**只有分钟变了才重绘**。
    // 界面只显示 HH:MM，秒数不画；每分钟一次 requestUpdate 连电量都算不上影响，
    // 而如果偷懒不复用这个定时器，分钟跳变最快也要等轮播那 8 秒才会被看见。
    function startClock() as Void {
        if (clockTimer != null) {
            return;
        }
        clockTimer = new Timer.Timer();
        clockTimer.start(method(:onClockTimer), 1000, true);
    }

    function stopClock() as Void {
        if (clockTimer != null) {
            clockTimer.stop();
            clockTimer = null;
        }
    }

    function onClockTimer() as Void {
        // 换分钟了才请求重绘；onUpdate 画完会把 lastMinute 更新成本帧的分钟
        if (minuteKey() != lastMinute) {
            WatchUi.requestUpdate();
        }
    }

    // "距零点多少分钟"，只用来比较是否换分钟，不参与显示
    function minuteKey() as Lang.Number {
        var clock = System.getClockTime();
        return clock.hour * 60 + clock.min;
    }

    // 固定 24 小时制、两位补零：宽度恒定，不会因为 "9:05" / "10:05" 抖动
    function clockText() as Lang.String {

        var clock = System.getClockTime();

        var hh = clock.hour;
        var mm = clock.min;

        var hs = hh < 10 ? "0" + hh.toString() : hh.toString();
        var ms = mm < 10 ? "0" + mm.toString() : mm.toString();

        return hs + ":" + ms;
    }

    // ---------------- 网络 ----------------

    function fetchPrice() as Void {

        // 与 Watch App 版一致：带上设备唯一标识（可选参数），服务端可区分设备。
        // 取不到就不带，服务端当可选值处理。
        var params = {};

        var uid = deviceUid();

        if (uid != null) {
            params.put("uid", uid);
        }

        // 应用形态标记：服务端日志里区分同一块表上的 Widget 版与 APP 版
        params.put("type", "widget");

        Communications.makeWebRequest(
            PRICE_API,
            params,
            requestOptions,
            method(:onReceive)
        );
    }

    // System.getDeviceSettings().uniqueIdentifier（API 2.4.1+）：
    // 同设备 + 本应用恒定、卸载重装不变、跨应用不同；出错/为空返回 null。
    function deviceUid() as Lang.String? {

        var id = null;

        try {
            id = System.getDeviceSettings().uniqueIdentifier;
        } catch (e) {
            id = null;
        }

        if (!(id instanceof Lang.String)) {
            return null;
        }

        return (id as Lang.String).length() > 0 ? id : null;
    }

    // ⚠️ SDK 对 makeWebRequest 回调的类型声明是：
    //    data as Null or Dictionary or String or PersistedContent.Iterator
    //    里面并没有 Array。但 responseType=JSON 且服务端返回 JSON 数组时，
    //    运行时实际传进来的是 Array —— 这就是 signature 与实际数据不符的根源。
    //    直接把参数声明成 Lang.Object 会让 makeWebRequest 的实参校验失败
    //    （-l 1 起直接编译报错），所以签名只能留在 SDK 允许的类型内，
    //    进入函数后立刻宽化为 Object，再用 instanceof 判断真实类型。
    function onReceive(
        responseCode as Lang.Number,
        data as Lang.Dictionary?
    ) as Void {

        // 先排除 null：错误响应时 SDK 会传 null，避免下面 as Object 时踩空
        if (responseCode != 200 || data == null) {
            handleFailure();
            return;
        }

        // 宽化到 Object，后续判断不再受 Dictionary 这个"名义类型"约束
        var payload = data as Lang.Object;

        if (!(payload instanceof Lang.Array)) {
            handleFailure();                 // 服务端回了错误体（Dictionary），按失败处理
            return;
        }

        var list = payload as Lang.Array;

        if (list.size() == 0) {
            handleFailure();
            return;
        }

        marketData = list;
        state = STATE_OK;
        subtitle = "- Coin -";               // 实时数据，恢复正常副标题

        saveCache(list);

        WatchUi.requestUpdate();
    }

    // 请求失败的统一出口：有旧数据就降级展示并标注离线，没有才显示 No Net
    function handleFailure() as Void {

        if (marketData == null) {
            state = STATE_ERROR;
        } else {
            subtitle = "- Offline -";
        }

        WatchUi.requestUpdate();
    }

    // ---------------- 本地缓存 ----------------
    // 存储结构：{ "time" => 秒级时间戳, "symbols" => [String...],
    //             "prices" => [String...], "changes" => [String...] }
    // 拆成平行数组而不是嵌套字典，是为了避免不同设备对嵌套结构的存储差异。
    // 价格存的是**已格式化的字符串**，不是数值：一是位数信息不会在存取中丢，
    // 二是 Storage 对 Float/Double 的还原精度没有保证。涨跌存原始字符串
    // （方向在绘制时现判），缺数据的条目存空串占位，保证三个数组等长。

    function saveCache(list as Lang.Array) as Void {

        var names   = [] as Lang.Array;
        var values  = [] as Lang.Array;
        var changes = [] as Lang.Array;

        for (var i = 0; i < list.size(); i++) {

            var item = list[i];

            if (!(item instanceof Lang.Dictionary)) {
                continue;
            }

            var dict = item as Lang.Dictionary;
            var name = dict["symbol"];
            var price = dict["price"];

            if (name instanceof Lang.String) {

                var text = priceText(price);

                if (text == null) {
                    continue;
                }

                names.add(name);
                values.add(text);            // 字符串存取无损，读回时位数依然正确

                var change = dict["change"];

                changes.add(change instanceof Lang.String ? change : "");
            }
        }

        if (names.size() == 0) {
            return;
        }

        try {
            Application.Storage.setValue(CACHE_KEY, {
                "time"    => Time.now().value(),
                "symbols" => names,
                "prices"  => values,
                "changes" => changes
            });
        } catch (e) {
            // 存储不可用或配额不足时静默失败：缓存只是锦上添花，不该影响主流程
        }
    }

    function loadCache() as Void {

        var raw = null;

        try {
            raw = Application.Storage.getValue(CACHE_KEY);
        } catch (e) {
            return;                          // 存储不可用：当作没有缓存即可
        }

        if (!(raw instanceof Lang.Dictionary)) {
            return;                          // 首次安装，没有缓存
        }

        var cache = raw as Lang.Dictionary;

        var symbols = cache["symbols"];
        var prices  = cache["prices"];
        var changes = cache["changes"];      // 旧版缓存可能没有这一项

        if (!(symbols instanceof Lang.Array) || !(prices instanceof Lang.Array)) {
            return;
        }

        var names  = symbols as Lang.Array;
        var values = prices as Lang.Array;
        var trends = changes instanceof Lang.Array ? changes as Lang.Array : null;

        var count = names.size();
        if (values.size() < count) {
            count = values.size();           // 两个数组长度不一致时取短的
        }

        if (trends != null && trends.size() < count) {
            count = trends.size();
        }

        var items = [] as Lang.Array;

        for (var i = 0; i < count; i++) {

            var name  = names[i];
            var price = values[i];

            if (name instanceof Lang.String && price instanceof Lang.String) {

                var item = { "symbol" => name, "price" => price };

                if (trends != null) {

                    var change = trends[i];

                    // 空串占位的条目不塞 change 键，让 trendUp() 判为"无方向"
                    if (change instanceof Lang.String && change.length() > 0) {
                        item["change"] = change;
                    }
                }

                items.add(item);
            }
        }

        if (items.size() == 0) {
            return;
        }

        marketData = items;
        state = STATE_OK;
        subtitle = "- Cache -";              // 明确告诉用户这是旧数据
    }
}
