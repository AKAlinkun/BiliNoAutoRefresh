//
//  Tweak.x  —— BiliNoAutoRefresh v1.6.0（v1.5.0 + 一次性收尾）
//
//  ══ v1.6.0 相对 v1.5.0 只加一件事：拦截之后的一次性收尾 ══════════════════
//  v1.5.0 实测（用户弹窗截图）：挂钩 4 个、return-to-home 那次**吃掉 1**、
//  手动下拉那次**放行 1** → **核心目标已达成**。唯一残留：拦完列表停在半拉状态。
//
//  ★★ v1.6.0 的关键新证据（来自 v1.5.0 弹窗里的调用栈）：
//      ⛔️ beginRefreshing @ BFCRefreshHeader  页面: NSKVONotifying_BBPhonePegasusMainV2VC
//          ↳ 1  bili-universal  _ZN15TZipThreadWorks3runEiPv + 635188
//     → **B站是在后台线程池（TZipThreadWorks）里触发首页刷新的，不是主线程。**
//     这一条同时解释了 v1.4.x 为什么崩：它让 `-setState:` 钩子在**后台线程**上执行，
//     而钩子里读 `isDragging` / 走响应链找 VC，全是 UIKit 操作；主线程此时若正在
//     做动画 → 数据竞争 → 崩。
//
//  ══ 本版两处改动 ══════════════════════════════════════════════════════
//  ① 【收尾】拦完之后，把被 App 拉进下拉区的列表收回来。
//     · **只在主线程做**（后台线程绝不碰 UIKit）
//     · 一次拦截最多两趟（立刻一趟 + 0.45s 后一趟），且幂等（没要修的就不动手）
//     · 用户正在拖（isDragging/isTracking/isDecelerating）→ 不插手
//     · 刚放行过用户自己的刷新（2 秒内）→ 不插手
//     · 位移幅度有上限守卫（内边距 >200pt / 位置 >300pt 的一律不碰，避免误伤正常布局）
//     · 用 animated:NO —— 不产生动画就不产生额外回调，避免连锁
//     · 全局限流：短时间大量收尾时自动停手
//  ② 【线程纪律】判断"该不该拦"时**绝不从后台线程读 UIKit**：
//     · 非主线程 → 只做纯逻辑判断（类名、时间、熔断），一律视作"程序化刷新"
//     · 主线程   → 才去读 state / isDragging / isTracking / isDecelerating
//     这既是修掉 v1.4.x 的崩溃根因，也是本版收尾能安全落地的前提。
//
//  ══ 保留自 v1.5.0 的三条铁律 ═══════════════════════════════════════════
//  ★ 铁律 A：不挂任何 UIScrollView 全局方法（v1.4.0 死在这：与 App 布局互相纠正 → 卡死）
//  ★ 铁律 B：不代 App 调用语义 API（不代叫 endRefreshing 之类）
//  ★ 铁律 C：不自动弹窗（v1.4.x 的自动弹窗落在页面转场动画里 → 进视频闪退）
//    → 本版唯一的几何写入只发生在「拦截之后、主线程、一次性、有守卫」的收尾里。
//
//  ══ 安全阀（纯本地逻辑，不与 App 交互）═════════════════════════════════
//    阀① 启动宽限：插件生效后 20 秒内一律放行 → 保证首屏一定能加载出来
//    阀③ 重试熔断：3 秒内被拦 > 6 次 → 静默 30 秒（防 App 重试循环被反复吃掉）
//    ★ 共同原则：任何异常一律放行。宁可漏拦，绝不卡界面。
//
//  ══ 诊断 ════════════════════════════════════════════════════════════════
//    · **不自动弹窗**。只有「切到别的 App 再切回来」时才弹一次统计。
//    · 弹窗前检查稳定态：有窗口 / 不在转场 / 不在 present-dismiss 中。
//    · 日志：B站沙盒 Documents/BNR_fix.log（放行、拦截、收尾三个低频事件）。
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <ctype.h>

#pragma mark - 配置

static BOOL kBlockRefresh = YES;    // 总闸：NO = 只观察不拦（排障用）
static BOOL kShowAlert    = YES;    // 关掉 = 不弹统计窗（拦截能力不受影响）
static BOOL kProbeTrigger = YES;    // 记录刷新来源（哪个页面 + 调用栈）
static BOOL kRetract      = YES;    // 拦住之后做一次性收尾（把半拉状态收回来）

// 安全阀
static BOOL   kStartupGrace     = YES;   // 阀①
static double kStartupGraceSecs = 20.0;
static BOOL   kBreakRetryLoop   = YES;   // 阀③
static double kCooldownSecs     = 30.0;

static const char *kTargetBundle = "tv.danmaku.bilianime";
static const char *kVersion      = "1.6.0";

// 刷新状态取值（MJRefresh / BFCRefresh 系列：Idle=1 Pulling=2 Refreshing=3 WillRefresh=4 NoMoreData=5）
static const NSInteger kStatePulling = 2;

// 收尾保护的参数
static const NSTimeInterval kAllowGrace      = 2.0;    // 刚放行过用户刷新 → 这段时间内不收尾
static const double         kMaxInsetDelta   = 200.0;  // 内边距被抬高超过这么多 → 不像下拉，不碰
static const double         kMaxOffsetDelta  = 300.0;  // 位置被拉低超过这么多 → 不像下拉，不碰
static const int            kBurstWindowSecs = 5;      // 收尾限流窗口
static const int            kBurstMax        = 20;     // 窗口内最多收尾这么多次

#pragma mark - 类型垫片
// 用 @protocol 声明要调的外部方法：拿到完整类型，且不把 objc_msgSend 强转成函数指针。

@protocol BNRRefreshLike <NSObject>
- (NSInteger)state;
- (UIScrollView *)scrollView;
@end

#pragma mark - 基础工具

static const char *BNRClassNameC(id obj) {
    if (!obj) return NULL;
    Class c = object_getClass(obj);        // 纯 runtime 调用，任何线程都安全
    return c ? class_getName(c) : NULL;
}

static NSString *BNRClassName(id obj) {
    const char *n = BNRClassNameC(obj);
    return n ? [NSString stringWithUTF8String:n] : @"(nil)";
}

// 上拉加载更多用的 footer 一律不拦（只看类名，不碰 UIKit → 后台线程也安全）
static BOOL BNRIsFooter(id comp) {
    const char *n = BNRClassNameC(comp);
    return n && strstr(n, "Footer") != NULL;
}

// 类名里带 Refresh / PullToRefresh → 疑似刷新控件
static BOOL BNRNameLooksLikeRefresh(const char *n) {
    if (!n) return NO;
    return (strstr(n, "Refresh") != NULL) || (strstr(n, "PullToRefresh") != NULL);
}

// 继承链上出现这些基类 → 也算刷新控件（哪怕它自己的类名里没有 Refresh）
static BOOL BNRIsSubclassOfRefreshBase(Class c) {
    if (!c) return NO;
    static const char *bases[] = {
        "BPlusBaseRefreshComponent", "BFCRefreshComponent", "MJRefreshComponent"
    };
    for (Class k = class_getSuperclass(c); k != Nil; k = class_getSuperclass(k)) {
        const char *n = class_getName(k);
        if (!n) continue;
        for (int i = 0; i < 3; i++) {
            if (strcmp(n, bases[i]) == 0) return YES;
        }
    }
    return NO;
}

// ★ 只能在主线程调用：沿响应链找宿主 VC，只用于日志
static UIViewController *BNRViewControllerOf(UIView *v) {
    if (!v) return nil;
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
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/BNR_fix.log"];
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

static int  gHooked       = 0;    // 成功挂钩的方法数
static int  gSeenBegin    = 0;    // -beginRefreshing 被调用次数
static int  gAllowBegin   = 0;    // 放行次数
static int  gBlockedBegin = 0;    // 吃掉次数
static int  gSeenMain     = 0;    // 其中来自主线程的调用
static int  gSeenBG       = 0;    // 其中来自后台线程的调用
static int  gRetracted    = 0;    // 收尾实际改动了几何值的次数
static int  gRetractRun   = 0;    // 收尾执行（被调用）的次数
static int  gCooldownHits = 0;    // 熔断触发次数
static BOOL gInstalled    = NO;

static NSTimeInterval gStartTime     = 0;   // 插件生效时刻（宽限期基准）
static NSTimeInterval gLastAllow     = 0;   // 上次放行用户刷新的时间
static NSTimeInterval gCooldownUntil = 0;   // 熔断静默截止时间
static NSTimeInterval gBlockWinStart = 0;   // 熔断统计窗口起点
static int            gBlockInWindow = 0;
static NSTimeInterval gBurstStart    = 0;   // 收尾限流窗口起点
static int            gBurstCount    = 0;

static NSMutableArray *gHookedNames = nil;
static NSMutableArray *gFound       = nil;   // 来源取证（最多 4 条）
static NSTimeInterval  gFoundLast   = 0;

static void BNRShowStats(void);   // 前置声明（定义在后面）

#pragma mark - 刷新控件判定（★ 只有 BNRIsFooter 允许在后台线程调用）

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

// 用户正在拖屏幕 → 手动下拉，必须放行。★ 只能在主线程调用
static BOOL BNRIsUserDriven(id comp) {
    if (BNRStateOf(comp) == kStatePulling) return YES;
    UIScrollView *sv = BNRScrollViewOf(comp);
    if (sv && (sv.isDragging || sv.isTracking || sv.isDecelerating)) return YES;
    return NO;
}

// 这一页是谁？（宿主 VC 的类名）★ 只能在主线程调用
static NSString *BNRPageOf(id comp) {
    UIScrollView *sv = BNRScrollViewOf(comp);
    if (!sv) return nil;
    UIViewController *vc = BNRViewControllerOf(sv);
    if (!vc) return nil;
    Class c = object_getClass(vc);
    const char *n = c ? class_getName(c) : NULL;
    return n ? [NSString stringWithUTF8String:n] : nil;
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
    BNRSigVoidNoArg = 0       // v@:
} BNRSigKind;

// 只接受「返回值 void + self/:_cmd 且没有多余参数」的签名，其余一律不碰
static BOOL BNRSigCheck(BNRSigKind kind, const char *t) {
    if (!t) return NO;
    const char *p = BNRNextType(t);    if (!p || *p != 'v') return NO;
    p = BNRNextType(p + 1);            if (!p || *p != '@') return NO;
    p = BNRNextType(p + 1);            if (!p || *p != ':') return NO;
    p = BNRNextType(p + 1);
    switch (kind) {
        case BNRSigVoidNoArg:
            return (p == NULL);
    }
    return NO;
}

#pragma mark - 动态挂钩表（(类, 方法) 双键；不用 Logos、不用 substrate）

typedef struct { Class cls; SEL sel; IMP imp; } BNRPatch;
static BNRPatch gPatches[32];
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
    if (gPatchCount >= 32)    { if (why) *why = "表满";   return NO; }

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

#pragma mark - 取证：记下「哪个页面、被放行还是被拦」

// page 由调用方传入（主线程里取好），本函数自身不碰 UIKit
static void BNRRecordEvent(NSString *what, NSString *page, BOOL blocked) {
    if (!kProbeTrigger) return;
    NSTimeInterval now = BNRNow();
    if (now - gFoundLast < 1.5) return;      // 节流：最多每 1.5 秒记一条
    gFoundLast = now;

    @try {
        if (!gFound) gFound = [NSMutableArray array];
        if (gFound.count >= 4) return;       // 只留 4 条

        NSMutableArray *frames = [NSMutableArray array];
        for (NSString *s in [NSThread callStackSymbols]) {
            if ([s containsString:@"BNRHooked"] || [s containsString:@"BNRRecordEvent"]) continue;
            [frames addObject:s];
            if (frames.count >= 5) break;
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

// ★★ 线程纪律：非主线程时绝不读 UIKit。
//    后台线程调用 beginRefreshing 必然是"程序化刷新"（B站用 TZipThreadWorks 线程池
//    在数据回调里触发），所以直接按"非用户触发"处理，不需要也不能去读 isDragging。
static BOOL BNRShouldBlock(id comp, NSString *what) {
    if (!kBlockRefresh) return NO;
    (void)what;

    @try {
        if (BNRIsFooter(comp)) return NO;      // 上拉加载更多：放行（只看类名，线程安全）
    } @catch (NSException *e) { (void)e; return NO; }

    if ([NSThread isMainThread]) {
        @try {
            if (BNRIsUserDriven(comp)) return NO;   // 用户自己在下拉：放行
        } @catch (NSException *e) { (void)e; return NO; }
    }

    NSTimeInterval now = BNRNow();

    // 阀① 启动宽限：保证首屏一定能加载出来
    if (kStartupGrace && (now - gStartTime) < kStartupGraceSecs) return NO;

    // 阀③ 熔断静默期：App 正在重试循环 → 全部放行，先让它缓过来
    if (kBreakRetryLoop && now < gCooldownUntil) return NO;

    return YES;   // 唯一会拦的分支
}

// 记录一次拦截；3 秒内拦太多次 → 判定为重试循环 → 熔断静默
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

#pragma mark - 一次性收尾（★ 全工程唯一写入几何值的地方；只在主线程执行）

// 前提（全部满足才动手）：
//   ① 在主线程（否则直接返回）
//   ② 用户没在拖（isDragging / isTracking / isDecelerating 全为 NO）
//   ③ 刚没放行过用户自己的刷新（2 秒内）
//   ④ 位移幅度在合理范围内（不像正常布局）
//   ⑤ 限流窗口内没超次数
static void BNRRetractOnMain(id comp) {
    if (!comp) return;
    if (![NSThread isMainThread]) return;              // ★ 双重保险

    @try {
        UIScrollView *sv = BNRScrollViewOf(comp);
        if (!sv) return;

        if (sv.isDragging || sv.isTracking || sv.isDecelerating) return;             // ②
        if (gLastAllow > 0 && (BNRNow() - gLastAllow) < kAllowGrace) return;         // ③

        NSTimeInterval now = BNRNow();
        if (now - gBurstStart > (NSTimeInterval)kBurstWindowSecs) { gBurstStart = now; gBurstCount = 0; }
        if (gBurstCount >= kBurstMax) return;                                        // ⑤
        gBurstCount++;
        __sync_fetch_and_add(&gRetractRun, 1);

        BOOL fixed = NO;
        double insetBefore = 0.0, insetOrig = 0.0, offsetBefore = 0.0, offsetTarget = 0.0;

        // ① 顶部内边距被抬高 → 还原到控件自己记录的原值（MJRefresh 系列的标准字段）
        if ([comp respondsToSelector:NSSelectorFromString(@"scrollViewOriginalInset")]) {
            id v = [comp valueForKey:@"scrollViewOriginalInset"];
            if ([v isKindOfClass:[NSValue class]]) {
                UIEdgeInsets o = [(NSValue *)v UIEdgeInsetsValue];
                UIEdgeInsets cur = sv.contentInset;
                insetBefore = cur.top; insetOrig = o.top;
                double d = cur.top - o.top;
                if (d > 0.5 && d < kMaxInsetDelta) {      // ④ 抬高幅度像一次下拉
                    cur.top = o.top;
                    [sv setContentInset:cur];
                    fixed = YES;
                }
            }
        }

        // ② 位置被拉到顶部之上 → 不动画地拉回（animated:NO → 不产生额外动画回调）
        UIEdgeInsets adj = sv.adjustedContentInset;
        CGFloat top = -adj.top;
        CGPoint p = sv.contentOffset;
        offsetBefore = p.y; offsetTarget = top;
        if (p.y < top - 1.0 && p.y > top - kMaxOffsetDelta) {   // ④ 拉低幅度像一次下拉
            p.y = top;
            [sv setContentOffset:p animated:NO];
            fixed = YES;
        }

        if (fixed) {
            __sync_fetch_and_add(&gRetracted, 1);
            BNRLogLine(@"🧹 收尾 → %@  页面: %@  inset %.1f→%.1f  offset %.1f→%.1f",
                       BNRClassName(comp), BNRPageOf(comp) ?: @"(未识别)",
                       insetBefore, insetOrig, offsetBefore, offsetTarget);
        } else {
            BNRLogLine(@"🧹 收尾检查 → %@  无需处理（inset %.1f/%.1f  offset %.1f/%.1f）",
                       BNRClassName(comp), insetBefore, insetOrig, offsetBefore, offsetTarget);
        }
    } @catch (NSException *e) { (void)e; }
}

// 一次拦截排两趟：立刻一趟 + 0.45 秒后一趟（App 可能在之后才把列表拉下去）
static void BNRRetractSchedule(id comp) {
    if (!comp || !kRetract) return;
    dispatch_async(dispatch_get_main_queue(), ^{ BNRRetractOnMain(comp); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ BNRRetractOnMain(comp); });
}

#pragma mark - 唯一的钩子：-beginRefreshing

static void BNRHookedBeginRefreshing(id self, SEL _cmd) {
    __sync_fetch_and_add(&gSeenBegin, 1);
    BOOL onMain = [NSThread isMainThread];
    if (onMain) __sync_fetch_and_add(&gSeenMain, 1);
    else        __sync_fetch_and_add(&gSeenBG, 1);

    if (BNRShouldBlock(self, @"beginRefreshing")) {
        __sync_fetch_and_add(&gBlockedBegin, 1);
        BNRNoteBlocked();

        if (onMain) {
            if (gBlockedBegin <= 20) {
                BNRLogLine(@"⛔️ 拦截 beginRefreshing → %@  页面: %@",
                           BNRClassName(self), BNRPageOf(self) ?: @"(未识别)");
            }
            BNRRecordEvent([NSString stringWithFormat:@"beginRefreshing @ %@", BNRClassName(self)],
                           BNRPageOf(self), YES);
        } else {
            // 后台线程：不碰 UIKit，页面名留到主线程那趟收尾时再记
            if (gBlockedBegin <= 20) {
                BNRLogLine(@"⛔️ 拦截 beginRefreshing（后台线程）→ %@", BNRClassName(self));
            }
            BNRRecordEvent([NSString stringWithFormat:@"beginRefreshing @ %@（后台线程）",
                            BNRClassName(self)], @"(后台线程触发)", YES);
        }

        BNRRetractSchedule(self);   // ★ 唯一写入几何值的地方，且只在主线程执行
        return;
    }

    __sync_fetch_and_add(&gAllowBegin, 1);
    gLastAllow = BNRNow();
    if (gAllowBegin <= 12) {
        BNRLogLine(@"✅ 放行 beginRefreshing → %@  页面: %@",
                   BNRClassName(self),
                   onMain ? (BNRPageOf(self) ?: @"(未识别)") : @"(后台线程)");
    }

    IMP orig = BNROrigFor(self, _cmd);
    if (orig) ((void (*)(id, SEL))orig)(self, _cmd);
}

#pragma mark - 安装

static void BNRInstallGates(void) {
    if (gInstalled) return;
    gInstalled = YES;

    SEL sBegin = @selector(beginRefreshing);
    NSMutableArray *names = [NSMutableArray array];
    NSMutableArray *notes = [NSMutableArray array];
    int n = 0;

    // 命中规则 = 类名含 Refresh  或  继承自 BFC/BPlus/MJ 刷新基类（改名前缀也能命中）
    // ★ 只挂这一个方法：不挂任何 UIScrollView 全局方法、也不挂 -setState:
    unsigned int count = 0;
    Class *list = objc_copyClassList(&count);
    if (list) {
        for (unsigned int i = 0; i < count; i++) {
            Class c = list[i];
            if (!c) continue;
            const char *nm = class_getName(c);
            if (!nm) continue;
            if (!BNRNameLooksLikeRefresh(nm) && !BNRIsSubclassOfRefreshBase(c)) continue;

            BOOL any = NO;
            const char *w = NULL;
            if (BNRPatchMethod(c, sBegin, (IMP)&BNRHookedBeginRefreshing, BNRSigVoidNoArg, &w)) {
                gHooked++; n++; any = YES;
            } else if (w && strcmp(w, "继承来的(避碰父类)") && strcmp(w, "方法不存在")) {
                [notes addObject:[NSString stringWithFormat:@"%s 跳过(%s)", nm, w]];
            }

            if (any) [names addObject:[NSString stringWithUTF8String:nm]];
        }
        free(list);
    }

    gHookedNames = names;
    gStartTime   = BNRNow();

    BNRLogLine(@"=== v%s 闸门安装：%d 个 → %@  %@", kVersion, n,
               names.count ? [names componentsJoinedByString:@", "] : @"(无)",
               notes.count ? [notes componentsJoinedByString:@"; "] : @"");
    BNRLogLine(@"=== 安全阀：启动宽限 %.0fs / 重试熔断 %@(%.0fs) / 一次性收尾 %@",
               kStartupGraceSecs, kBreakRetryLoop ? @"开" : @"关", kCooldownSecs,
               kRetract ? @"开" : @"关");
}

#pragma mark - 统计弹窗（只在用户主动切回前台时弹，且绝不在转场中弹）

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

// ★ 只有「稳定态」才允许弹：有窗口、不在转场、不在 present/dismiss 过程中
static BOOL BNRCanPresent(UIViewController *vc) {
    if (!vc) return NO;
    if (!vc.view.window) return NO;
    if (vc.isBeingPresented || vc.isBeingDismissed) return NO;
    if (vc.isMovingToParentViewController || vc.isMovingFromParentViewController) return NO;
    if (vc.transitionCoordinator) return NO;      // 正在做转场动画
    return YES;
}

static void BNRAlert(NSString *title, NSString *msg, NSString *btn) {
    if (!kShowAlert) return;
    @try {
        UIViewController *root = BNRRootVC();
        if (!BNRCanPresent(root)) return;

        UIViewController *host = root;
        while (host.presentedViewController) host = host.presentedViewController;
        if (!BNRCanPresent(host)) return;
        if (host.presentedViewController) return;   // 已经有东西在展示了，别抢

        UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
                                                                   message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:btn style:UIAlertActionStyleDefault handler:nil]];
        [host presentViewController:ac animated:YES completion:nil];
    } @catch (NSException *e) { (void)e; }
}

static void BNRShowStats(void) {
    @try {
        if (!kShowAlert) return;
        if (gStartTime <= 0) return;
        if (BNRNow() - gStartTime < 15.0) return;    // 启动 15 秒内不弹，别干扰启动

        NSString *cls   = gHookedNames.count ? [gHookedNames componentsJoinedByString:@"\n"] : @"(无)";
        NSString *hints = gFound.count ? [gFound componentsJoinedByString:@"\n\n"] : @"(还没捕捉到)";
        NSString *valve = [NSString stringWithFormat:@"启动宽限剩 %.0fs%@%@",
                           MAX(0.0, kStartupGraceSecs - (BNRNow() - gStartTime)),
                           (gCooldownUntil > BNRNow()) ? @"·熔断中" : @"",
                           gCooldownHits ? [NSString stringWithFormat:@"·熔断过 %d 次", gCooldownHits] : @""];

        NSString *lastAllow = (gLastAllow > 0)
            ? [NSString stringWithFormat:@"%.0f 秒前", BNRNow() - gLastAllow]
            : @"(还没有)";

        NSString *msg = [NSString stringWithFormat:
            @"挂钩方法: %d 个    %@\n\n"
             "beginRefreshing   触发 %d / 放行 %d / 吃掉 %d\n"
             "触发来源   主线程 %d / 后台线程 %d\n"
             "一次性收尾   执行 %d 次 / 实际复位 %d 次\n"
             "最近一次放行用户刷新: %@\n\n"
             "挂钩的类:\n%@\n\n"
             "谁在触发刷新:\n%@",
            gHooked, valve,
            gSeenBegin, gAllowBegin, gBlockedBegin,
            gSeenMain, gSeenBG,
            gRetractRun, gRetracted,
            lastAllow, cls, hints];

        BNRLogLine(@"--- 前台统计：钩=%d 见=%d(主%d/后%d) 放行=%d 吃掉=%d 收尾=%d/%d",
                   gHooked, gSeenBegin, gSeenMain, gSeenBG,
                   gAllowBegin, gBlockedBegin, gRetractRun, gRetracted);
        BNRAlert([NSString stringWithFormat:@"BiliNoRefresh v%s 统计", kVersion], msg, @"好");
    } @catch (NSException *e) { (void)e; }
}

#pragma mark - 加载入口
// ⚠️ dyld 阶段只排一个延后任务，绝不碰运行时、绝不弹窗。

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

        // 装好后：每次切回前台报一次统计（启动 15 秒内不弹，且只在稳定态弹）
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
