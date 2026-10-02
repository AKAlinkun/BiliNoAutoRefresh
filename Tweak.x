//
//  Tweak.x
//  BiliNoAutoRefresh v1.2.0 —— 防崩溃重构版
//
//  ── v1.1.0 为什么会让 App 启动闪退 ─────────────────────────────────────
//  v1.1.0 把「遍历全机类表 + 批量替换方法实现」放进了 __attribute__((constructor))。
//  构造函数跑在 dyld 加载阶段 —— 那一刻 Objective-C 运行时还没稳定，App 自己的库
//  （含 MJRefresh）也还没加载完。在这种时机调 objc_copyClassList() 会强制 realize
//  所有已注册的类，再叠上 method_setImplementation() 批量改写方法实现，
//  极易在启动瞬间把某个类改坏 → 进程被直接杀掉，表现就是「点开就闪退」。
//
//  ── v1.2.0 相对上一版的六处改动 ─────────────────────────────────────────
//   1. 构造函数里【只】排一个延后任务，绝不碰运行时。安装推迟到启动完成 + 2 秒，且带
//      重试 —— 这时 B站的库才加载完，也才扫得到 MJRefresh（上一版「没生效」多半就栽在这）。
//   2. 动态换实现前【校验方法签名】(v@: / v@:q)，签名不符的一律不碰，杜绝参数错位崩溃。
//   3. 只改「自己实现了该方法」的类，不再误改父类共享的 Method 影响一堆兄弟类。
//   4. 去掉最危险的探针：不再 hook NSNotificationCenter（启动期高频 + 递归风险）。
//   5. 日志只进内存，弹窗时才落盘 —— 热路径里不再有任何文件 I/O。
//   6. 只在哔哩哔哩里动作；诊断弹窗跳过「冷启动那次激活」，绝不干扰启动过程。
//
//  ⚠️ 诊断期开关：kShowAlert / kDebugFile 开着，拿到结论后要关掉。
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <ctype.h>

#pragma mark - 开关

static BOOL kEnabled      = YES;   // 总开关：NO = 整个插件什么都不做
static BOOL kBlockRefresh = YES;   // 拦截「非用户触发」的自动刷新
static BOOL kShowAlert    = YES;   // 诊断期：切后台再切回来时弹窗汇报
static BOOL kDebugFile    = YES;   // 诊断期：弹窗时把内存日志落盘，方便细看
static BOOL kProbeVC      = YES;   // 探针：记录关键页面生命周期
static BOOL kProbeReload  = YES;   // 探针：记录关键列表的 reloadData

static const char *kTargetBundle = "tv.danmaku.bilianime";

// MJRefreshState 取值（取自 MJRefresh 源码，别改）
static const NSInteger kStateIdle    = 1;
static const NSInteger kStatePulling = 2;
static const NSInteger kStateRefresh = 3;

#pragma mark - 类型垫片
// 用协议声明要调的外部方法：既能拿到完整类型（绕开「给前向声明的类发消息」这类编译错误），
// 又不依赖任何第三方头文件，更不用把 objc_msgSend 强转成函数指针（ARC 下有过度释放风险）。

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

// 关键页面判定的关键词（纯 C 数组，热路径不产生任何对象）
static const char *kBNRKeywords[] = {
    "Home", "Feed", "Recommend", "Index", "Square",
    "Video", "Search", "Detail", "Main", "Root"
};

static BOOL BNRKeywordHitC(const char *n) {
    if (!n) return NO;
    if (strlen(n) < 3) return NO;
    for (size_t i = 0; i < sizeof(kBNRKeywords) / sizeof(kBNRKeywords[0]); i++) {
        if (strstr(n, kBNRKeywords[i])) return YES;
    }
    return NO;
}

#pragma mark - 内存事件缓冲（不做任何文件 I/O）

static NSMutableArray<NSString *> *BNREvents(void) {
    static NSMutableArray *a; static dispatch_once_t once;
    dispatch_once(&once, ^{ a = [NSMutableArray array]; });
    return a;
}
static NSMutableSet<NSString *> *BNRSeenVC(void) {
    static NSMutableSet *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [NSMutableSet set]; });
    return s;
}
static NSMutableSet<NSString *> *BNRReloadOwners(void) {
    static NSMutableSet *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [NSMutableSet set]; });
    return s;
}
static NSMutableSet<NSString *> *BNRRefreshClasses(void) {
    static NSMutableSet *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [NSMutableSet set]; });
    return s;
}

static void BNREvent(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    @synchronized (BNREvents()) {
        if (BNREvents().count < 600) [BNREvents() addObject:msg];
    }
}

static void BNRAddUnique(NSMutableSet *set, NSString *value, NSUInteger cap) {
    if (!value) return;
    @synchronized (set) {
        if (set.count < cap) [set addObject:value];
    }
}

#pragma mark - 判定：刷新是不是用户自己拉的

static BOOL BNRIsFooter(id comp) {
    const char *n = BNRClassNameC(comp);
    return n && strstr(n, "Footer") != NULL;      // 上拉加载更多用的 footer 一律不拦
}

static NSInteger BNRStateOf(id comp) {
    id p = (id<BNRRefreshLike>)comp;
    @try {
        if ([p respondsToSelector:@selector(state)]) return [p state];
    } @catch (NSException *e) { (void)e; }
    return kStateIdle;
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

static BOOL BNRIsUserDriven(id comp) {
    if (BNRStateOf(comp) == kStatePulling) return YES;      // 用户正拉着 → 是手动刷新
    UIScrollView *sv = BNRScrollViewOf(comp);
    if (sv && (sv.isDragging || sv.isTracking || sv.isDecelerating)) return YES;
    return NO;
}

static BOOL BNRUIRefreshIsUserDriven(UIRefreshControl *ctl) {
    UIView *v = ctl.superview;
    NSInteger depth = 0;
    while (v && depth++ < 10) {
        if ([v isKindOfClass:[UIScrollView class]]) {
            UIScrollView *sv = (UIScrollView *)v;
            return (sv.isDragging || sv.isTracking || sv.isDecelerating);
        }
        v = v.superview;
    }
    return YES;      // 找不到宿主滚动视图就放行，宁可漏拦也不误伤
}

#pragma mark - 方法签名校验（v1.2.0 新增，防止参数错位崩溃）

// 方法签名形如 "v@:q" / "v@:q16" / "v24@0:8q16"，统一按「跳过数字偏移、逐段取类型」来解析。
static const char *BNRNextType(const char *t) {
    if (!t) return NULL;
    while (*t && isdigit((unsigned char)*t)) t++;
    return (*t) ? t : NULL;
}

// -(void)foo    → v@:
static BOOL BNREncVoidNoArg(const char *t) {
    const char *p = BNRNextType(t);    if (!p || *p != 'v') return NO;
    p = BNRNextType(p + 1);            if (!p || *p != '@') return NO;
    p = BNRNextType(p + 1);            if (!p || *p != ':') return NO;
    p = BNRNextType(p + 1);
    return (p == NULL);                // 后面不能再有参数
}

// -(void)foo:(NSInteger)x → v@:q
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

#pragma mark - 动态闸门

typedef struct { Class cls; SEL sel; IMP imp; } BNRPatch;
static BNRPatch gPatches[32];
static int      gPatchCount = 0;
static int      gBlocked    = 0;
static int      gHooked     = 0;

// 找被我们替换掉的原实现：沿继承链匹配「类 + 选择子」
static IMP BNROrigFor(id self, SEL cmd) {
    Class c = object_getClass(self);
    for (Class k = c; k != Nil; k = class_getSuperclass(k)) {
        for (int i = 0; i < gPatchCount; i++) {
            if (gPatches[i].cls == k && sel_isEqual(gPatches[i].sel, cmd)) return gPatches[i].imp;
        }
    }
    return NULL;
}

static void BNRHookedBeginRefreshing(id self, SEL _cmd) {
    BOOL block = NO;
    if (kEnabled && kBlockRefresh) {
        @try {
            if (!BNRIsFooter(self) && !BNRIsUserDriven(self)) block = YES;
        } @catch (NSException *e) { (void)e; block = NO; }
    }
    if (block) {
        __sync_fetch_and_add(&gBlocked, 1);
        BNREvent(@"⛔️ 吃掉自动刷新 beginRefreshing → %@", BNRClassName(self));
        return;
    }
    IMP orig = BNROrigFor(self, _cmd);
    if (orig) ((void (*)(id, SEL))orig)(self, _cmd);
}

static void BNRHookedSetState(id self, SEL _cmd, NSInteger state) {
    BOOL block = NO;
    if (kEnabled && kBlockRefresh && state == kStateRefresh) {
        @try {
            if (!BNRIsFooter(self) && !BNRIsUserDriven(self)) block = YES;
        } @catch (NSException *e) { (void)e; block = NO; }
    }
    if (block) {
        __sync_fetch_and_add(&gBlocked, 1);
        BNREvent(@"⛔️ 吃掉自动刷新 setState:Refreshing → %@", BNRClassName(self));
        return;
    }
    IMP orig = BNROrigFor(self, _cmd);
    if (orig) ((void (*)(id, SEL, NSInteger))orig)(self, _cmd, state);
}

// 这个方法归哪个类「自己」实现？返回 Nil = 都是继承来的
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

static void BNRPatchClass(Class c, SEL sel, IMP newImp, const char *label) {
    if (gPatchCount >= 32) return;
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return;
    IMP old = method_setImplementation(m, newImp);
    if (!old || old == newImp) return;          // 保险：绝不让 orig 指向自己（会死循环）
    gPatches[gPatchCount].cls = c;
    gPatches[gPatchCount].sel = sel;
    gPatches[gPatchCount].imp = old;
    gPatchCount++;
    __sync_fetch_and_add(&gHooked, 1);
    BNREvent(@"🔧 挂钩 -%s [%s]", label, class_getName(c));
}

static BOOL BNRNameLooksLikeRefresh(const char *n) {
    if (!n) return NO;
    return (strstr(n, "Refresh") != NULL) || (strstr(n, "PullToRefresh") != NULL);
}

// 返回 YES = 至少挂上了一个闸门
static BOOL BNRInstallGates(void) {
    unsigned int count = 0;
    Class *list = objc_copyClassList(&count);
    if (!list) return NO;

    int patched = 0;
    SEL sBegin = @selector(beginRefreshing);
    SEL sSet   = sel_registerName("setState:");

    for (unsigned int i = 0; i < count; i++) {
        Class c = list[i];
        const char *nm = class_getName(c);
        if (!BNRNameLooksLikeRefresh(nm)) continue;

        BNRAddUnique(BNRRefreshClasses(), [NSString stringWithUTF8String:nm], 40);

        // 只改「自己实现」的方法；改父类共享的 Method 会波及所有兄弟类
        if (BNROwnerOfSEL(c, sBegin) == c) {
            Method m = class_getInstanceMethod(c, sBegin);
            const char *t = m ? method_getTypeEncoding(m) : NULL;
            if (BNREncVoidNoArg(t)) {
                BNRPatchClass(c, sBegin, (IMP)&BNRHookedBeginRefreshing, "beginRefreshing");
                patched++;
            } else {
                BNREvent(@"⚠️ 跳过 %s -beginRefreshing（签名不符：%s）", nm, t ? t : "?");
            }
        }
        if (BNROwnerOfSEL(c, sSet) == c) {
            Method m = class_getInstanceMethod(c, sSet);
            const char *t = m ? method_getTypeEncoding(m) : NULL;
            if (BNREncVoidIntegerArg(t)) {
                BNRPatchClass(c, sSet, (IMP)&BNRHookedSetState, "setState:");
                patched++;
            }
        }
    }
    free(list);
    return patched > 0;
}

#pragma mark - 前置声明（探针里要用到安装入口）

static BOOL gBootstrapped;
static BOOL gBootRunning;
static void BNRBootstrap(void);
static void BNRHandleBecameActive(void);
static void BNRDumpLogToFile(void);
static void BNRShowAlert(void);

#pragma mark - 探针（全部走 UIKit，类都有完整头文件，安全）

%hook UIViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (kProbeVC) {
        const char *n = BNRClassNameC(self);
        if (BNRKeywordHitC(n)) {
            NSString *s = [NSString stringWithUTF8String:n];
            BNRAddUnique(BNRSeenVC(), s, 40);
            BNREvent(@"▶️ 页面将出现: %@", s);
        }
    }
    if (!gBootstrapped) dispatch_async(dispatch_get_main_queue(), ^{ BNRBootstrap(); });
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    if (kProbeVC) {
        const char *n = BNRClassNameC(self);
        if (BNRKeywordHitC(n)) BNREvent(@"⏹ 页面已离开: %@", [NSString stringWithUTF8String:n]);
    }
}

- (void)dealloc {
    if (kProbeVC) {
        const char *n = BNRClassNameC(self);
        if (BNRKeywordHitC(n)) BNREvent(@"💀 页面被销毁(dealloc): %@", [NSString stringWithUTF8String:n]);
    }
    %orig;
}

%end

%hook UICollectionView

- (void)reloadData {
    if (kProbeReload) {
        @try {
            const char *dn = BNRClassNameC(self.delegate);
            const char *sn = BNRClassNameC(self.dataSource);
            if (BNRKeywordHitC(dn) || BNRKeywordHitC(sn)) {
                NSString *line = [NSString stringWithFormat:@"🔁 reloadData [%@] delegate=%s",
                                  BNRClassName(self), dn ? dn : "(nil)"];
                BNRAddUnique(BNRReloadOwners(), line, 40);
                BNREvent(@"%@", line);
            }
        } @catch (NSException *e) { (void)e; }
    }
    %orig;
}

%end

%hook UITableView

- (void)reloadData {
    if (kProbeReload) {
        @try {
            const char *dn = BNRClassNameC(self.delegate);
            const char *sn = BNRClassNameC(self.dataSource);
            if (BNRKeywordHitC(dn) || BNRKeywordHitC(sn)) {
                NSString *line = [NSString stringWithFormat:@"🔁 reloadData [%@] delegate=%s",
                                  BNRClassName(self), dn ? dn : "(nil)"];
                BNRAddUnique(BNRReloadOwners(), line, 40);
                BNREvent(@"%@", line);
            }
        } @catch (NSException *e) { (void)e; }
    }
    %orig;
}

%end

#pragma mark - 副力闸门：系统原生 UIRefreshControl

%hook UIRefreshControl

- (void)beginRefreshing {
    if (kEnabled && kBlockRefresh && !BNRUIRefreshIsUserDriven(self)) {
        __sync_fetch_and_add(&gBlocked, 1);
        BNREvent(@"⛔️ 吃掉自动刷新 UIRefreshControl beginRefreshing");
        return;
    }
    %orig;
}

%end

#pragma mark - 安装入口

static BOOL gBootstrapped = NO;
static int  gRetries      = 0;
static BOOL gBootRunning  = NO;
static BOOL gObserverDone = NO;

static void BNRBootstrap(void);

// 只在哔哩哔哩里动作，其它进程一律装死
static BOOL BNRIsTargetApp(void) {
    @try {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        return bid && [bid isEqualToString:[NSString stringWithUTF8String:kTargetBundle]];
    } @catch (NSException *e) { (void)e; return NO; }
}

static void BNRRetryLater(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ BNRBootstrap(); });
}

static void BNRBootstrap(void) {
    if (gBootstrapped || gBootRunning) return;
    gBootRunning = YES;

    if (!BNRIsTargetApp()) {
        gBootstrapped = YES;
        gBootRunning = NO;
        return;
    }

    if (!gObserverDone) {
        gObserverDone = YES;
        @try {
            [[NSNotificationCenter defaultCenter]
                addObserverForName:UIApplicationDidBecomeActiveNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *note) {
                (void)note;
                BNRHandleBecameActive();
            }];
        } @catch (NSException *e) { (void)e; }
    }

    BOOL ok = NO;
    @try { ok = BNRInstallGates(); } @catch (NSException *e) { (void)e; ok = NO; }

    if (ok) {
        gBootstrapped = YES;
        NSUInteger n = 0;
        @synchronized (BNRRefreshClasses()) { n = BNRRefreshClasses().count; }
        BNREvent(@"✅ 闸门安装完成：疑似刷新类 %lu 个 / 挂钩 %d 个（第 %d 次尝试）",
                 (unsigned long)n, gHooked, gRetries + 1);
    } else if (++gRetries >= 8) {
        gBootstrapped = YES;
        BNREvent(@"❌ 已尝试 8 次仍未发现任何刷新控件类 —— 首页刷新很可能不走 MJRefresh");
    } else {
        BNREvent(@"… 尚未发现刷新控件，1.5 秒后重试（第 %d 次）", gRetries);
        BNRRetryLater();
    }

    gBootRunning = NO;
}

#pragma mark - 诊断汇报

// 跳过「冷启动那次激活」，绝不在启动过程中弹窗
static void BNRHandleBecameActive(void) {
    static int activeCount = 0;
    int n = __sync_add_and_fetch(&activeCount, 1);
    if (n < 2 || !kShowAlert) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        BNRDumpLogToFile();
        BNRShowAlert();
    });
}

static NSString *BNRJoinSet(NSMutableSet *s, NSUInteger max) {
    NSArray *arr = nil;
    @synchronized (s) { arr = [s.allObjects sortedArrayUsingSelector:@selector(compare:)]; }
    if (arr.count == 0) return @"无";
    NSArray *sub = arr.count > max ? [arr subarrayWithRange:NSMakeRange(0, max)] : arr;
    NSString *joined = [sub componentsJoinedByString:@"\n"];
    if (arr.count > max) joined = [joined stringByAppendingFormat:@"\n…(共%lu项)", (unsigned long)arr.count];
    return joined;
}

static void BNRDumpLogToFile(void) {
    if (!kDebugFile) return;
    @try {
        NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/BiliNoRefresh.log"];
        NSMutableString *s = [NSMutableString string];
        @synchronized (BNREvents()) {
            for (NSString *l in BNREvents()) [s appendFormat:@"%@\n", l];
        }
        [s writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    } @catch (NSException *e) { (void)e; }
}

static void BNRShowAlert(void) {
    if (!kShowAlert) return;
    @try {
        UIWindow *win = nil;
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                if (w.isKeyWindow) { win = w; break; }
            }
            if (win) break;
        }
        if (!win) win = UIApplication.sharedApplication.keyWindow;
        UIViewController *root = win.rootViewController;
        if (!root || root.presentedViewController) return;
        if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;

        NSMutableString *m = [NSMutableString string];
        [m appendFormat:@"刷新控件类:\n%@\n\n", BNRJoinSet(BNRRefreshClasses(), 6)];
        [m appendFormat:@"已挂钩方法: %d 个\n已拦截自动刷新: %d 次\n\n", gHooked, gBlocked];
        [m appendFormat:@"关键页面:\n%@\n\n", BNRJoinSet(BNRSeenVC(), 6)];
        [m appendFormat:@"reloadData 宿主:\n%@\n\n", BNRJoinSet(BNRReloadOwners(), 5)];
        [m appendString:@"截这张图发我即可"];

        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"BiliNoRefresh v1.2.0 诊断"
                                                                   message:m
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [root presentViewController:ac animated:YES completion:nil];
    } @catch (NSException *e) { (void)e; }
}

#pragma mark - 加载入口
// ⚠️ 关键：构造函数跑在 dyld 阶段，这里【只能】排一个延后任务，绝不允许碰运行时。

__attribute__((constructor))
static void BNRInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ BNRBootstrap(); });
}
