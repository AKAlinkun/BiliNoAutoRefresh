//
//  Tweak.x
//  BiliNoAutoRefresh v1.1.0 —— 诊断版
//
//  ── 目的 ──────────────────────────────────────────────────────────────
//  v1.0.1 按「刷新走 MJRefresh」的假设写了闸门，但反馈「搜索→点视频→播放→返回首页仍会刷新」。
//  到底是「闸门没挂上」还是「首页刷新根本不走 MJRefresh」，猜不出来，所以这一版让插件自己报。
//
//  本版三处升级：
//    1. 运行时自动发现：不再写死 "MJRefreshHeader" 类名，扫全机类表找刷新控件，改过名也能命中。
//    2. 动态挂钩：用 objc runtime 直接换实现（method_setImplementation），不依赖 Logos。
//    3. 可视化诊断：切回前台时弹窗汇总（刷新控件类名 / 拦截次数 / 关键页面 / reloadData 宿主 /
//       刷新相关通知），细节同时落盘到 App 沙盒 Documents/BiliNoRefresh.log。
//
//  ⚠️ 诊断版：kShowAlert / kDebugLog 开着。拿到结论后要关掉。
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#pragma mark - 开关

static BOOL kEnabled        = YES;
static BOOL kBlockUIRefresh = YES;
static BOOL kDebugLog       = YES;   // 诊断期：写日志
static BOOL kShowAlert      = YES;   // 诊断期：切回前台弹窗汇总
static BOOL kProbeVC        = YES;   // 探针：记录关键页面出现
static BOOL kProbeReload    = YES;   // 探针：记录关键列表的 reloadData
static BOOL kProbeNotify    = YES;   // 探针：记录刷新相关通知

// MJRefreshState 枚举值（取自 MJRefresh 源码，别改）
static const NSInteger kMJStateIdle    = 1;
static const NSInteger kMJStatePulling = 2;
static const NSInteger kMJStateRefresh = 3;

static const unsigned long long kMaxLogBytes = 512ULL * 1024ULL;
static NSString * const kLogName = @"BiliNoRefresh.log";

static int gBlockedCount  = 0;
static int gHookedMethods = 0;

#pragma mark - 懒初始化容器（避免加载顺序问题）

static NSString *BNRLogPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:
            [@"Documents" stringByAppendingPathComponent:kLogName]];
}

static NSMutableArray<NSString *> *BNREvents(void) {
    static NSMutableArray *a; static dispatch_once_t once;
    dispatch_once(&once, ^{ a = [NSMutableArray array]; });
    return a;
}
static NSMutableSet<NSString *> *BNRRefreshClasses(void) {
    static NSMutableSet *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [NSMutableSet set]; });
    return s;
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
static NSMutableSet<NSString *> *BNRNotifyNames(void) {
    static NSMutableSet *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [NSMutableSet set]; });
    return s;
}
static NSMutableDictionary *BNROrigBegin(void) {
    static NSMutableDictionary *d; static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [NSMutableDictionary dictionary]; });
    return d;
}
static NSMutableDictionary *BNROrigSetState(void) {
    static NSMutableDictionary *d; static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [NSMutableDictionary dictionary]; });
    return d;
}

#pragma mark - 日志

static void BNRWrite(NSString *line) {
    if (!kDebugLog) return;
    @synchronized (kLogName) {                 // hook 可能在任意线程触发，写文件要串行化
        NSString *path = BNRLogPath();
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDictionary *attr = [fm attributesOfItemAtPath:path error:NULL];
        if (attr && [attr[NSFileSize] unsignedLongLongValue] > kMaxLogBytes) return;
        if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:nil];

        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) return;
        @try {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        } @catch (NSException *e) { (void)e; }
        [fh closeFile];
    }
}

static void BNRLog(NSString *fmt, ...) {
    if (!kDebugLog) return;
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    BNRWrite([NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg]);
}

// 记一条「事件」：既进内存（弹窗用），也落盘
static void BNREvent(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    @synchronized (BNREvents()) {
        if (BNREvents().count < 300) [BNREvents() addObject:msg];
    }
    BNRLog(@"[事件] %@", msg);
}

#pragma mark - 安全工具（全用 C 函数，避免对不完整类型发消息）

static NSString *BNRClassName(id obj) {
    if (!obj) return @"(nil)";
    Class c = object_getClass(obj);
    return c ? NSStringFromClass(c) : @"(unknown)";
}

#pragma mark - 判定：刷新是不是用户自己触发的

static UIScrollView *BNRScrollViewOf(id comp) {
    UIScrollView *sv = nil;
    @try {
        if ([comp respondsToSelector:NSSelectorFromString(@"scrollView")]) {
            sv = [comp valueForKey:@"scrollView"];
        }
    } @catch (NSException *e) { (void)e; sv = nil; }
    if ([sv isKindOfClass:[UIScrollView class]]) return sv;

    @try {
        if ([comp respondsToSelector:NSSelectorFromString(@"superScrollView")]) {
            sv = [comp valueForKey:@"superScrollView"];
        }
    } @catch (NSException *e) { (void)e; sv = nil; }
    return [sv isKindOfClass:[UIScrollView class]] ? sv : nil;
}

static NSInteger BNRStateOf(id comp) {
    NSInteger st = kMJStateIdle;
    @try {
        if ([comp respondsToSelector:NSSelectorFromString(@"state")]) {
            st = [[comp valueForKey:@"state"] integerValue];
        }
    } @catch (NSException *e) { (void)e; st = kMJStateIdle; }
    return st;
}

static BOOL BNRIsUserDriven(id comp) {
    if (BNRStateOf(comp) == kMJStatePulling) return YES;
    UIScrollView *sv = BNRScrollViewOf(comp);
    if (sv && (sv.isDragging || sv.isTracking || sv.isDecelerating)) return YES;
    return NO;
}

// 上拉加载更多用的 footer 不拦，免得影响「加载更多」
static BOOL BNRIsFooter(id comp) {
    return [BNRClassName(comp) containsString:@"Footer"];
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
    return YES;
}

#pragma mark - 探针关键词

static NSArray<NSString *> *BNRKeywords(void) {
    static NSArray *a; static dispatch_once_t once;
    dispatch_once(&once, ^{
        a = @[@"Home", @"Feed", @"Recommend", @"Index", @"Square",
              @"Video", @"Search", @"Detail", @"Main", @"Root"];
    });
    return a;
}

static BOOL BNRIsKeyName(NSString *n) {
    if (n.length < 3) return NO;
    for (NSString *k in BNRKeywords()) {
        if ([n containsString:k]) return YES;
    }
    return NO;
}

#pragma mark - 运行时自动发现 + 动态挂钩刷新控件

typedef void (*BNRVoidVoidFn)(id, SEL);
typedef void (*BNRVoidIntFn)(id, SEL, NSInteger);

static IMP BNRFindOrig(NSMutableDictionary *map, id obj) {
    for (Class c = object_getClass(obj); c; c = class_getSuperclass(c)) {
        NSValue *v = nil;
        @synchronized (map) { v = map[NSStringFromClass(c)]; }
        if (v) return (IMP)[v pointerValue];
    }
    return NULL;
}

static void BNRDynBeginRefreshing(id self, SEL _cmd) {
    IMP orig = BNRFindOrig(BNROrigBegin(), self);
    if (kEnabled && !BNRIsFooter(self) && !BNRIsUserDriven(self)) {
        __sync_fetch_and_add(&gBlockedCount, 1);
        BNREvent(@"拦截自动刷新 beginRefreshing → %@", BNRClassName(self));
        return;                       // 不执行原实现 = 吃掉这次自动刷新
    }
    if (orig) ((BNRVoidVoidFn)orig)(self, _cmd);
}

static void BNRDynSetState(id self, SEL _cmd, NSInteger state) {
    IMP orig = BNRFindOrig(BNROrigSetState(), self);
    if (kEnabled && state == kMJStateRefresh && !BNRIsFooter(self) && !BNRIsUserDriven(self)) {
        __sync_fetch_and_add(&gBlockedCount, 1);
        BNREvent(@"拦截自动刷新 setState:Refreshing → %@", BNRClassName(self));
        return;
    }
    if (orig) ((BNRVoidIntFn)orig)(self, _cmd, state);
}

// 判断一个类是不是刷新控件，并回填「它是否自己实现了这两个方法」（只有自己实现的才能安全换实现，
// 换父类共享的 Method 会波及所有子类）。
static BOOL BNRIsRefreshClass(Class c, BOOL *hasBegin, BOOL *hasSet) {
    SEL sBegin = @selector(beginRefreshing);
    SEL sSet   = sel_registerName("setState:");
    SEL sState = sel_registerName("state");

    BOOL mBegin = class_getInstanceMethod(c, sBegin) != NULL;
    BOOL mSet   = class_getInstanceMethod(c, sSet)   != NULL;
    if (!mBegin && !mSet) return NO;

    const char *name = class_getName(c);
    BOOL isMJFamily = (name && strstr(name, "MJRefresh"));

    // 非 MJRefresh 家族的类，必须「beginRefreshing + setState: + state」三件套齐全才认，
    // 避免误伤无关类。
    if (!isMJFamily && !(mBegin && mSet && class_getInstanceMethod(c, sState))) return NO;

    unsigned int mcount = 0;
    Method *methods = class_copyMethodList(c, &mcount);
    BOOL hb = NO, hs = NO;
    for (unsigned int j = 0; j < mcount; j++) {
        const char *sn = sel_getName(method_getName(methods[j]));
        if (strcmp(sn, "beginRefreshing") == 0) hb = YES;
        else if (strcmp(sn, "setState:") == 0) hs = YES;
    }
    if (methods) free(methods);

    if (hasBegin) *hasBegin = hb;
    if (hasSet)   *hasSet = hs;
    return (hb || hs);
}

static void BNRInstallRefreshGates(void) {
    unsigned int count = 0;
    Class *list = objc_copyClassList(&count);
    if (!list) { BNRLog(@"objc_copyClassList 失败"); return; }

    for (unsigned int i = 0; i < count; i++) {
        Class c = list[i];
        BOOL hasBegin = NO, hasSet = NO;
        if (!BNRIsRefreshClass(c, &hasBegin, &hasSet)) continue;

        NSString *clsName = @(class_getName(c));
        @synchronized (BNRRefreshClasses()) { [BNRRefreshClasses() addObject:clsName]; }

        if (hasBegin) {
            Method m = class_getInstanceMethod(c, @selector(beginRefreshing));
            if (m) {
                IMP old = method_setImplementation(m, (IMP)&BNRDynBeginRefreshing);
                if (old) {
                    @synchronized (BNROrigBegin()) {
                        BNROrigBegin()[clsName] = [NSValue valueWithPointer:old];
                    }
                }
                BNRLog(@"挂钩 %@ -beginRefreshing", clsName);
                __sync_fetch_and_add(&gHookedMethods, 1);
            }
        }
        if (hasSet) {
            Method m = class_getInstanceMethod(c, sel_registerName("setState:"));
            if (m) {
                IMP old = method_setImplementation(m, (IMP)&BNRDynSetState);
                if (old) {
                    @synchronized (BNROrigSetState()) {
                        BNROrigSetState()[clsName] = [NSValue valueWithPointer:old];
                    }
                }
                BNRLog(@"挂钩 %@ -setState:", clsName);
                __sync_fetch_and_add(&gHookedMethods, 1);
            }
        }
    }
    free(list);
}

#pragma mark - 探针一：关键页面出现（Logos 走 UIKit，类都有完整头文件，安全）

%hook UIViewController

- (void)viewWillAppear:(BOOL)animated {
    if (kDebugLog && kProbeVC) {
        NSString *n = BNRClassName(self);
        if (BNRIsKeyName(n)) {
            @synchronized (BNRSeenVC()) { [BNRSeenVC() addObject:n]; }
            BNREvent(@"页面将出现: %@", n);
        }
    }
    %orig;
}

%end

#pragma mark - 探针二：关键列表 reloadData（记录宿主类名，用于反查首页 VC）

%hook UICollectionView

- (void)reloadData {
    if (kDebugLog && kProbeReload) {
        NSString *dn = BNRClassName(self.delegate);
        NSString *sn = BNRClassName(self.dataSource);
        if (BNRIsKeyName(dn) || BNRIsKeyName(sn)) {
            @synchronized (BNRReloadOwners()) {
                [BNRReloadOwners() addObject:[NSString stringWithFormat:@"%@(dg=%@)", BNRClassName(self), dn]];
            }
            BNREvent(@"reloadData: delegate=%@ dataSource=%@", dn, sn);
        }
    }
    %orig;
}

%end

%hook UITableView

- (void)reloadData {
    if (kDebugLog && kProbeReload) {
        NSString *dn = BNRClassName(self.delegate);
        NSString *sn = BNRClassName(self.dataSource);
        if (BNRIsKeyName(dn) || BNRIsKeyName(sn)) {
            @synchronized (BNRReloadOwners()) {
                [BNRReloadOwners() addObject:[NSString stringWithFormat:@"%@(dg=%@)", BNRClassName(self), dn]];
            }
            BNREvent(@"reloadData: delegate=%@ dataSource=%@", dn, sn);
        }
    }
    %orig;
}

%end

#pragma mark - 探针三：刷新相关通知

%hook NSNotificationCenter

- (void)postNotificationName:(NSNotificationName)name object:(id)object userInfo:(NSDictionary *)userInfo {
    if (kDebugLog && kProbeNotify && name.length > 3) {
        NSString *n = name;
        if ([n rangeOfString:@"refresh" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [n rangeOfString:@"reload"  options:NSCaseInsensitiveSearch].location != NSNotFound) {
            @synchronized (BNRNotifyNames()) { [BNRNotifyNames() addObject:n]; }
            BNREvent(@"通知: %@ (object=%@)", n, BNRClassName(object));
        }
    }
    %orig;
}

- (void)postNotificationName:(NSNotificationName)name object:(id)object {
    if (kDebugLog && kProbeNotify && name.length > 3) {
        NSString *n = name;
        if ([n rangeOfString:@"refresh" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [n rangeOfString:@"reload"  options:NSCaseInsensitiveSearch].location != NSNotFound) {
            @synchronized (BNRNotifyNames()) { [BNRNotifyNames() addObject:n]; }
            BNREvent(@"通知: %@ (object=%@)", n, BNRClassName(object));
        }
    }
    %orig;
}

%end

#pragma mark - 副力闸门：系统原生 UIRefreshControl

%hook UIRefreshControl

- (void)beginRefreshing {
    if (kEnabled && kBlockUIRefresh && !BNRUIRefreshIsUserDriven(self)) {
        __sync_fetch_and_add(&gBlockedCount, 1);
        BNREvent(@"拦截自动刷新 UIRefreshControl beginRefreshing");
        return;
    }
    %orig;
}

%end

#pragma mark - 诊断弹窗

static NSString *BNRJoinSet(NSMutableSet *s, NSUInteger max) {
    NSArray *arr = nil;
    @synchronized (s) { arr = [s.allObjects sortedArrayUsingSelector:@selector(compare:)]; }
    if (arr.count == 0) return @"无";
    NSArray *sub = arr.count > max ? [arr subarrayWithRange:NSMakeRange(0, max)] : arr;
    NSString *joined = [sub componentsJoinedByString:@", "];
    if (arr.count > max) joined = [joined stringByAppendingFormat:@" …(共%lu个)", (unsigned long)arr.count];
    return joined;
}

static void BNRShowAlert(void) {
    if (!kShowAlert) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = nil;
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
            if ([sc isKindOfClass:[UIWindowScene class]]) {
                for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                    if (w.isKeyWindow) { win = w; break; }
                }
            }
            if (win) break;
        }
        if (!win) win = UIApplication.sharedApplication.keyWindow;
        UIViewController *root = win.rootViewController;
        if (!root || root.presentedViewController) return;

        NSMutableString *m = [NSMutableString string];
        [m appendFormat:@"刷新控件类: %@\n", BNRJoinSet(BNRRefreshClasses(), 6)];
        [m appendFormat:@"已挂钩方法数: %d\n", gHookedMethods];
        [m appendFormat:@"已拦截自动刷新: %d 次\n", gBlockedCount];
        [m appendFormat:@"关键页面: %@\n", BNRJoinSet(BNRSeenVC(), 5)];
        [m appendFormat:@"reloadData宿主: %@\n", BNRJoinSet(BNRReloadOwners(), 4)];
        [m appendFormat:@"刷新相关通知: %@\n", BNRJoinSet(BNRNotifyNames(), 5)];
        [m appendString:@"\n点「好」后去复现问题，再切后台回来可看新一轮统计"];

        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"BiliNoRefresh 诊断"
                                                                   message:m
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [root presentViewController:ac animated:YES completion:nil];

        @synchronized (BNREvents()) { [BNREvents() removeAllObjects]; }
    });
}

#pragma mark - 加载入口
// 不用 %ctor（避免 Logos「用了 %ctor 就不再自动初始化顶层 %hook」的坑），改用普通 constructor。

__attribute__((constructor))
static void BNRInit(void) {
    BNRLog(@"================ BiliNoAutoRefresh v1.1.0 诊断版加载 ================");
    BNRLog(@"日志路径: %@", BNRLogPath());
    BNRLog(@"bundle=%@", [[NSBundle mainBundle] bundleIdentifier]);

    BNRInstallRefreshGates();

    NSArray *found = nil;
    @synchronized (BNRRefreshClasses()) { found = BNRRefreshClasses().allObjects; }
    if (found.count == 0) {
        BNRLog(@"!!! 未发现任何刷新控件类 —— 首页刷新可能不走 MJRefresh");
    } else {
        BNRLog(@"共发现 %lu 个刷新控件类", (unsigned long)found.count);
    }

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        (void)note;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            BNRShowAlert();
        });
    }];
}
