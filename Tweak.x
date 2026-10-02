//
//  Tweak.x
//  BiliNoAutoRefresh —— 禁止哔哩哔哩（iOS 客户端）首页 / 推荐流自动刷新
//
//  ── 核心思路 ──────────────────────────────────────────────────────────
//  国内 App 的下拉刷新几乎都基于 MJRefresh（B站也不例外）。它触发刷新只有两条路：
//
//    A. 用户手动下拉：拖拽 → state 变 Pulling → 松手 → state 变 Refreshing   ← 要保留
//    B. App 自动刷新：直接调 beginRefreshing，或把 header.state 置成 Refreshing ← 要拦掉
//
//  两条路最终都会进 setState:，区别只有一个：
//      自动刷新时，触发瞬间「用户并没有在拖屏幕」，且进入前的 state 是 Idle；
//      手动下拉时，进入前的 state 是 Pulling。
//
//  所以只要在 setState:/beginRefreshing 里加一道闸门：判定「不是用户自己拉的」就直接
//  返回、不执行原方法 —— 自动刷新被吃掉，手动下拉与上拉加载更多完全不受影响。
//
//  另外顺手拦掉系统原生 UIRefreshControl 的程序化刷新（有些页面用原生控件）。
//
//  ── 可调开关 ──────────────────────────────────────────────────────────
//  kEnabled        总开关
//  kBlockUIRefresh 是否同时拦原生 UIRefreshControl
//  kDebugLog       排障开关：打开后会把每次拦截记到 App 沙盒 Documents/BiliNoRefresh.log
//  kProbe          排障开关：额外打印首页相关 ViewController 的出现记录（配合 kDebugLog）
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#pragma mark - 目标类声明（必须！）
//
//  MJRefresh 不在我们的编译环境里，Logos 默认只会给被 hook 的类生成一条 @class 前向声明，
//  那是「不完整类型」，clang 对不完整类型发消息会直接报错：
//      error: receiver type 'MJRefreshHeader' for instance message is a forward declaration
//  所以这里自己补上完整声明，让编译器拿到完整类型。
//  注意：这只是编译期声明，不产生任何代码，与 App 内真实的 MJRefresh 实现互不干扰。

@interface MJRefreshComponent : UIView
@end

@interface MJRefreshHeader : MJRefreshComponent
@end

#pragma mark - 开关

static BOOL kEnabled        = YES;
static BOOL kBlockUIRefresh = YES;
static BOOL kDebugLog       = NO;
static BOOL kProbe          = NO;

// MJRefreshState 枚举值（取自 MJRefresh 源码，别改）
static const NSInteger kMJStateIdle    = 1;
static const NSInteger kMJStatePulling = 2;
static const NSInteger kMJStateRefresh = 3;

#pragma mark - 安全工具（全部用 C 函数，避免对不完整类型发消息）

static NSString *BNRClassName(id obj) {
    Class c = object_getClass(obj);
    return c ? NSStringFromClass(c) : @"(unknown)";
}

static BOOL BNRIsKindOfClassNamed(id obj, const char *className) {
    Class target = objc_getClass(className);
    if (!target || !obj) return NO;
    for (Class c = object_getClass(obj); c; c = class_getSuperclass(c)) {
        if (c == target) return YES;
    }
    return NO;
}

#pragma mark - 日志（只在 kDebugLog 打开时写文件）

static void BNRLog(NSString *fmt, ...) {
    if (!kDebugLog) return;

    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/BiliNoRefresh.log"];

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        [fm createFileAtPath:path contents:nil attributes:nil];
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) return;
    @try {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    } @catch (NSException *e) { (void)e; }
    [fh closeFile];
}

#pragma mark - 判定工具

// 通过 KVC 拿 MJRefresh 组件内部的 scrollView（不同版本属性名略有差异，做兜底）
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

// YES = 这次刷新是用户自己触发的（放行）
static BOOL BNRIsUserDriven(id comp) {
    if (BNRStateOf(comp) == kMJStatePulling) return YES;   // 手动下拉松手那一刻

    UIScrollView *sv = BNRScrollViewOf(comp);
    if (sv && (sv.isDragging || sv.isTracking || sv.isDecelerating)) return YES;

    return NO;
}

// UIRefreshControl：向上找包裹它的 UIScrollView，看用户是不是正在拖
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
    return YES;   // 找不到宿主滚动视图就不拦，避免误伤
}

#pragma mark - 主力闸门一：MJRefresh 下拉头

%group MJHeaderGate

%hook MJRefreshHeader

- (void)beginRefreshing {
    if (kEnabled && !BNRIsUserDriven(self)) {
        BNRLog(@"拦截自动刷新 [beginRefreshing] %@", BNRClassName(self));
        return;
    }
    %orig;
}

- (void)setState:(NSInteger)state {
    if (kEnabled && state == kMJStateRefresh && !BNRIsUserDriven(self)) {
        BNRLog(@"拦截自动刷新 [setState:Refreshing] %@", BNRClassName(self));
        return;
    }
    %orig;
}

%end

%end

#pragma mark - 主力闸门二：MJRefresh 基类（兜底自研刷新头重写 beginRefreshing 的情况）

%group MJComponentGate

%hook MJRefreshComponent

- (void)beginRefreshing {
    if (kEnabled && BNRIsKindOfClassNamed(self, "MJRefreshHeader") && !BNRIsUserDriven(self)) {
        BNRLog(@"拦截自动刷新 [component beginRefreshing] %@", BNRClassName(self));
        return;
    }
    %orig;
}

%end

%end

#pragma mark - 副力闸门：系统原生 UIRefreshControl

%group UIRefreshGate

%hook UIRefreshControl

- (void)beginRefreshing {
    if (kEnabled && kBlockUIRefresh && !BNRUIRefreshIsUserDriven(self)) {
        BNRLog(@"拦截自动刷新 [UIRefreshControl beginRefreshing]");
        return;
    }
    %orig;
}

%end

%end

#pragma mark - 排障探针（默认关闭，不影响日常使用）

%group ProbeGate

%hook UIViewController

- (void)viewWillAppear:(BOOL)animated {
    if (kDebugLog && kProbe) {
        NSString *name = BNRClassName(self);
        for (NSString *kw in @[@"Home", @"Index", @"Feed", @"Recommend", @"Timeline", @"Square", @"Popular"]) {
            if ([name containsString:kw]) {
                BNRLog(@"页面出现: %@", name);
                break;
            }
        }
    }
    %orig;
}

%end

%end

#pragma mark - 初始化
// 注意：一旦自己写了 %ctor，Logos 就不会再自动初始化任何分组，
//       所有 %init 必须在这里显式调用（且只调一次，避免重复 swizzle 递归）。

%ctor {
    Class headerCls    = objc_getClass("MJRefreshHeader");
    Class componentCls = objc_getClass("MJRefreshComponent");

    if (headerCls) {
        %init(MJHeaderGate);
        BNRLog(@"MJRefreshHeader 闸门已启用");
    } else {
        BNRLog(@"未发现 MJRefreshHeader");
    }

    if (componentCls) {
        %init(MJComponentGate);
    }

    %init(UIRefreshGate);
    %init(ProbeGate);

    if (!headerCls && !componentCls) {
        BNRLog(@"目标 App 未使用 MJRefresh，主力闸门未生效，请打开 kProbe 反馈日志");
    }
    BNRLog(@"=== BiliNoAutoRefresh 已加载 ===");
}
