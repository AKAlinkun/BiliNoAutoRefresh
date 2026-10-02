//
//  Tweak.x  —— BiliNoAutoRefresh v1.4.0
//
//  ── 这一版为什么这么写（先看结论）────────────────────────────────────────
//  v1.3.0 实测结果：**不闪退**，而且闸门真的装上了：
//      BPlusBaseRefreshComponent / BFCRefreshComponent /
//      BFCRefreshAutoFooter / UIRefreshControl   共 4 个钩子。
//  一次解决两个悬案：
//    ① 闪退的锅在「Logos %hook + TrollFools 注入的 CydiaSubstrate」这条线上，
//       跟安装时机/时序无关 —— 零 Logos 之后就再没崩过。
//       所以本版**继续保持零 Logos**，全部用 objc runtime 动态挂钩。
//    ② B站不用 MJRefresh，用的是自研 BFCRefresh（类名带 BFC / BPlus 前缀）。
//
//  实测新现象：**返回首页时会往下拉一下、但不刷新，然后卡住**。
//  原因很清楚：App 先把列表拉到「下拉区」，等 header 进入刷新态再自动收回；
//  而我把 header 的刷新入口吃掉了 → header 永远进不了刷新态 → 没人负责收回 → 卡住。
//  所以本版在拦截之后**主动收尾**（BNRUnstick）：还原被抬高的顶部内边距 +
//  把 contentOffset 拉回正常顶部。用户看到的效果 = 什么都没发生。
//
//  ── 本版四道防线 ────────────────────────────────────────────────────────
//  ① 拦 -beginRefreshing / -setState:Refreshing —— 只在「不是用户自己在拖」时吃掉
//  ② 拦 UIScrollView -setContentOffset:animated: —— 非拖拽状态下，把「拉进下拉区」
//     的偏移直接夹回正常顶部 → 那一下下拉根本不出现
//  ③ 拦 UIScrollView -setContentInset: —— 非拖拽状态下被抬高 >20pt 的「伪下拉」不生效
//  ④ 兜底收尾 BNRUnstick：每次拦截后 0.08s + 0.6s 各做一次几何复位，保证绝不卡住
//
//  取证：kProbeTrigger=YES 会记录「程序化下拉」的来源（宿主 VC + 调用栈，最多 6 条），
//        切回前台时显示在弹窗里 —— 用来最终确认到底是谁在下拉。
//
//  ⚠️ 仍然是诊断版：每次切回前台弹一次统计。定案后把 kShowAlert 改 NO 即可。
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <ctype.h>

#pragma mark - 开关

static BOOL kBlockRefresh  = YES;   // 总闸：吃掉非用户触发的刷新
static BOOL kBlockFakePull = YES;   // 不吃「抬高顶部内边距」这种伪下拉
static BOOL kShowAlert     = YES;   // 关掉 = 不弹窗（拦截能力不受影响）
static BOOL kProbeTrigger  = YES;   // 记录程序化下拉的来源（取证用，最多 6 条）

static const char *kTargetBundle = "tv.danmaku.bilianime";
static const char *kVersion      = "1.4.0";

// 刷新状态取值（与 MJRefresh / BFCRefresh 一致）
static const NSInteger kStatePulling    = 2;
static const NSInteger kStateRefreshing = 3;

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

// 某个 view 挂在哪个 VC 上（沿响应链往上找），用来辨认「是谁在下拉」
static UIViewController *BNRViewControllerOf(UIView *v) {
    id r = v;
    for (int i = 0; i < 12 && r; i++) {
        if ([r isKindOfClass:[UIViewController class]]) return (UIViewController *)r;
        if (![r isKindOfClass:[UIResponder class]]) break;
        r = [(UIResponder *)r nextResponder];
    }
    return nil;
}

// 这个滚动视图里有没有「刷新控件」的影子（类名带 Refresh / BFC / BPlus）
static BOOL BNRHasRefreshHeader(UIScrollView *sv) {
    for (UIView *v in sv.subviews) {
        const char *n = BNRClassNameC(v);
        if (!n) continue;
        if (strstr(n, "Refresh") || strstr(n, "BFC") || strstr(n, "BPlus")) return YES;
    }
    return NO;
}

// 这个滚动视图里有没有「正在刷新」的刷新控件（有 = 真刷新，别乱动它）
static BOOL BNRAnyRefreshingIn(UIScrollView *sv) {
    for (UIView *v in sv.subviews) {
        const char *n = BNRClassNameC(v);
        if (!n || !BNRNameLooksLikeRefresh(n)) continue;
        @try {
            id p = (id<BNRRefreshLike>)v;
            if ([p respondsToSelector:@selector(state)] && [p state] == kStateRefreshing) return YES;
        } @catch (NSException *e) { (void)e; }
    }
    return NO;
}

#pragma mark - 日志（低频：只在拦截/复位/取证时写）

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

#pragma mark - 计数器 / 取证

static int  gHooked       = 0;
static int  gBlockedBegin = 0;
static int  gBlockedState = 0;
static int  gClamped      = 0;
static int  gUnstuck      = 0;
static BOOL gInstalled    = NO;
static BOOL gSuppress     = NO;   // 我们自己复位时，跳过闸门逻辑（防自激）

static NSMutableArray *gHookedNames  = nil;
static NSMutableArray *gTriggerHints = nil;
static NSTimeInterval  gLastHintTime = 0;

#pragma mark - 刷新状态判定

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

#pragma mark - 方法签名校验（防参数错位崩溃）

static const char *BNRNextType(const char *t) {
    if (!t) return NULL;
    while (*t && isdigit((unsigned char)*t)) t++;
    return (*t) ? t : NULL;
}

typedef enum {
    BNRSigVoidNoArg = 0,       // v@:
    BNRSigVoidIntArg,          // v@:q  / v@:i / v@:l …
    BNRSigVoidPointBool,       // v@:{CGPoint=dd}B
    BNRSigVoidEdgeInsets       // v@:{UIEdgeInsets=dddd}
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

        case BNRSigVoidPointBool: {
            if (!p || *p != '{') return NO;
            int depth = 0;
            while (*p) {
                if (*p == '{') depth++;
                else if (*p == '}') { depth--; p++; if (depth == 0) break; }
                else p++;
            }
            p = BNRNextType(p);
            return (p && *p == 'B' && BNRNextType(p + 1) == NULL);
        }

        case BNRSigVoidEdgeInsets: {
            if (!p || *p != '{') return NO;
            int depth = 0;
            while (*p) {
                if (*p == '{') depth++;
                else if (*p == '}') { depth--; p++; if (depth == 0) break; }
                else p++;
            }
            return (BNRNextType(p) == NULL);
        }
    }
    return NO;
}

#pragma mark - 动态挂钩表（(类, 方法) 双键；不用 Logos、不用 substrate）

typedef struct { Class cls; SEL sel; IMP imp; } BNRPatch;
static BNRPatch gPatches[64];
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
    if (gPatchCount >= 64)    { if (why) *why = "表满";   return NO; }

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

#pragma mark - 取证：记录「程序化下拉」的来源

static void BNRRecordHint(NSString *what, UIScrollView *sv, double v) {
    if (!kProbeTrigger) return;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - gLastHintTime < 2.0) return;      // 节流：最多每 2 秒记一条
    gLastHintTime = now;

    @try {
        if (!gTriggerHints) gTriggerHints = [NSMutableArray array];
        if (gTriggerHints.count >= 6) return;   // 只留 6 条

        UIViewController *vc = BNRViewControllerOf(sv);
        NSMutableArray *frames = [NSMutableArray array];
        for (NSString *s in [NSThread callStackSymbols]) {
            if ([s containsString:@"BNRHooked"] || [s containsString:@"BNRRecordHint"]) continue;
            [frames addObject:s];
            if (frames.count >= 8) break;
        }
        NSString *line = [NSString stringWithFormat:@"%@ (%.0f) 宿主VC: %@\n%@",
                          what, v,
                          vc ? NSStringFromClass([vc class]) : @"(未知)",
                          [frames componentsJoinedByString:@"\n    ← "]];
        [gTriggerHints addObject:line];
        BNRLogLine(@"🔎 %@", line);
    } @catch (NSException *e) { (void)e; }
}

#pragma mark - 兜底收尾：把「拉到一半的刷新」复位
// 拦截之后必须有人负责收尾，否则就是用户看到的「卡住」。
// 两件事：① 还原被抬高的顶部内边距；② contentOffset 拉回正常顶部。
// 0.08s 做一次（拦截当下），0.6s 再看一眼（应对 App 随后才动的动画）。

static void BNRUnstickPass(id comp) {
    if (!comp) return;
    @try {
        UIScrollView *sv = BNRScrollViewOf(comp);
        if (!sv) return;
        if (sv.isDragging || sv.isTracking || sv.isDecelerating) return;  // 用户正在动，别插手

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
            BNRLogLine(@"🧹 收尾复位 → %@ (offset %.1f → %.1f)", BNRClassName(comp), p.y, top);
        }
    } @catch (NSException *e) { (void)e; }
}

static void BNRUnstick(id comp) {
    if (!comp) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ BNRUnstickPass(comp); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.60 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ BNRUnstickPass(comp); });
}

#pragma mark - 闸门本体

// ① -beginRefreshing
static void BNRHookedBeginRefreshing(id self, SEL _cmd) {
    BOOL block = NO;
    if (kBlockRefresh) {
        @try {
            if (!BNRIsFooter(self) && !BNRIsUserDriven(self)) block = YES;
        } @catch (NSException *e) { (void)e; block = NO; }
    }
    if (block) {
        int n = __sync_fetch_and_add(&gBlockedBegin, 1);
        if (n < 20) BNRLogLine(@"⛔️ 拦截 beginRefreshing → %@", BNRClassName(self));
        BNRUnstick(self);
        return;
    }
    IMP orig = BNROrigFor(self, _cmd);
    if (orig) ((void (*)(id, SEL))orig)(self, _cmd);
}

// ② -setState:（有的实现直接置 Refreshing，不走 beginRefreshing）
static void BNRHookedSetState(id self, SEL _cmd, NSInteger newState) {
    BOOL block = NO;
    if (kBlockRefresh && newState == kStateRefreshing) {
        @try {
            if (!BNRIsFooter(self) && !BNRIsUserDriven(self)) block = YES;
        } @catch (NSException *e) { (void)e; block = NO; }
    }
    if (block) {
        int n = __sync_fetch_and_add(&gBlockedState, 1);
        if (n < 20) BNRLogLine(@"⛔️ 拦截 setState:Refreshing → %@", BNRClassName(self));
        BNRUnstick(self);
        return;
    }
    IMP orig = BNROrigFor(self, _cmd);
    if (orig) ((void (*)(id, SEL, NSInteger))orig)(self, _cmd, newState);
}

// ③ UIScrollView -setContentOffset:animated: —— 非拖拽状态下把「拉进下拉区」夹回顶部
static void BNRHookedSetContentOffset(id self, SEL _cmd, CGPoint offset, BOOL animated) {
    IMP orig = BNROrigFor(self, _cmd);
    if (kBlockRefresh && !gSuppress && [self isKindOfClass:[UIScrollView class]]) {
        @try {
            UIScrollView *sv = (UIScrollView *)self;
            if (!sv.isDragging && !sv.isTracking && !sv.isDecelerating) {
                CGFloat top = -(sv.adjustedContentInset.top);
                if (offset.y < top - 6.0 && BNRHasRefreshHeader(sv)) {
                    if (offset.y < top - 30.0) BNRRecordHint(@"程序化下拉偏移", sv, top - offset.y);
                    __sync_fetch_and_add(&gClamped, 1);
                    offset.y = top;                      // 夹回正常顶部
                }
            }
        } @catch (NSException *e) { (void)e; }
    }
    if (orig) ((void (*)(id, SEL, CGPoint, BOOL))orig)(self, _cmd, offset, animated);
}

// ④ UIScrollView -setContentInset: —— 非拖拽状态下「抬高顶部内边距来伪下拉」的不生效
static void BNRHookedSetContentInset(id self, SEL _cmd, UIEdgeInsets inset) {
    IMP orig = BNROrigFor(self, _cmd);
    if (kBlockFakePull && !gSuppress && [self isKindOfClass:[UIScrollView class]]) {
        @try {
            UIScrollView *sv = (UIScrollView *)self;
            if (!sv.isDragging && !sv.isTracking && !sv.isDecelerating) {
                UIEdgeInsets cur = sv.contentInset;
                CGFloat delta = inset.top - cur.top;
                if (delta > 20.0 && BNRHasRefreshHeader(sv) && !BNRAnyRefreshingIn(sv)) {
                    BNRRecordHint(@"抬高顶部内边距", sv, delta);
                    inset.top = cur.top;                 // 只回滚 top，其余照旧
                    __sync_fetch_and_add(&gClamped, 1);
                }
            }
        } @catch (NSException *e) { (void)e; }
    }
    if (orig) ((void (*)(id, SEL, UIEdgeInsets))orig)(self, _cmd, inset);
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

    // A. 刷新控件类：beginRefreshing + setState:（扫全机类表，改名前缀也能命中）
    unsigned int count = 0;
    Class *list = objc_copyClassList(&count);
    if (list) {
        for (unsigned int i = 0; i < count; i++) {
            Class c = list[i];
            const char *nm = class_getName(c);
            if (!BNRNameLooksLikeRefresh(nm)) continue;

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

    // B. 滚动视图：两道几何防线
    Class uv = [UIScrollView class];
    const char *w2 = NULL;
    if (BNRPatchMethod(uv, @selector(setContentOffset:animated:),
                       (IMP)&BNRHookedSetContentOffset, BNRSigVoidPointBool, &w2)) {
        gHooked++; n++; [names addObject:@"UIScrollView -setContentOffset:animated:"];
    } else if (w2) {
        [notes addObject:[NSString stringWithFormat:@"UIScrollView -setContentOffset: 跳过(%s)", w2]];
    }

    w2 = NULL;
    if (BNRPatchMethod(uv, @selector(setContentInset:),
                       (IMP)&BNRHookedSetContentInset, BNRSigVoidEdgeInsets, &w2)) {
        gHooked++; n++; [names addObject:@"UIScrollView -setContentInset:"];
    } else if (w2) {
        [notes addObject:[NSString stringWithFormat:@"UIScrollView -setContentInset: 跳过(%s)", w2]];
    }

    gHookedNames = names;
    BNRLogLine(@"=== v%s 闸门安装：%d 个 → %@  %@", kVersion, n,
               names.count ? [names componentsJoinedByString:@", "] : @"(无)",
               notes.count ? [notes componentsJoinedByString:@"; "] : @"");
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
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
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
    BNRAlertRetry(title, msg, btn, after, 8);
}

static void BNRShowStats(void) {
    @try {
        NSString *cls   = gHookedNames.count ? [gHookedNames componentsJoinedByString:@"\n"] : @"(无)";
        NSString *hints = gTriggerHints.count ? [gTriggerHints componentsJoinedByString:@"\n\n"] : @"(还没捕捉到)";
        NSString *msg = [NSString stringWithFormat:
            @"挂钩 %d 个\n"
             "拦 beginRefreshing: %d\n"
             "拦 setState:Refreshing: %d\n"
             "夹回下拉偏移/伪下拉: %d\n"
             "自动收尾复位: %d\n\n"
             "挂钩的类:\n%@\n\n"
             "捕捉到的程序化下拉来源:\n%@",
            gHooked, gBlockedBegin, gBlockedState, gClamped, gUnstuck, cls, hints];
        BNRLogLine(@"--- 前台统计：挂钩=%d 拦begin=%d 拦state=%d 夹回=%d 复位=%d",
                   gHooked, gBlockedBegin, gBlockedState, gClamped, gUnstuck);
        BNRAlert([NSString stringWithFormat:@"BiliNoRefresh v%s 统计", kVersion], msg, @"好", nil);
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
        BOOL ready = (objc_getClass("BFCRefreshComponent")    != NULL) ||
                     (objc_getClass("BPlusBaseRefreshComponent") != NULL) ||
                     (objc_getClass("MJRefreshHeader")        != NULL);
        if (!ready && tries < 10) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ BNRInstallWhenReady(tries + 1); });
            return;
        }

        BNRInstallGates();

        // 装好后：每次切回前台报一次统计，方便截图（冷启动那次不会触发）
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
