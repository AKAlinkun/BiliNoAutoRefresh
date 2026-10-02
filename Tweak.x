//
//  Tweak.x
//  BiliNoAutoRefresh v1.3.0 —— 三档自检版
//
//  ── 为什么推倒重来 ──────────────────────────────────────────────────────
//  v1.1.0（启动即扫类表 + 批量换实现）和 v1.2.0（延后安装）**都闪退**。
//  说明「安装时机」不是唯一变量。必须把变量一个个摘掉，分辨到底哪一层出问题。
//
//  本版做了三件事，把风险面压到最小：
//    1. **一个 Logos %hook 都不用**（连 UIRefreshControl 也去掉）→ 编译产物不再引用
//       substrate 符号，Makefile 里再加 -Wl,-dead_strip_dylibs 把 libsubstrate 从依赖表里
//       摘掉 → TrollFools 不会再注入 CydiaSubstrate。等于把 substrate 这一层整个移出等式。
//       拦截能力改由纯 objc runtime（method_setImplementation）提供，效果一样。
//    2. **不做任何时序猜测**：启动后弹第 ① 个窗，你点「继续」才做第 ② 步，再点才做第 ③ 步。
//       哪一步点完闪退，就是哪一层的锅 —— 不用猜。
//    3. 每一步都先写日志再弹窗，日志在 Documents/BNR_step.log（Filza 可看）。
//
//  ── 三档分别是 ─────────────────────────────────────────────────────────
//    ① 存活确认：什么都不做，只报 bundle + 几个关键类是否存在（这一步崩 = 注入层问题）
//    ② 只读扫描：objc_copyClassList 遍历全机类表，只读不写，报告发现哪些刷新控件
//    ③ 安装闸门：只对 -beginRefreshing 换实现（不碰 setState:），报告挂钩数量
//
//  ⚠️ 诊断版：会弹 3 个窗，之后每次切回前台还弹一次统计。定案后把 kShowAlert 改 NO 即可。
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <ctype.h>

#pragma mark - 开关

static BOOL kBlockRefresh = YES;   // 第 ③ 档才用到
static BOOL kShowAlert    = YES;   // 关掉它 = 不弹窗（拦截功能不受影响）

static const char *kTargetBundle = "tv.danmaku.bilianime";
static const char *kVersion      = "1.3.0-t3";

// MJRefreshState 取值（取自 MJRefresh 源码）
static const NSInteger kStatePulling = 2;

#pragma mark - 类型垫片
// 用协议声明要调的外部方法：拿到完整类型，且**不用把 objc_msgSend 强转成函数指针**
// （ARC 下函数指针返回值所有权会算错，这里避开）。

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

#pragma mark - 日志（全程只写 3~6 次，不在任何热路径里）

static NSString *BNRLogPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/BNR_step.log"];
}

static void BNRLogLine(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSLog(@"[BNR] %@", msg);        // 同时进系统日志

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

#pragma mark - 刷新状态判定

static BOOL BNRIsFooter(id comp) {
    const char *n = BNRClassNameC(comp);
    return n && strstr(n, "Footer") != NULL;      // 上拉加载更多用的 footer 一律不拦
}

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

// 用户正在拖屏幕 → 这是手动下拉，必须放行
static BOOL BNRIsUserDriven(id comp) {
    if (BNRStateOf(comp) == kStatePulling) return YES;
    UIScrollView *sv = BNRScrollViewOf(comp);
    if (sv && (sv.isDragging || sv.isTracking || sv.isDecelerating)) return YES;
    return NO;
}

#pragma mark - 方法签名校验（防止参数错位崩溃）

static const char *BNRNextType(const char *t) {
    if (!t) return NULL;
    while (*t && isdigit((unsigned char)*t)) t++;
    return (*t) ? t : NULL;
}

// -(void)foo  → v@:
static BOOL BNREncVoidNoArg(const char *t) {
    const char *p = BNRNextType(t);    if (!p || *p != 'v') return NO;
    p = BNRNextType(p + 1);            if (!p || *p != '@') return NO;
    p = BNRNextType(p + 1);            if (!p || *p != ':') return NO;
    p = BNRNextType(p + 1);
    return (p == NULL);
}

// -(void)foo:(NSInteger)x → v@:q （本版暂未用到，留着下一档用）
__attribute__((unused))
static BOOL BNREncVoidIntegerArg(const char *t) {
    const char *p = BNRNextType(t);    if (!p || *p != 'v') return NO;
    p = BNRNextType(p + 1);            if (!p || *p != '@') return NO;
    p = BNRNextType(p + 1);            if (!p || *p != ':') return NO;
    p = BNRNextType(p + 1);            if (!p) return NO;
    char r = *p;
    if (!(r == 'q' || r == 'Q' || r == 'i' || r == 'I' ||
          r == 'l' || r == 'L' || r == 's' || r == 'S' || r == 'c' || r == 'C')) return NO;
    p = BNRNextType(p + 1);
    return (p == NULL);
}

#pragma mark - 闸门（纯 runtime，不用 substrate）

typedef struct { Class cls; IMP imp; } BNRPatch;
static BNRPatch gPatches[32];
static int      gPatchCount = 0;
static int      gBlocked    = 0;
static int      gHooked     = 0;

static IMP BNROrigFor(id self) {
    Class c = object_getClass(self);
    for (Class k = c; k != Nil; k = class_getSuperclass(k)) {
        for (int i = 0; i < gPatchCount; i++) {
            if (gPatches[i].cls == k) return gPatches[i].imp;
        }
    }
    return NULL;
}

static void BNRHookedBeginRefreshing(id self, SEL _cmd) {
    BOOL block = NO;
    if (kBlockRefresh) {
        @try {
            if (!BNRIsFooter(self) && !BNRIsUserDriven(self)) block = YES;
        } @catch (NSException *e) { (void)e; block = NO; }
    }
    if (block) {
        __sync_fetch_and_add(&gBlocked, 1);
        BNRLogLine(@"⛔️ 吃掉自动刷新 beginRefreshing → %@", BNRClassName(self));
        return;
    }
    IMP orig = BNROrigFor(self);
    if (orig) ((void (*)(id, SEL))orig)(self, _cmd);
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

static BOOL BNRNameLooksLikeRefresh(const char *n) {
    if (!n) return NO;
    return (strstr(n, "Refresh") != NULL) || (strstr(n, "PullToRefresh") != NULL);
}

#pragma mark - 弹窗（每一步由用户点「继续」推进，杜绝时序竞争）

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

static void BNRAlert(NSString *title, NSString *msg, NSString *btn, void (^after)(void));

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

#pragma mark - 第 ① 档：存活确认（不做任何实质动作）

static void BNRStep2(void);

static void BNRStep1(void) {
    NSString *bid = @"(取不到)";
    @try { bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"(nil)"; } @catch (NSException *e) { (void)e; }

    // 安全网：只在哔哩哔哩进程里动作
    if (![bid isEqualToString:[NSString stringWithUTF8String:kTargetBundle]]) {
        BNRLogLine(@"非目标 App（%@），什么都不做", bid);
        return;
    }

    NSMutableString *m = [NSMutableString string];
    [m appendFormat:@"版本 %s 已注入并运行。\n\n", kVersion];
    [m appendFormat:@"bundle: %@\n\n", bid];
    [m appendString:@"关键类探测（决定下一步能不能找到刷新控件）:\n"];

    NSArray *names = @[@"MJRefreshHeader", @"MJRefreshComponent", @"MJRefreshFooter",
                       @"MJRefreshNormalHeader", @"UIRefreshControl"];
    NSMutableArray *log = [NSMutableArray array];
    for (NSString *n in names) {
        Class c = objc_getClass(n.UTF8String);
        [m appendFormat:@"%@ : %@\n", n, c ? @"✅ 存在" : @"❌ 不存在"];
        [log addObject:[NSString stringWithFormat:@"%@=%@", n, c ? @"Y" : @"N"]];
    }

    BNRLogLine(@"=== 第①档 存活确认：bundle=%@  %@", bid, [log componentsJoinedByString:@" "]);
    [m appendString:@"\n点「继续」进入第 ② 档（只读扫描类表，不修改任何东西）"];

    BNRAlert([NSString stringWithFormat:@"① 存活确认  v%s", kVersion], m, @"继续", ^{ BNRStep2(); });
}

#pragma mark - 第 ② 档：只读扫描（绝不修改任何实现）

static void BNRStep3(void);

static void BNRStep2(void) {
    NSMutableArray *hits = [NSMutableArray array];
    unsigned int count = 0;
    Class *list = objc_copyClassList(&count);

    if (list) {
        for (unsigned int i = 0; i < count; i++) {
            Class c = list[i];
            const char *nm = class_getName(c);
            if (!BNRNameLooksLikeRefresh(nm)) continue;

            SEL sBegin = @selector(beginRefreshing);
            SEL sSet   = sel_registerName("setState:");
            BOOL ownBegin = (BNROwnerOfSEL(c, sBegin) == c);
            BOOL ownSet   = (BNROwnerOfSEL(c, sSet) == c);
            Method mb = class_getInstanceMethod(c, sBegin);
            Method ms = class_getInstanceMethod(c, sSet);
            const char *tb = mb ? method_getTypeEncoding(mb) : NULL;
            const char *ts = ms ? method_getTypeEncoding(ms) : NULL;

            [hits addObject:[NSString stringWithFormat:
                @"%@\n   begin:%@ (%s)   setState:%@ (%s)", @(nm),
                ownBegin ? @"自实现" : @"继承", tb ? tb : "-",
                ownSet ? @"自实现" : @"继承", ts ? ts : "-"]];
        }
        free(list);
    }

    NSString *body = hits.count ? [hits componentsJoinedByString:@"\n"] : @"（一个都没找到）";
    BNRLogLine(@"=== 第②档 只读扫描：类表总数=%u，疑似刷新类=%lu\n%@",
               count, (unsigned long)hits.count, body);

    NSArray *shown = hits.count > 6 ? [hits subarrayWithRange:NSMakeRange(0, 6)] : hits;
    NSString *msg = [NSString stringWithFormat:
        @"类表总数: %u\n疑似刷新控件类: %lu 个\n\n%@%@\n\n点「继续」进入第 ③ 档（真正安装闸门）",
        count, (unsigned long)hits.count,
        [shown componentsJoinedByString:@"\n"],
        hits.count > 6 ? [NSString stringWithFormat:@"\n…(共%lu个)", (unsigned long)hits.count] : @""];

    BNRAlert(@"② 只读扫描完成", msg, @"继续", ^{ BNRStep3(); });
}

#pragma mark - 第 ③ 档：安装闸门（只换 beginRefreshing）

static NSMutableArray *gHookedNames = nil;

static void BNRStep3(void) {
    unsigned int count = 0;
    Class *list = objc_copyClassList(&count);
    SEL sBegin = @selector(beginRefreshing);
    NSMutableArray *hooked  = [NSMutableArray array];
    NSMutableArray *skipped = [NSMutableArray array];

    if (list) {
        for (unsigned int i = 0; i < count; i++) {
            Class c = list[i];
            const char *nm = class_getName(c);
            if (!BNRNameLooksLikeRefresh(nm)) continue;
            if (BNROwnerOfSEL(c, sBegin) != c) continue;      // 只改「自己实现」的

            Method m = class_getInstanceMethod(c, sBegin);
            const char *t = m ? method_getTypeEncoding(m) : NULL;
            if (!BNREncVoidNoArg(t)) {
                [skipped addObject:[NSString stringWithFormat:@"%s 签名不符(%s)", nm, t ? t : "-"]];
                continue;
            }
            if (gPatchCount >= 32) break;

            IMP old = method_setImplementation(m, (IMP)&BNRHookedBeginRefreshing);
            if (!old || old == (IMP)&BNRHookedBeginRefreshing) continue;
            gPatches[gPatchCount].cls = c;
            gPatches[gPatchCount].imp = old;
            gPatchCount++;
            __sync_fetch_and_add(&gHooked, 1);
            [hooked addObject:@(nm)];
        }
        free(list);
    }

    gHookedNames = hooked;

    BNRLogLine(@"=== 第③档 安装闸门：挂钩 %lu 个 → %@   %@",
               (unsigned long)hooked.count,
               hooked.count ? [hooked componentsJoinedByString:@", "] : @"(无)",
               skipped.count ? [skipped componentsJoinedByString:@", "] : @"");

    NSString *msg = [NSString stringWithFormat:
        @"已挂钩 -beginRefreshing 的类: %lu 个\n%@\n%@\n\n%@",
        (unsigned long)hooked.count,
        hooked.count ? [hooked componentsJoinedByString:@"\n"] : @"（无）",
        skipped.count ? [NSString stringWithFormat:@"跳过: %@", [skipped componentsJoinedByString:@"\n"]] : @"",
        (hooked.count > 0)
            ? @"接着做两件事，然后切后台再切回来，我会报拦截次数：\n1) 搜索 → 点视频 → 播放 → 返回首页\n2) 首页手动下拉一次，确认手动刷新还能用"
            : @"⚠️ 一个都没挂上：刷新控件类名不含 Refresh，需要换策略"];

    BNRAlert(@"③ 闸门安装完成", msg, @"好", ^{
        // 装好后：每次切回前台报一次统计，方便截图
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            (void)note;
            NSString *s = [NSString stringWithFormat:
                @"已挂钩方法: %d 个\n已拦截自动刷新: %d 次\n\n挂钩的类:\n%@\n\n若始终为 0，说明首页刷新不走 beginRefreshing",
                gHooked, gBlocked,
                gHookedNames.count ? [gHookedNames componentsJoinedByString:@"\n"] : @"(无)"];
            BNRLogLine(@"--- 切回前台统计：挂钩=%d 拦截=%d", gHooked, gBlocked);
            BNRAlert(@"BiliNoRefresh 统计", s, @"好", nil);
        }];
    });
}

#pragma mark - 加载入口
// ⚠️ dyld 阶段只排一个延后任务，绝不碰运行时、绝不弹窗。

__attribute__((constructor))
static void BNRInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ BNRStep1(); });
}
