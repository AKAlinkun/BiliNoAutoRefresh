//
//  Tweak.x  —— BiliNoAutoRefresh v1.4.2（保守版）
//
//  ── v1.4.2 相对 v1.4.1 只做一件事：修编译错误 ──────────────────────────────
//  v1.4.1 在 CI 上报：Tweak.x:506: use of undeclared identifier 'kStateRefreshing'
//  原因：编辑常量声明时把 `static const NSInteger kStateRefreshing = 3;` 整行误删了。
//  已补回，并把刷新状态枚举写全（Idle=1 Pulling=2 Refreshing=3 WillRefresh=4 NoMoreData=5）。
//  ★ 逻辑与 v1.4.1 **完全一致**，没有任何行为改动。
//  ★ 顺带在 CI 里加了一道「常量定义自检」，这类错误以后会在编译前就报出人话。
//
//  ── v1.4.0 实测把 App 搞卡死了，v1.4.1 把风险撤干净 ──────────────────────
//  现象：注入 v1.4.0 后「打开 B站启动很慢，首页直接卡死」，封面图全是灰的。
//  与「能正常用」的 v1.3.0 相比，v1.4.0 多出三个**全新变量**，本版逐一处理：
//
//   ① 【撤掉】两个全局热路径钩子：UIScrollView -setContentOffset:animated:
//      和 -setContentInset:。它们会被 App 的每一次布局/滚动调用；而我们在里面
//      **回写几何值**（把 offset 夹回顶部、把 inset.top 回滚），App 的布局代码
//      下一帧又设回去 → 两边对着改 = 布局死循环 → 主线程被占满 = 卡死 + 启动慢。
//      ★ 通用教训：**永远不要让 tweak 去"纠正" App 的几何值**，那是和布局系统抢方向盘。
//
//   ② 【加阀门】拦刷新本身也可能把 App 挂住：如果首屏是靠 beginRefreshing /
//      setState:Refreshing 驱动的，我们把它吃掉 → 首屏数据永远不来 → 页面空转。
//      本版加三道安全阀（见下），任何一道触发都直接放行，宁可漏拦也不卡界面。
//
//   ③ 【后移】"首次拦截自动弹窗"从 2.5s 改成"启动 15 秒之后才允许弹"，
//      避免在启动过程里 present 一个 alert 干扰 App 自己的启动流程。
//
//  ── 本版只做两件事 ──────────────────────────────────────────────────────
//   ① 拦 -beginRefreshing / -setState:Refreshing（**只读判断，绝不回写几何值**）
//   ② 拦完做一次**温和收尾**：只在该控件自己的滚动视图上，把被抬高的 inset.top
//      还原、把 contentOffset 拉回顶部 → 解决 v1.3.0 的「下拉一下但不刷新、卡住」。
//      （去掉了 v1.4.0 的 endRefreshing 调用 —— 那是 App 的语义 API，不该由我们代叫。）
//
//  ── 三道安全阀（全部"故障时放行"，这是不卡界面的关键）──────────────────
//   阀① 启动宽限：启动后 N 秒内，一切刷新一律放行 → 保证首屏一定能加载出来。
//   阀② 每页首次：识别到宿主页面后，**每个页面允许一次**程序化刷新（首屏/首次进入），
//                 之后的才拦。→ 用户场景（启动已放过一次，返回首页那次才被拦）正好命中。
//   阀③ 熔断：3 秒内被拦超过 6 次 → 判定 App 在重试循环 → 静默 30 秒全部放行。
//   另有：认不出宿主页面 → 放行（不认识的场景不下手）；footer（上拉加载更多）→ 放行。
//
//  ── 取证 ────────────────────────────────────────────────────────────────
//  统计拆成「触发 / 放行 / 吃掉」，并把每次**放行**和**拦截**都记下「哪个页面 +
//  调用栈」，弹窗里能直接看到：谁在什么时候触发了刷新、为什么被放行/拦住。
//  这是彻底定案、并最终把拦截点上移到"触发那一行"的关键证据。
//
//  ⚠️ 诊断版：启动 15 秒后，首次拦截会弹一次；之后每次切回前台再弹一次。
//     定案后把 kShowAlert / kProbeTrigger 改 NO 即可（拦截能力不受影响）。
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <ctype.h>

#pragma mark - 开关

static BOOL kBlockRefresh = YES;    // 总闸：吃掉「非用户触发、且该页面已放过一次」的刷新
static BOOL kShowAlert    = YES;    // 关掉 = 不弹窗（拦截能力不受影响）
static BOOL kProbeTrigger = YES;    // 记录刷新来源（哪个页面 + 调用栈）

// ── 安全阀（默认全开。全关掉 = 变成"见刷新就拦"的激进版，界面有卡住风险，别关）──
static BOOL   kStartupGrace     = YES;   // 阀① 启动宽限期
static double kStartupGraceSecs = 20.0;  //      启动后这么多秒内一律放行
static BOOL   kFirstPerPage     = YES;   // 阀② 每个页面允许一次程序化刷新
static BOOL   kBreakRetryLoop   = YES;   // 阀③ 重试循环熔断
static double kCooldownSecs     = 30.0;  //      熔断后静默这么久

static const char *kTargetBundle = "tv.danmaku.bilianime";
static const char *kVersion      = "1.4.2";

// 刷新状态取值（与 MJRefresh / BFCRefresh 一致：Idle=1 Pulling=2 Refreshing=3 WillRefresh=4 NoMoreData=5）
// ★ 这两个常量必须成对存在：漏掉任何一个都会在 CI 编译期报 "use of undeclared identifier"
static const NSInteger kStatePulling    = 2;
static const NSInteger kStateRefreshing = 3;

// 收尾保护：刚放行过用户自己的刷新 → 这段时间内不做几何复位，绝不打扰用户的下拉
static const NSTimeInterval kAllowGrace = 2.0;

#pragma mark - 类型垫片
// 用协议声明要调的外部方法：拿到完整类型，且**不把 objc_msgSend 强转成函数指针**
// （ARC 下函数指针返回值所有权会算错，这里整个避开）。

@protocol BNRRefreshLike <NSObject>
- (NSInteger)state;
- (UIScrollView *)scrollView;
@end

#pragma mark - 基础工具

static const char *BNRClassNameC(id obj) {
    if (!obj) return NULL;
    Class c = object_getClass(obj);
    return c ? class_getName(c) : NULL;
}

static NSString *BNRClassName(id obj) {
    const char *n = BNRClassNameC(obj);
    return n ? [NSString stringWithUTF8String:n] : @"(nil)";
}

static BOOL BNRIsFooter(id comp) {
    const char *n = BNRClassNameC(comp);
    return n && strstr(n, "Footer") != NULL;      // 上拉加载更多用的 footer 一律不拦
}

static BOOL BNRNameLooksLikeRefresh(const char *n) {
    if (!n) return NO;
    return (strstr(n, "Refresh") != NULL) || (strstr(n, "PullToRefresh") != NULL);
}

// 继承链上出现这些基类 → 这个类也是刷新控件（哪怕它自己的类名里没有 Refresh）
static BOOL BNRIsSubclassOfRefreshBase(Class c) {
    if (!c) return NO;
    static const char *bases[] = {
        "BPlusBaseRefreshComponent", "BFCRefreshComponent", "MJRefreshComponent"
    };
    for (Class k = class_getSuperclass(c); k != Nil; k = class_getSuperclass(k)) {
        const char *n = class_getName(k);
        for (int i = 0; i < 3; i++) {
            if (strcmp(n, bases[i]) == 0) return YES;
        }
    }
    return NO;
}

// 某个 view 挂在哪个 VC 上（沿响应链往上找），用来辨认「是哪一页在下拉」
static UIViewController *BNRViewControllerOf(UIView *v) {
    id r = v;
    for (int i = 0; i < 12 && r; i++) {
        if ([r isKindOfClass:[UIViewController class]]) return (UIViewController *)r;
        if (![r isKindOfClass:[UIResponder class]]) break;
        r = [(UIResponder *)r nextResponder];
    }
    return nil;
}

#pragma mark - 日志（低频：只在放行/拦截/收尾时写）

static NSString *BNRLogPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/BNR_step.log"];
}

static void BNRLogLine(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSLog(@"[BNR] %@", msg);

    @try {
        NSString *path = BNRLogPath();
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:nil];
        NSString *line = [NSString stringWithFormat:@"%@  %@\n", [NSDate date], msg];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) return;
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } @catch (NSException *e) { (void)e; }
}

#pragma mark - 计数器 / 运行状态

static int  gHooked       = 0;      // 成功挂钩的方法数
static int  gSeenBegin    = 0;      // -beginRefreshing 被调用次数
static int  gAllowBegin   = 0;      // 放行次数
static int  gBlockedBegin = 0;      // 吃掉次数
static int  gSeenState    = 0;      // -setState:Refreshing 被调用次数
static int  gAllowState   = 0;
static int  gBlockedState = 0;
static int  gUnstuck      = 0;      // 温和收尾次数
static int  gCooldownHits = 0;      // 熔断触发次数
static BOOL gInstalled    = NO;
static BOOL gSuppress     = NO;     // 我们自己收尾时跳过闸门逻辑（防自激）
static BOOL gAutoPopped   = NO;

static NSTimeInterval gStartTime      = 0;   // 插件生效时刻（宽限期基准）
static NSTimeInterval gLastAllow      = 0;   // 上次放行用户刷新的时间
static NSTimeInterval gCooldownUntil  = 0;   // 熔断静默截止时间
static NSTimeInterval gBlockWinStart  = 0;   // 熔断统计窗口起点
static int            gBlockInWindow  = 0;

static NSMutableArray *gHookedNames = nil;
static NSMutableArray *gFound       = nil;   // 来源取证（最多 4 条）
static NSTimeInterval  gFoundLast   = 0;
static NSMutableSet   *gAllowedPages = nil;  // 已经放过一次程序化刷新的页面类名

static void BNRShowStats(void);     // 前置声明（弹窗定义在后面）
static void BNRAutoPopOnce(void);   // 前置声明

#pragma mark - 刷新控件 / 页面 判定

static NSInteger BNRStateOf(id comp) {
    id p = (id<BNRRefreshLike>)comp;
    @try {
        if ([p respondsToSelector:@selector(state)]) return [p state];
    } @catch (NSException *e) { (void)e; }
    return 1;   // Idle
}

static UIScrollView *BNRScrollViewOf(id comp) {
    id p = (id<BNRRefreshLike>)comp;
    @try {
        if ([p respondsToSelector:@selector(scrollView)]) {
            id sv = [p scrollView];
            if ([sv isKindOfClass:[UIScrollView class]]) return (UIScrollView *)sv;
        }
    } @catch (NSException *e) { (void)e; }
    return nil;
}

// 用户正在拖屏幕 → 手动下拉，必须放行
static BOOL BNRIsUserDriven(id comp) {
    if (BNRStateOf(comp) == kStatePulling) return YES;
    UIScrollView *sv = BNRScrollViewOf(comp);
    if (sv && (sv.isDragging || sv.isTracking || sv.isDecelerating)) return YES;
    return NO;
}

// 这一页是谁？（宿主 VC 的类名）—— 认不出就返回 nil
static NSString *BNRPageOf(id comp) {
    UIScrollView *sv = BNRScrollViewOf(comp);
    if (!sv) return nil;
    UIViewController *vc = BNRViewControllerOf(sv);
    if (!vc) return nil;
    const char *n = object_getClass(vc) ? class_getName(object_getClass(vc)) : NULL;
    return n ? [NSString stringWithUTF8String:n] : nil;
}

// 该页面是否已经放过一次程序化刷新
static BOOL BNRPageAlreadyAllowed(NSString *page) {
    if (!page) return NO;
    @synchronized (gAllowedPages ?: [NSNull null]) {
        return [gAllowedPages containsObject:page];
    }
}

static void BNRMarkPageAllowed(NSString *page) {
    if (!page) return;
    @synchronized (gAllowedPages ?: [NSNull null]) {
        if (!gAllowedPages) gAllowedPages = [NSMutableSet set];
        [gAllowedPages addObject:page];
    }
}

static NSTimeInterval BNRNow(void) {
    return [NSDate timeIntervalSinceReferenceDate];
}

#pragma mark - 方法签名校验（防参数错位崩溃）

static const char *BNRNextType(const char *t) {
    if (!t) return NULL;
    while (*t && isdigit((unsigned char)*t)) t++;
    return (*t) ? t : NULL;
}

typedef enum {
    BNRSigVoidNoArg = 0,       // v@:
    BNRSigVoidIntArg           // v@:q  / v@:i / v@:l …
} BNRSigKind;

// 只接受「返回值 void + self/:_cmd + 期望的参数类型」，其余一律不碰
static BOOL BNRSigCheck(BNRSigKind kind, const char *t) {
    if (!t) return NO;
    const char *p = BNRNextType(t);    if (!p || *p != 'v') return NO;
    p = BNRNextType(p + 1);            if (!p || *p != '@') return NO;
    p = BNRNextType(p + 1);            if (!p || *p != ':') return NO;
    p = BNRNextType(p + 1);

    switch (kind) {
        case BNRSigVoidNoArg:
            return (p == NULL);

        case BNRSigVoidIntArg: {
            if (!p) return NO;
            char r = *p;
            if (!(r == 'q' || r == 'Q' || r == 'i' || r == 'I' ||
                  r == 'l' || r == 'L' || r == 's' || r == 'S' || r == 'c' || r == 'C')) return NO;
            p = BNRNextType(p + 1);
            return (p == NULL);
        }
    }
    return NO;
}

#pragma mark - 动态挂钩表（(类, 方法) 双键；不用 Logos、不用 substrate）

typedef struct { Class cls; SEL sel; IMP imp; } BNRPatch;
static BNRPatch gPatches[160];
static int      gPatchCount = 0;

static IMP BNROrigFor(id self, SEL sel) {
    Class c = object_getClass(self);
    for (Class k = c; k != Nil; k = class_getSuperclass(k)) {
        for (int i = 0; i < gPatchCount; i++) {
            if (gPatches[i].cls == k && sel_isEqual(gPatches[i].sel, sel)) return gPatches[i].imp;
        }
    }
    return NULL;
}

// 这个方法归哪个类「自己」实现？返回 Nil = 都是继承来的（不能改，会波及所有兄弟类）
static Class BNROwnerOfSEL(Class c, SEL sel) {
    for (Class k = c; k != Nil; k = class_getSuperclass(k)) {
        unsigned int n = 0;
        Method *ms = class_copyMethodList(k, &n);
        BOOL found = NO;
        if (ms) {
            for (unsigned int i = 0; i < n; i++) {
                if (sel_isEqual(method_getName(ms[i]), sel)) { found = YES; break; }
            }
            free(ms);
        }
        if (found) return k;
    }
    return Nil;
}

static BOOL BNRIsPatched(Class c, SEL sel) {
    for (int i = 0; i < gPatchCount; i++) {
        if (gPatches[i].cls == c && sel_isEqual(gPatches[i].sel, sel)) return YES;
    }
    return NO;
}

static BOOL BNRPatchMethod(Class c, SEL sel, IMP repl, BNRSigKind kind, const char **why) {
    if (!c || !sel || !repl) { if (why) *why = "空参数"; return NO; }
    if (BNRIsPatched(c, sel)) { if (why) *why = "已挂过"; return NO; }
    if (gPatchCount >= 160)   { if (why) *why = "表满";   return NO; }

    if (BNROwnerOfSEL(c, sel) != c) { if (why) *why = "继承来的(避碰父类)"; return NO; }

    Method m = class_getInstanceMethod(c, sel);
    if (!m) { if (why) *why = "方法不存在"; return NO; }
    const char *t = method_getTypeEncoding(m);
    if (!BNRSigCheck(kind, t)) { if (why) *why = t ? t : "无签名"; return NO; }

    IMP old = method_setImplementation(m, repl);
    if (!old || old == repl) { if (why) *why = "换实现失败"; return NO; }

    gPatches[gPatchCount].cls = c;
    gPatches[gPatchCount].sel = sel;
    gPatches[gPatchCount].imp = old;
    gPatchCount++;
    return YES;
}

#pragma mark - 取证：记下「哪个页面、什么时候、被放行/被拦」

static void BNRRecordEvent(NSString *what, NSString *page, UIScrollView *sv, BOOL blocked) {
    if (!kProbeTrigger) return;
    NSTimeInterval now = BNRNow();
    if (now - gFoundLast < 1.5) return;      // 节流：最多每 1.5 秒记一条
    gFoundLast = now;

    @try {
        if (!gFound) gFound = [NSMutableArray array];
        if (gFound.count >= 4) return;       // 只留 4 条

        NSMutableArray *frames = [NSMutableArray array];
        for (NSString *s in [NSThread callStackSymbols]) {
            if ([s containsString:@"BNRHooked"] || [s containsString:@"BNRRecordEvent"] ||
                [s containsString:@"BNRUnstick"] || [s containsString:@"BNRDecide"]) continue;
            [frames addObject:s];
            if (frames.count >= 6) break;
        }
        NSString *line = [NSString stringWithFormat:@"%@ %@  页面: %@\n    ↳ %@",
                          blocked ? @"⛔️" : @"✅", what,
                          page ?: @"(未识别)",
                          [frames componentsJoinedByString:@"\n    ↳ "]];
        [gFound addObject:line];
        BNRLogLine(@"🔎 %@", line);
    } @catch (NSException *e) { (void)e; }
}

#pragma mark - 闸门决策（故障一律放行：宁可漏拦，绝不卡住界面）

static BOOL BNRShouldBlock(id comp, NSString *what) {
    if (!kBlockRefresh || gSuppress) return NO;
    if (BNRIsFooter(comp)) return NO;                                  // 上拉加载更多：放行

    @try {
        if (BNRIsUserDriven(comp)) return NO;                          // 用户自己在下拉：放行
    } @catch (NSException *e) { (void)e; return NO; }

    NSTimeInterval now = BNRNow();

    // 阀① 启动宽限：保证首屏一定能加载出来
    if (kStartupGrace && (now - gStartTime) < kStartupGraceSecs) {
        BNRMarkPageAllowed(BNRPageOf(comp));
        return NO;
    }

    // 阀③ 熔断静默期：App 正在重试循环 → 全部放行，先让它缓过来
    if (kBreakRetryLoop && now < gCooldownUntil) {
        BNRMarkPageAllowed(BNRPageOf(comp));
        return NO;
    }

    // 认不出是哪一页 → 不敢下手，放行
    NSString *page = BNRPageOf(comp);
    if (!page || page.length == 0) return NO;

    // 阀② 每个页面允许一次程序化刷新（首屏 / 首次进入这一页）
    if (kFirstPerPage && !BNRPageAlreadyAllowed(page)) {
        BNRMarkPageAllowed(page);
        BNRRecordEvent([NSString stringWithFormat:@"%@ @ %@（该页首次，放行）",
                        what, BNRClassName(comp)], page, BNRScrollViewOf(comp), NO);
        return NO;
    }

    return YES;   // 唯一会拦的分支：非用户触发 + 非 footer + 已过宽限 + 该页已放过一次
}

// 记录一次拦截；3 秒内拦太多次 → 判定为重试循环 → 熔断 30 秒
static void BNRNoteBlocked(void) {
    NSTimeInterval now = BNRNow();
    if (now - gBlockWinStart > 3.0) { gBlockWinStart = now; gBlockInWindow = 0; }
    gBlockInWindow++;
    if (kBreakRetryLoop && gBlockInWindow > 6 && now >= gCooldownUntil) {
        gCooldownUntil = now + kCooldownSecs;
        __sync_fetch_and_add(&gCooldownHits, 1);
        BNRLogLine(@"⚠️ 3 秒内拦了 %d 次，疑似 App 在重试 → 熔断静默 %.0f 秒",
                   gBlockInWindow, kCooldownSecs);
    }
}

#pragma mark - 温和收尾：把「拉到一半的刷新」复位
// ★ 只做几何复位，绝不调用 App 的语义 API（v1.4.0 就是多调了 endRefreshing、
//   又去全局纠正 offset/inset 才把界面搞卡的）。
// 只在这个控件自己的滚动视图上、且用户没在拖、且刚没放行过用户刷新时才动手。

static void BNRUnstickPass(id comp) {
    if (!comp) return;
    @try {
        UIScrollView *sv = BNRScrollViewOf(comp);
        if (!sv) return;
        if (sv.isDragging || sv.isTracking || sv.isDecelerating) return;   // 用户正在动，别插手
        if (gLastAllow > 0 && (BNRNow() - gLastAllow) < kAllowGrace) return; // 刚放行过用户刷新

        BOOL fixed = NO;

        // ① 顶部内边距被抬高 → 还原
        if ([comp respondsToSelector:NSSelectorFromString(@"scrollViewOriginalInset")]) {
            id v = [comp valueForKey:@"scrollViewOriginalInset"];
            if ([v isKindOfClass:[NSValue class]]) {
                UIEdgeInsets orig = [(NSValue *)v UIEdgeInsetsValue];
                UIEdgeInsets cur  = sv.contentInset;
                if (cur.top > orig.top + 0.5) {
                    gSuppress = YES;
                    cur.top = orig.top;
                    [sv setContentInset:cur];
                    gSuppress = NO;
                    fixed = YES;
                }
            }
        }

        // ② 位置被拉到顶部之上 → 拉回来
        CGFloat top = -(sv.adjustedContentInset.top);
        CGPoint p = sv.contentOffset;
        if (p.y < top - 1.0) {
            gSuppress = YES;
            p.y = top;
            [sv setContentOffset:p animated:YES];
            gSuppress = NO;
            fixed = YES;
        }

        if (fixed) {
            __sync_fetch_and_add(&gUnstuck, 1);
            BNRLogLine(@"🧹 温和收尾 → %@", BNRClassName(comp));
        }
    } @catch (NSException *e) { (void)e; }
}

static void BNRUnstick(id comp) {
    if (!comp) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ BNRUnstickPass(comp); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.50 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ BNRUnstickPass(comp); });
}

#pragma mark - 闸门本体（只读判断，绝不回写几何值）

// ① -beginRefreshing
static void BNRHookedBeginRefreshing(id self, SEL _cmd) {
    __sync_fetch_and_add(&gSeenBegin, 1);

    if (BNRShouldBlock(self, @"beginRefreshing")) {
        __sync_fetch_and_add(&gBlockedBegin, 1);
        BNRNoteBlocked();
        if (gBlockedBegin <= 20) BNRLogLine(@"⛔️ 拦截 beginRefreshing → %@  页面: %@",
                                            BNRClassName(self), BNRPageOf(self) ?: @"(未识别)");
        BNRRecordEvent([NSString stringWithFormat:@"beginRefreshing @ %@",
                        BNRClassName(self)], BNRPageOf(self), BNRScrollViewOf(self), YES);
        BNRUnstick(self);
        BNRAutoPopOnce();
        return;
    }

    __sync_fetch_and_add(&gAllowBegin, 1);
    gLastAllow = BNRNow();
    if (gAllowBegin <= 12) BNRLogLine(@"✅ 放行 beginRefreshing → %@  页面: %@",
                                      BNRClassName(self), BNRPageOf(self) ?: @"(未识别)");

    IMP orig = BNROrigFor(self, _cmd);
    if (orig) ((void (*)(id, SEL))orig)(self, _cmd);
}

// ② -setState:（有的实现直接置 Refreshing，不走 beginRefreshing）
static void BNRHookedSetState(id self, SEL _cmd, NSInteger newState) {
    if (newState == kStateRefreshing) {
        __sync_fetch_and_add(&gSeenState, 1);

        if (BNRShouldBlock(self, @"setState:Refreshing")) {
            __sync_fetch_and_add(&gBlockedState, 1);
            BNRNoteBlocked();
            if (gBlockedState <= 20) BNRLogLine(@"⛔️ 拦截 setState:Refreshing → %@  页面: %@",
                                                BNRClassName(self), BNRPageOf(self) ?: @"(未识别)");
            BNRRecordEvent([NSString stringWithFormat:@"setState:Refreshing @ %@",
                            BNRClassName(self)], BNRPageOf(self), BNRScrollViewOf(self), YES);
            BNRUnstick(self);
            BNRAutoPopOnce();
            return;
        }

        __sync_fetch_and_add(&gAllowState, 1);
        gLastAllow = BNRNow();
    }

    IMP orig = BNROrigFor(self, _cmd);
    if (orig) ((void (*)(id, SEL, NSInteger))orig)(self, _cmd, newState);
}

#pragma mark - 安装

static void BNRInstallGates(void) {
    if (gInstalled) return;
    gInstalled = YES;

    SEL sBegin = @selector(beginRefreshing);
    SEL sSet   = NSSelectorFromString(@"setState:");
    NSMutableArray *names = [NSMutableArray array];
    NSMutableArray *notes = [NSMutableArray array];
    int n = 0;

    // 命中规则 = 类名含 Refresh  或  继承自 BFC/BPlus/MJ 刷新基类（改名前缀也能命中）
    // ★ 本版**只挂这两个方法**，不再挂任何 UIScrollView 的全局方法。
    unsigned int count = 0;
    Class *list = objc_copyClassList(&count);
    if (list) {
        for (unsigned int i = 0; i < count; i++) {
            Class c = list[i];
            const char *nm = class_getName(c);
            if (!BNRNameLooksLikeRefresh(nm) && !BNRIsSubclassOfRefreshBase(c)) continue;

            BOOL any = NO;
            const char *w = NULL;
            if (BNRPatchMethod(c, sBegin, (IMP)&BNRHookedBeginRefreshing, BNRSigVoidNoArg, &w)) {
                gHooked++; n++; any = YES;
            } else if (w && strcmp(w, "继承来的(避碰父类)") && strcmp(w, "方法不存在")) {
                [notes addObject:[NSString stringWithFormat:@"%s -beginRefreshing 跳过(%s)", nm, w]];
            }

            // -setState: 只挂 B站自研的那些；UIRefreshControl 的状态枚举取值不同，
            // 挂它的 setState: 有误判风险，所以只留它的 -beginRefreshing。
            if (strstr(nm, "UIRefreshControl") == NULL) {
                w = NULL;
                if (BNRPatchMethod(c, sSet, (IMP)&BNRHookedSetState, BNRSigVoidIntArg, &w)) {
                    gHooked++; n++; any = YES;
                } else if (w && strcmp(w, "继承来的(避碰父类)") && strcmp(w, "方法不存在")) {
                    [notes addObject:[NSString stringWithFormat:@"%s -setState: 跳过(%s)", nm, w]];
                }
            }

            if (any) [names addObject:@(nm)];
        }
        free(list);
    }

    gHookedNames = names;
    gStartTime   = BNRNow();

    BNRLogLine(@"=== v%s 闸门安装：%d 个 → %@  %@", kVersion, n,
               names.count ? [names componentsJoinedByString:@", "] : @"(无)",
               notes.count ? [notes componentsJoinedByString:@"; "] : @"");
    BNRLogLine(@"=== 安全阀：启动宽限 %.0fs / 每页首次放行 %@ / 重试熔断 %@(%.0fs)",
               kStartupGraceSecs, kFirstPerPage ? @"开" : @"关",
               kBreakRetryLoop ? @"开" : @"关", kCooldownSecs);
}

#pragma mark - 弹窗

static UIViewController *BNRRootVC(void) {
    @try {
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                if (w.isKeyWindow && w.rootViewController) return w.rootViewController;
            }
        }
        return UIApplication.sharedApplication.keyWindow.rootViewController;
    } @catch (NSException *e) { (void)e; return nil; }
}

static void BNRAlertRetry(NSString *title, NSString *msg, NSString *btn, void (^after)(void), int tries) {
    if (!kShowAlert) { if (after) after(); return; }
    UIViewController *root = BNRRootVC();
    if (!root) {
        if (tries <= 0) { if (after) after(); return; }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            BNRAlertRetry(title, msg, btn, after, tries - 1);
        });
        return;
    }
    @try {
        UIViewController *host = root;
        while (host.presentedViewController) host = host.presentedViewController;
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
                                                                   message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:btn
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) { (void)a; if (after) after(); }]];
        [host presentViewController:ac animated:YES completion:nil];
    } @catch (NSException *e) {
        (void)e;
        if (after) after();
    }
}

static void BNRAlert(NSString *title, NSString *msg, NSString *btn, void (^after)(void)) {
    BNRAlertRetry(title, msg, btn, after, 4);
}

static void BNRShowStats(void) {
    @try {
        if (!kShowAlert) return;
        if (gStartTime <= 0) return;
        if (BNRNow() - gStartTime < 15.0) return;    // 启动 15 秒内不弹，别干扰启动

        NSString *cls   = gHookedNames.count ? [gHookedNames componentsJoinedByString:@"\n"] : @"(无)";
        NSString *pages = gAllowedPages.count ? [[gAllowedPages allObjects] componentsJoinedByString:@", "] : @"(无)";
        NSString *hints = gFound.count ? [gFound componentsJoinedByString:@"\n\n"] : @"(还没捕捉到)";
        NSString *valve = [NSString stringWithFormat:@"启动宽限剩 %.0fs%@%@",
                           MAX(0.0, kStartupGraceSecs - (BNRNow() - gStartTime)),
                           (gCooldownUntil > BNRNow()) ? @"·熔断中" : @"",
                           gCooldownHits ? [NSString stringWithFormat:@"·熔断过 %d 次", gCooldownHits] : @""];

        NSString *msg = [NSString stringWithFormat:
            @"挂钩方法: %d 个    %@\n\n"
             "beginRefreshing   触发 %d / 放行 %d / 吃掉 %d\n"
             "setState:Refreshing  触发 %d / 放行 %d / 吃掉 %d\n"
             "温和收尾: %d\n\n"
             "已放过一次的页面:\n%@\n\n"
             "挂钩的类:\n%@\n\n"
             "谁在触发刷新:\n%@",
            gHooked, valve,
            gSeenBegin, gAllowBegin, gBlockedBegin,
            gSeenState, gAllowState, gBlockedState,
            gUnstuck, pages, cls, hints];

        BNRLogLine(@"--- 前台统计：钩=%d 见begin=%d 放行=%d 吃begin=%d 见state=%d 放行=%d 吃state=%d 收尾=%d",
                   gHooked, gSeenBegin, gAllowBegin, gBlockedBegin,
                   gSeenState, gAllowState, gBlockedState, gUnstuck);
        BNRAlert([NSString stringWithFormat:@"BiliNoRefresh v%s 统计", kVersion], msg, @"好", nil);
    } @catch (NSException *e) { (void)e; }
}

// 首次拦截后弹一次（但必须已经过了启动宽限，别在启动过程里弹）
static void BNRAutoPopOnce(void) {
    if (!kShowAlert || gAutoPopped) return;
    if (gStartTime <= 0 || (BNRNow() - gStartTime) < 15.0) return;
    gAutoPopped = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ BNRShowStats(); });
}

#pragma mark - 加载入口
// ⚠️ dyld 阶段只排一个延后任务，绝不碰运行时、绝不弹窗。
//   （v1.1.0 就是在这里扫类表批量改实现才把 B站搞崩的，别再犯。）

static void BNRInstallWhenReady(int tries) {
    @try {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
        if (![bid isEqualToString:[NSString stringWithUTF8String:kTargetBundle]]) return;   // 只在 B站进程内动作

        // 等 B站自己的库加载完：能看见刷新控件类 或者 已重试 10 次，就动手
        BOOL ready = (objc_getClass("BFCRefreshComponent")      != NULL) ||
                     (objc_getClass("BPlusBaseRefreshComponent") != NULL) ||
                     (objc_getClass("MJRefreshHeader")          != NULL);
        if (!ready && tries < 10) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ BNRInstallWhenReady(tries + 1); });
            return;
        }

        BNRInstallGates();

        // 装好后：每次切回前台报一次统计，方便截图（启动 15 秒内不弹）
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) { (void)note; BNRShowStats(); }];
    } @catch (NSException *e) { (void)e; }
}

__attribute__((constructor))
static void BNRInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ BNRInstallWhenReady(0); });
}
