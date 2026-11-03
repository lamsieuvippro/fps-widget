// FPSRAMOverlay.m  (v4)
// HUD không nền: FPS, thanh RAM 3 đoạn (dùng / trống / Metal), pin, giờ, CPU, GPU.
// - Kéo 1 ngón để di chuyển (nhớ vị trí)
// - Chạm 1 lần để thu gọn / mở rộng
// - Chụm 2 ngón để đổi kích thước, hoặc nhấn giữ để đổi nhanh giữa các cỡ có sẵn
// - Giới hạn RAM của app ở FR_RAM_LIMIT_MB (mặc định 1.9 GB): xem ghi chú ở dưới
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <mach/mach.h>
#import <dlfcn.h>
#import <unistd.h>
#import <malloc/malloc.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

// ===== GIỚI HẠN RAM =====
// Giới hạn mềm (luôn bật): khi RAM của app (phys_footprint) vượt mức này, dylib sẽ
//   1) trả lại các trang bộ nhớ đã free cho hệ thống (malloc_zone_pressure_relief)
//   2) giả lập cảnh báo thiếu RAM để game tự xả cache/texture (tối đa 1 lần / 3 giây)
// Không ép cứng được: nếu game vẫn giữ RAM thì con số vẫn có thể vượt mức.
#define FR_RAM_LIMIT_MB 1946.0   // 1.9 GB
// Giới hạn cứng (thử): đặt 1 thì xin hệ điều hành đặt trần jetsam cho process.
// Vượt trần là game BỊ KILL. App sideload thường không có quyền nên có thể không có tác dụng.
#define FR_TRY_HARD_LIMIT 0

#pragma mark - Helpers

static UIWindow *FRFindWindow(void) {
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        if (s.activationState != UISceneActivationStateForegroundActive) continue;
        UIWindowScene *ws = (UIWindowScene *)s;
        for (UIWindow *w in ws.windows) if (w.isKeyWindow) return w;
        if (ws.windows.firstObject) return ws.windows.firstObject;
    }
    return UIApplication.sharedApplication.windows.firstObject;
}

static NSString *FRFmt(double bytes) {
    double gb = 1024.0 * 1024.0 * 1024.0;
    if (bytes >= gb) return [NSString stringWithFormat:@"%.1fG", bytes / gb];
    return [NSString stringWithFormat:@"%.0fM", bytes / (1024.0 * 1024.0)];
}

// RAM hệ thống: used / free (free = free + inactive)
static void FRSysMem(double *used, double *freeB) {
    vm_statistics64_data_t vm;
    mach_msg_type_number_t c = HOST_VM_INFO64_COUNT;
    vm_size_t page = 0;
    host_page_size(mach_host_self(), &page);
    double total = (double)NSProcessInfo.processInfo.physicalMemory;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &c) != KERN_SUCCESS) {
        *used = 0; *freeB = total; return;
    }
    double f = ((double)vm.free_count + (double)vm.inactive_count) * (double)page;
    if (f > total) f = total;
    *freeB = f;
    *used = total - f;
}

// RAM của chính app (giống Xcode)
static double FRAppBytes(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
    return (double)info.phys_footprint;
}

static void FRApplyHardLimit(void) {
#if FR_TRY_HARD_LIMIT
    typedef int (*mc_t)(uint32_t, int32_t, uint32_t, void *, size_t);
    mc_t mc = (mc_t)dlsym(RTLD_DEFAULT, "memorystatus_control");
    if (mc) {
        // 6 = MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT (giá trị tính bằng MB, vượt là bị kill)
        int r = mc(6, getpid(), (uint32_t)FR_RAM_LIMIT_MB, NULL, 0);
        NSLog(@"[FPSRAM] hard limit result: %d", r);
    }
#endif
}

// Bộ nhớ Metal mà process này đang cấp phát
static double FRMetalBytes(void) {
    static id<MTLDevice> dev;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ dev = MTLCreateSystemDefaultDevice(); });
    return dev ? (double)dev.currentAllocatedSize : 0;
}

// CPU toàn hệ thống (%), tính theo chênh lệch giữa 2 lần gọi
static int FRCPU(void) {
    static host_cpu_load_info_data_t prev;
    static BOOL has = NO;
    host_cpu_load_info_data_t cur;
    mach_msg_type_number_t c = HOST_CPU_LOAD_INFO_COUNT;
    if (host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, (host_info_t)&cur, &c) != KERN_SUCCESS) return -1;
    int r = -1;
    if (has) {
        double u = cur.cpu_ticks[CPU_STATE_USER]   - prev.cpu_ticks[CPU_STATE_USER];
        double s = cur.cpu_ticks[CPU_STATE_SYSTEM] - prev.cpu_ticks[CPU_STATE_SYSTEM];
        double i = cur.cpu_ticks[CPU_STATE_IDLE]   - prev.cpu_ticks[CPU_STATE_IDLE];
        double n = cur.cpu_ticks[CPU_STATE_NICE]   - prev.cpu_ticks[CPU_STATE_NICE];
        double total = u + s + i + n;
        if (total > 0) r = (int)lround((u + s + n) / total * 100.0);
    }
    prev = cur; has = YES;
    return r;
}

// GPU (%): đọc IOAccelerator qua IOKit (dlopen). Nếu bị chặn thì trả -1 -> hiện "--".
typedef mach_port_t fr_io_object_t;
typedef CFMutableDictionaryRef (*FRMatching_t)(const char *);
typedef kern_return_t (*FRGetServices_t)(mach_port_t, CFDictionaryRef, fr_io_object_t *);
typedef fr_io_object_t (*FRNext_t)(fr_io_object_t);
typedef kern_return_t (*FRProps_t)(fr_io_object_t, CFMutableDictionaryRef *, CFAllocatorRef, uint32_t);
typedef kern_return_t (*FRRelease_t)(fr_io_object_t);

static int FRGPU(void) {
    static FRMatching_t fMatching; static FRGetServices_t fGet;
    static FRNext_t fNext; static FRProps_t fProps; static FRRelease_t fRelease;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
        if (!h) return;
        fMatching = (FRMatching_t)dlsym(h, "IOServiceMatching");
        fGet      = (FRGetServices_t)dlsym(h, "IOServiceGetMatchingServices");
        fNext     = (FRNext_t)dlsym(h, "IOIteratorNext");
        fProps    = (FRProps_t)dlsym(h, "IORegistryEntryCreateCFProperties");
        fRelease  = (FRRelease_t)dlsym(h, "IOObjectRelease");
    });
    if (!fMatching || !fGet || !fNext || !fProps || !fRelease) return -1;

    fr_io_object_t it = 0;
    if (fGet(0, fMatching("IOAccelerator"), &it) != KERN_SUCCESS || !it) return -1;
    int result = -1;
    fr_io_object_t svc;
    while ((svc = fNext(it)) != 0) {
        CFMutableDictionaryRef props = NULL;
        if (fProps(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS && props) {
            NSDictionary *d = (__bridge NSDictionary *)props;
            NSDictionary *perf = d[@"PerformanceStatistics"];
            if ([perf isKindOfClass:NSDictionary.class]) {
                NSNumber *n = perf[@"Device Utilization %"] ?: perf[@"GPU Activity(%)"];
                if ([n isKindOfClass:NSNumber.class]) result = n.intValue;
            }
            CFRelease(props);
        }
        fRelease(svc);
        if (result >= 0) break;
    }
    fRelease(it);
    return result;
}

static void FRSetFont(UILabel *l, CGFloat size, UIFontWeight w) {
    l.font = [UIFont monospacedSystemFontOfSize:size weight:w];
}

static UILabel *FRLabel(UIColor *c, NSTextAlignment a) {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
    l.textColor = c;
    l.textAlignment = a;
    l.adjustsFontSizeToFitWidth = YES;
    l.minimumScaleFactor = 0.5;
    l.shadowColor = [UIColor colorWithWhite:0 alpha:0.85];
    l.shadowOffset = CGSizeMake(0, 1);
    return l;
}

static NSAttributedString *FRLoadText(int cpu, int gpu, CGFloat size) {
    UIFont *f = [UIFont monospacedSystemFontOfSize:size weight:UIFontWeightSemibold];
    UIColor *blue = [UIColor colorWithRed:0.30 green:0.60 blue:1.0 alpha:1];
    UIColor *orange = [UIColor colorWithRed:1.0 green:0.62 blue:0.12 alpha:1];
    NSString *c = cpu >= 0 ? [NSString stringWithFormat:@"● CPU %d%%", cpu] : @"● CPU --";
    NSString *g = gpu >= 0 ? [NSString stringWithFormat:@"● GPU %d%%", gpu] : @"● GPU --";
    NSMutableAttributedString *s = [NSMutableAttributedString new];
    [s appendAttributedString:[[NSAttributedString alloc] initWithString:c
        attributes:@{NSFontAttributeName: f, NSForegroundColorAttributeName: blue}]];
    [s appendAttributedString:[[NSAttributedString alloc] initWithString:@"  "
        attributes:@{NSFontAttributeName: f}]];
    [s appendAttributedString:[[NSAttributedString alloc] initWithString:g
        attributes:@{NSFontAttributeName: f, NSForegroundColorAttributeName: orange}]];
    return s;
}

#pragma mark - HUD

static const CGFloat kMinScale = 0.6, kMaxScale = 2.5;

@interface FRHud : NSObject
@property (nonatomic, strong) UIView *root, *barBg;
@property (nonatomic, strong) UILabel *fps, *app, *bat, *clock, *load;
@property (nonatomic, strong) NSArray<UIView *> *segs;
@property (nonatomic, strong) NSArray<UILabel *> *segLabels;
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic, strong) NSDateFormatter *df;
@property (nonatomic) CFTimeInterval lastFPS, lastStat;
@property (nonatomic) NSUInteger frames;
@property (nonatomic) int fpsValue, lastCPU, lastGPU;
@property (nonatomic) double usedB, freeB, metalB, appB;
@property (nonatomic) CFTimeInterval lastTrim;
@property (nonatomic) CGFloat scale, baseScale;
@property (nonatomic) BOOL collapsed, placed;
@end

@implementation FRHud

- (void)start {
    UIDevice.currentDevice.batteryMonitoringEnabled = YES;
    self.df = [NSDateFormatter new];
    self.df.dateFormat = @"HH:mm";
    self.fpsValue = -1; self.lastCPU = -1; self.lastGPU = -1;

    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    self.collapsed = [d boolForKey:@"FRCollapsed"];
    self.scale = [d objectForKey:@"FRScale"] ? (CGFloat)[d doubleForKey:@"FRScale"] : 1.0;
    self.scale = MIN(MAX(self.scale, kMinScale), kMaxScale);

    self.root = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 190, 116)];
    self.root.backgroundColor = UIColor.clearColor;   // không nền
    self.root.layer.zPosition = CGFLOAT_MAX;

    self.fps   = FRLabel([UIColor colorWithWhite:0.92 alpha:1], NSTextAlignmentLeft);
    self.app   = FRLabel([UIColor colorWithWhite:0.92 alpha:1], NSTextAlignmentLeft);
    self.bat   = FRLabel([UIColor colorWithRed:0.35 green:0.92 blue:0.35 alpha:1], NSTextAlignmentLeft);
    self.clock = FRLabel([UIColor colorWithWhite:0.80 alpha:1], NSTextAlignmentLeft);
    self.load  = FRLabel(UIColor.whiteColor, NSTextAlignmentLeft);

    // Thanh RAM: xanh đậm = đang dùng, xanh nhạt = còn trống, xám nhạt = Metal
    self.barBg = [UIView new];
    self.barBg.clipsToBounds = YES;
    NSArray *bg = @[[UIColor colorWithRed:0.10 green:0.30 blue:0.78 alpha:1],
                    [UIColor colorWithRed:0.50 green:0.75 blue:1.00 alpha:1],
                    [UIColor colorWithWhite:0.80 alpha:1]];
    NSArray *fg = @[UIColor.whiteColor,
                    [UIColor colorWithRed:0.04 green:0.14 blue:0.38 alpha:1],
                    [UIColor colorWithWhite:0.12 alpha:1]];
    NSMutableArray *segs = [NSMutableArray array], *lbls = [NSMutableArray array];
    for (int i = 0; i < 3; i++) {
        UIView *s = [UIView new];
        s.backgroundColor = bg[i];
        UILabel *l = FRLabel(fg[i], NSTextAlignmentCenter);
        if (i > 0) l.shadowColor = nil;
        [s addSubview:l];
        [self.barBg addSubview:s];
        [segs addObject:s]; [lbls addObject:l];
    }
    self.segs = segs; self.segLabels = lbls;

    [self.root addSubview:self.fps];
    [self.root addSubview:self.barBg];
    [self.root addSubview:self.app];
    [self.root addSubview:self.bat];
    [self.root addSubview:self.clock];
    [self.root addSubview:self.load];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)];
    pan.maximumNumberOfTouches = 1;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tap:)];
    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(pinch:)];
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPress:)];
    lp.minimumPressDuration = 0.6;
    for (UIGestureRecognizer *g in @[pan, tap, pinch, lp]) [self.root addGestureRecognizer:g];
    self.root.userInteractionEnabled = YES;

    [self relayout];
    [self attachIfNeeded];
    if (!self.collapsed) [self updateStats];

    self.lastFPS = CACurrentMediaTime();
    self.lastStat = 0;
    self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    [self.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

#pragma mark layout

- (void)renderFPS {
    if (self.fpsValue < 0) { self.fps.text = self.collapsed ? @"FPS --" : @"FPS: --"; return; }
    self.fps.text = [NSString stringWithFormat:self.collapsed ? @"FPS %d" : @"FPS: %d", self.fpsValue];
}

- (void)renderLoad {
    self.load.attributedText = FRLoadText(self.lastCPU, self.lastGPU, 11 * self.scale);
}

- (void)layoutBar {
    CGFloat k = self.scale, W = 190 * k, H = 18 * k;
    double vals[3] = { self.usedB, self.freeB, self.metalB };
    double total = vals[0] + vals[1] + vals[2];
    CGFloat x = 0;
    for (int i = 0; i < 3; i++) {
        CGFloat w = total > 0 ? W * (CGFloat)(vals[i] / total) : 0;
        if (i == 2) w = MAX(0, W - x);
        self.segs[i].frame = CGRectMake(x, 0, w, H);
        UILabel *l = self.segLabels[i];
        l.frame = CGRectMake(0, 0, w, H);
        FRSetFont(l, 11 * k, UIFontWeightSemibold);
        l.text = FRFmt(vals[i]);
        l.hidden = w < 26 * k;
        x += w;
    }
}

- (void)relayout {
    CGFloat k = self.scale;
    BOOL c = self.collapsed;
    CGPoint o = self.root.frame.origin;

    for (UIView *v in @[self.barBg, self.app, self.bat, self.clock, self.load]) v.hidden = c;

    if (c) {
        self.root.frame = CGRectMake(o.x, o.y, 70 * k, 20 * k);
        self.fps.frame = CGRectMake(0, 0, 70 * k, 20 * k);
        FRSetFont(self.fps, 13 * k, UIFontWeightBold);
        self.fps.textAlignment = NSTextAlignmentLeft;
    } else {
        CGFloat W = 190 * k;
        self.root.frame = CGRectMake(o.x, o.y, W, 116 * k);
        self.fps.frame   = CGRectMake(0, 0, W, 20 * k);
        self.barBg.frame = CGRectMake(0, 24 * k, W, 18 * k);
        self.barBg.layer.cornerRadius = 3 * k;
        self.app.frame   = CGRectMake(0, 46 * k, W, 16 * k);
        self.bat.frame   = CGRectMake(0, 64 * k, W, 16 * k);
        self.clock.frame = CGRectMake(0, 80 * k, W, 16 * k);
        self.load.frame  = CGRectMake(0, 98 * k, W, 16 * k);
        FRSetFont(self.fps, 15 * k, UIFontWeightBold);
        FRSetFont(self.app, 12 * k, UIFontWeightBold);
        FRSetFont(self.bat, 12 * k, UIFontWeightBold);
        FRSetFont(self.clock, 12 * k, UIFontWeightRegular);
        [self layoutBar];
        [self renderLoad];
    }
    [self renderFPS];
    [self clamp];
}

- (void)clamp {
    UIView *sv = self.root.superview;
    if (!sv) return;
    CGRect f = self.root.frame;
    f.origin.x = MIN(MAX(f.origin.x, 0), MAX(0, sv.bounds.size.width - f.size.width));
    f.origin.y = MIN(MAX(f.origin.y, 0), MAX(0, sv.bounds.size.height - f.size.height));
    self.root.frame = f;
}

- (void)attachIfNeeded {
    UIWindow *w = FRFindWindow();
    if (!w) return;
    if (self.root.superview != w) {
        CGPoint o;
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        if (!self.placed && [d objectForKey:@"FRX"]) {
            o = CGPointMake([d doubleForKey:@"FRX"], [d doubleForKey:@"FRY"]);
        } else if (!self.placed) {
            o = CGPointMake(MAX(w.safeAreaInsets.left, 8) + 4, MAX(w.safeAreaInsets.top, 8) + 2);
        } else {
            o = self.root.frame.origin;
        }
        self.placed = YES;
        [self.root removeFromSuperview];
        CGRect f = self.root.frame; f.origin = o;
        self.root.frame = f;
        [w addSubview:self.root];
        [self clamp];
    } else {
        [w bringSubviewToFront:self.root];
    }
}

#pragma mark gestures

- (void)savePosition {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setDouble:self.root.frame.origin.x forKey:@"FRX"];
    [d setDouble:self.root.frame.origin.y forKey:@"FRY"];
}

- (void)pan:(UIPanGestureRecognizer *)g {
    UIView *sv = self.root.superview;
    if (!sv) return;
    CGPoint t = [g translationInView:sv];
    CGRect f = self.root.frame;
    f.origin.x += t.x;
    f.origin.y += t.y;
    self.root.frame = f;
    [g setTranslation:CGPointZero inView:sv];
    [self clamp];
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) [self savePosition];
}

- (void)tap:(UITapGestureRecognizer *)g {
    self.collapsed = !self.collapsed;
    [NSUserDefaults.standardUserDefaults setBool:self.collapsed forKey:@"FRCollapsed"];
    [self relayout];
    if (!self.collapsed) [self updateStats];
    [self savePosition];
}

- (void)pinch:(UIPinchGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) self.baseScale = self.scale;
    if (g.state == UIGestureRecognizerStateBegan || g.state == UIGestureRecognizerStateChanged) {
        self.scale = MIN(MAX(self.baseScale * g.scale, kMinScale), kMaxScale);
        [self relayout];
    }
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        [NSUserDefaults.standardUserDefaults setDouble:self.scale forKey:@"FRScale"];
        [self savePosition];
    }
}

// Nhấn giữ: đổi nhanh qua các cỡ 0.8 -> 1.0 -> 1.3 -> 1.7 -> 2.2
- (void)longPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    CGFloat presets[] = { 0.8, 1.0, 1.3, 1.7, 2.2 };
    CGFloat next = presets[0];
    for (int i = 0; i < 5; i++) {
        if (presets[i] > self.scale + 0.01) { next = presets[i]; break; }
    }
    self.scale = next;
    [NSUserDefaults.standardUserDefaults setDouble:self.scale forKey:@"FRScale"];
    [self relayout];
    [self savePosition];
}

#pragma mark update

- (void)updateStats {
    FRSysMem(&_usedB, &_freeB);
    self.metalB = FRMetalBytes();
    [self layoutBar];

    self.appB = FRAppBytes();
    double limit = FR_RAM_LIMIT_MB * 1024.0 * 1024.0;
    double ratio = self.appB / limit;
    self.app.text = [NSString stringWithFormat:@"APP %@ / %@%@", FRFmt(self.appB), FRFmt(limit), ratio > 1 ? @" !" : @""];
    self.app.textColor = ratio > 1 ? [UIColor colorWithRed:1.0 green:0.30 blue:0.30 alpha:1]
                       : ratio > 0.8 ? [UIColor colorWithRed:1.0 green:0.85 blue:0.20 alpha:1]
                                     : [UIColor colorWithWhite:0.92 alpha:1];

    UIDevice *dev = UIDevice.currentDevice;
    float lvl = dev.batteryLevel;
    BOOL charging = dev.batteryState == UIDeviceBatteryStateCharging || dev.batteryState == UIDeviceBatteryStateFull;
    self.bat.text = lvl < 0 ? @"BAT --" : [NSString stringWithFormat:@"BAT %d%%%@", (int)lroundf(lvl * 100), charging ? @" ⚡" : @""];

    self.clock.text = [self.df stringFromDate:NSDate.date];
    self.lastCPU = FRCPU();
    self.lastGPU = FRGPU();
    [self renderLoad];
}

// Giới hạn mềm: chạy mỗi ~0.5 giây, kể cả khi HUD đang thu gọn
- (void)enforceLimit {
    double limit = FR_RAM_LIMIT_MB * 1024.0 * 1024.0;
    if (FRAppBytes() <= limit) return;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - self.lastTrim < 3.0) return;
    self.lastTrim = now;

    malloc_zone_pressure_relief(NULL, 0);

    UIApplication *a = UIApplication.sharedApplication;
    SEL sel = NSSelectorFromString(@"_performMemoryWarning");
    if ([a respondsToSelector:sel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [a performSelector:sel];
#pragma clang diagnostic pop
    } else {
        [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidReceiveMemoryWarningNotification object:a];
    }
}

- (void)tick:(CADisplayLink *)l {
    self.frames++;
    CFTimeInterval now = l.timestamp;
    CFTimeInterval dt = now - self.lastFPS;
    if (dt < 0.5) return;

    self.fpsValue = (int)lround(self.frames / dt);
    self.frames = 0;
    self.lastFPS = now;

    [self attachIfNeeded];
    [self renderFPS];
    [self enforceLimit];
    if (now - self.lastStat >= 1.0) {
        self.lastStat = now;
        if (!self.collapsed) [self updateStats];
    }
}

@end

static FRHud *gHud;

__attribute__((constructor))
static void FRInit(void) {
    FRApplyHardLimit();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        gHud = [FRHud new];
        [gHud start];
    });
}
