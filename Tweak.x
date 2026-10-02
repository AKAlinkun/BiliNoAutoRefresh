//
//  Tweak.x  —— BiliNoAutoRefresh v1.5.0（回到已验证的最小可靠版）
//
//  ══ 为什么又改回去 ══════════════════════════════════════════════════════
//  实测链条（每一条都是真机结论，不是推断）：
//
//    v1.3.0  ✅ 不闪退；钩子挂上 4 个；「返回首页不刷新」**已生效**（用户亲测确认）
//              唯一毛病：会停在半拉状态，向上划一下恢复 —— 可自愈，只是难看
//    v1.4.0  ❌ 启动极慢 + 首页直接卡死（挂了两条 UIScrollView 几何热路径钩子，
//              在里面回写几何值 → 与 App 布局互相纠正 → 布局死循环）
//    v1.4.1  ❌ CI 编译失败（kStateRefreshing 常量被误删）
//    v1.4.2  ❌ 下拉刷新即闪退、搜索进视频即闪退（行为 == v1.4.1）
//
//  ★ 根因是我的方法论错了：v1.4.x 在 v1.3.0 之上**一次加了三个新机制**
//    （-setState: 钩子 / 几何收尾 / 自动弹窗），**一次只该动一个变量**。
//    所以本版把三个全部撤掉，回到 v1.3.0 的钩子集。
//
//  ══ 本版做什么 ══════════════════════════════════════════════════════════
//  只挂 **一个方法**：刷新控件的 `-beginRefreshing`
//    · 用户自己在下拉（state==Pulling，或 scrollView 正在 dragging/tracking/decelerating）→ 放行
//    · footer（上拉加载更多）→ 放行
//    · 其余「程序化刷新」→ 拦掉，不执行原方法
//
//  ★ 铁律 A：全程**不写任何几何值**（不碰 contentOffset / contentInset / frame）。
//            v1.4.0 就是死在这一条上。
//  ★ 铁律 B：全程**不代 App 调用语义 API**（不代叫 endRefreshing 之类）。
//  ★ 铁律 C：全程**不自动弹窗**。v1.4.x 的「首次拦截后 2.5 秒自动弹」是
//            「搜索进视频闪退」的头号嫌疑：拦截发生时用户刚好点进视频，
//            2 秒后正好落在页面转场动画里 present alert → UIKit 崩。
//
//  ══ 安全阀（纯本地逻辑，不与 App 交互，零风险）═════════════════════════
//    阀① 启动宽限：插件生效后 20 秒内一律放行 → 保证首屏一定能加载出来
//    阀③ 重试熔断：3 秒内被拦 > 6 次 → 静默 30 秒（防 App 重试循环被反复吃掉）
//    （v1.4.x 的「每页首次放行」已去掉 —— 它会让「返回首页」那一次被放过）
//
//    ★ 共同原则：任何异常一律放行。宁可漏拦，绝不卡界面。
//
//  ══ 已知问题（本版刻意不治，留作下一步单独处理）════════════════════════
//    「拦截后列表停在半拉状态，向上划一下恢复」。
//    成因：B站是**先直接把列表拉进下拉区、再调 beginRefreshing**。我们拦掉后者，
//    前者就没人负责收回。
//    收尾必须写几何值 → 高风险（v1.4.0 的教训）→ 所以**先确认本版不闪退**，
//    再单独加「一次性收尾」，一次只动一个变量。
//
//  ══ 诊断 ════════════════════════════════════════════════════════════════
//    · **不自动弹窗**。只有「切到别的 App 再切回来」时才弹一次统计。
//    · 弹窗前会检查：有窗口、不在转场动画中、不在 present/dismiss 过程中。
//    · 日志写在 B站沙盒 Documents/BNR_fix.log（低频：只在放行/拦截时写）。
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <ctype.h>

#pragma mark - 配置

static BOOL kBlockRefresh = YES;    // 总闸：NO = 只观察不拦（排障用）
static BOOL kShowAlert    = YES;    // 关掉 = 不弹统计窗（拦截能力不受影响）
static BOOL kProbeTrigger = YES;    // 记录刷新来源（哪个页面 + 调用栈）

// 安全阀
static BOOL   kStartupGrace     = YES;   // 阀①
static double kStartupGraceSecs = 20.0;
static BOOL   kBreakRetryLoop   = YES;   // 阀③
static double kCooldownSecs     = 30.0;

static const char *kTargetBundle = "tv.danmaku.bilianime";
static const char *kVersion      = "1.5.0";

// 刷新状态取值（MJRefresh / BFCRefresh 系列：Idle=1 Pulling=2 Refreshing=3 WillRefresh=4 NoMoreData=5）
static const NSInteger kStatePulling = 2;

#pragma mark - 类型垫片
// 用 @protocol 声明要调的外部方法：拿到完整类型，且不把 objc_msgSend 强转成函数指针。

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

// 上拉加载更多用的 footer 一律不拦
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

// 某个 view 挂在哪个 VC 上（沿响应链往上找），只用于日志辨认「是哪一页在下拉」
static UIViewController *BNRViewControllerOf(UIView *v) {
    id r = v;
    for (int i = 0; i < 12 && r; i++) {
        if ([r isKindOfClass:[UIViewController class]]) return (UIViewController *)r;
        if (![r isKindOfClass:[UIResponder class]]) break;
        r = [(UIResponder *)r nextResponder];
    }
    return nil;
}

#pragma mark - 日志（低频：只在放行/拦截时写）

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
static int  gCooldownHits = 0;    // 熔断触发次数
static BOOL gInstalled    = NO;

static NSTimeInterval gStartTime     = 0;   // 插件生效时刻（宽限期基准）
static NSTimeInterval gLastAllow     = 0;   // 上次放行用户刷新的时间
static NSTimeInterval gCooldownUntil = 0;   // 熔断静默截止时间
static NSTimeInterval gBlockWinStart = 0;   // 熔断统计窗口起点
static int            gBlockInWindow = 0;

static NSMutableArray *gHookedNames = nil;
static NSMutableArray *gFound       = nil;   // 来源取证（最多 4 条）
static NSTimeInterval  gFoundLast   = 0;

static void BNRShowStats(void);   // 前置声明（定义在后面）

#pragma mark - 刷新控件判定

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

// 这一页是谁？（宿主 VC 的类名）—— 认不出返回 nil
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

static BOOL BNRShouldBlock(id comp, NSString *what) {
    if (!kBlockRefresh) return NO;

    @try {
        if (BNRIsFooter(comp)) return NO;      // 上拉加载更多：放行
    } @catch (NSException *e) { (void)e; return NO; }

    @try {
        if (BNRIsUserDriven(comp)) return NO;  // 用户自己在下拉：放行
    } @catch (NSException *e) { (void)e; return NO; }

    NSTimeInterval now = BNRNow();

    // 阀① 启动宽限：保证首屏一定能加载出来
    if (kStartupGrace && (now - gStartTime) < kStartupGraceSecs) return NO;

    // 阀③ 熔断静默期：App 正在重试循环 → 全部放行，先让它缓过来
    if (kBreakRetryLoop && now < gCooldownUntil) return NO;

    return YES;   // 唯一会拦的分支：非用户触发 + 非 footer + 已过宽限 + 不在熔断期
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

#pragma mark - 唯一的钩子：-beginRefreshing

static void BNRHookedBeginRefreshing(id self, SEL _cmd) {
    __sync_fetch_and_add(&gSeenBegin, 1);

    if (BNRShouldBlock(self, @"beginRefreshing")) {
        __sync_fetch_and_add(&gBlockedBegin, 1);
        BNRNoteBlocked();
        if (gBlockedBegin <= 20) {
            BNRLogLine(@"⛔️ 拦截 beginRefreshing → %@  页面: %@",
                       BNRClassName(self), BNRPageOf(self) ?: @"(未识别)");
        }
        BNRRecordEvent([NSString stringWithFormat:@"beginRefreshing @ %@", BNRClassName(self)],
                       BNRPageOf(self), YES);
        // ★ 到此为止：不写几何值、不代叫任何 App 的语义 API、不弹窗。
        return;
    }

    __sync_fetch_and_add(&gAllowBegin, 1);
    gLastAllow = BNRNow();
    if (gAllowBegin <= 12) {
        BNRLogLine(@"✅ 放行 beginRefreshing → %@  页面: %@",
                   BNRClassName(self), BNRPageOf(self) ?: @"(未识别)");
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
    // ★ 本版**只挂这一个方法**，绝不挂任何 UIScrollView 的全局方法、也绝不挂 -setState:
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
    BNRLogLine(@"=== 安全阀：启动宽限 %.0fs / 重试熔断 %@(%.0fs)",
               kStartupGraceSecs, kBreakRetryLoop ? @"开" : @"关", kCooldownSecs);
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
             "最近一次放行用户刷新: %@\n\n"
             "挂钩的类:\n%@\n\n"
             "谁在触发刷新:\n%@",
            gHooked, valve, gSeenBegin, gAllowBegin, gBlockedBegin, lastAllow, cls, hints];

        BNRLogLine(@"--- 前台统计：钩=%d 见=%d 放行=%d 吃掉=%d",
                   gHooked, gSeenBegin, gAllowBegin, gBlockedBegin);
        BNRAlert([NSString stringWithFormat:@"BiliNoRefresh v%s 统计", kVersion], msg, @"好");
    } @catch (NSException *e) { (void)e; }
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
