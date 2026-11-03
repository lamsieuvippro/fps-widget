// FPSRAMOverlay.m  (v2)
// HUD: FPS, thanh RAM hệ thống, RAM free, RAM của app, pin, giờ, CPU, GPU.
// - Kéo để di chuyển (nhớ vị trí)
// - Chạm 1 lần để thu gọn / mở rộng
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach.h>
#import <dlfcn.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

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

// RAM của chính app (giống Xcode)
static double FRAppBytes(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
    return (double)info.phys_footprint;
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

// GPU (%): iOS không có API công khai. Thử đọc IOAccelerator qua IOKit (dlopen).
// Nếu hệ thống chặn thì trả -1 và HUD hiện "--".
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

static UILabel *FRLabel(CGRect f, CGFloat size, UIFontWeight w, UIColor *c, NSTextAlignment a) {
    UILabel *l = [[UILabel alloc] initWithFrame:f];
    l.font = [UIFont monospacedSystemFontOfSize:size weight:w];
    l.textColor = c;
    l.textAlignment = a;
    l.adjustsFontSizeToFitWidth = YES;
    l.minimumScaleFactor = 0.6;
    l.shadowColor = [UIColor colorWithWhite:0 alpha:0.6];
    l.shadowOffset = CGSizeMake(0, 1);
    return l;
}

static NSAttributedString *FRLoadText(int cpu, int gpu) {
    UIFont *f = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightSemibold];
    UIColor *blue = [UIColor colorWithRed:0.25 green:0.55 blue:1.0 alpha:1];
    UIColor *orange = [UIColor colorWithRed:1.0 green:0.60 blue:0.10 alpha:1];
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

static const CGFloat kBarW = 96;

@interface FRHud : NSObject
@property (nonatomic, strong) UIView *root, *barBg, *barFill;
@property (nonatomic, strong) UILabel *fps, *memUsed, *memFree, *memApp, *bat, *clock, *load;
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic, strong) NSDateFormatter *df;
@property (nonatomic) CFTimeInterval lastFPS, lastStat;
@property (nonatomic) NSUInteger frames;
@property (nonatomic) int fpsValue;
@property (nonatomic) BOOL collapsed, placed;
@end

@implementation FRHud

- (void)start {
    UIDevice.currentDevice.batteryMonitoringEnabled = YES;
    self.df = [NSDateFormatter new];
    self.df.dateFormat = @"HH:mm";
    self.fpsValue = -1;
    self.collapsed = [NSUserDefaults.standardUserDefaults boolForKey:@"FRCollapsed"];

    UIColor *gray = [UIColor colorWithWhite:0.85 alpha:1];

    self.root = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 196, 106)];
    self.root.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    self.root.layer.cornerRadius = 8;
    self.root.layer.zPosition = CGFLOAT_MAX;

    self.fps = FRLabel(CGRectMake(8, 4, 180, 20), 15, UIFontWeightBold, gray, NSTextAlignmentLeft);
    [self.root addSubview:self.fps];

    self.barBg = [[UIView alloc] initWithFrame:CGRectMake(8, 28, kBarW, 18)];
    self.barBg.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    self.barBg.clipsToBounds = YES;
    self.barFill = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, 18)];
    self.barFill.backgroundColor = [UIColor colorWithRed:0.18 green:0.42 blue:0.85 alpha:0.9];
    [self.barBg addSubview:self.barFill];
    self.memUsed = FRLabel(CGRectMake(0, 0, kBarW, 18), 11, UIFontWeightSemibold, UIColor.whiteColor, NSTextAlignmentCenter);
    [self.barBg addSubview:self.memUsed];
    [self.root addSubview:self.barBg];

    self.memFree = FRLabel(CGRectMake(108, 28, 40, 18), 11, UIFontWeightSemibold, gray, NSTextAlignmentCenter);
    self.memApp  = FRLabel(CGRectMake(148, 28, 40, 18), 11, UIFontWeightSemibold, gray, NSTextAlignmentCenter);
    [self.root addSubview:self.memFree];
    [self.root addSubview:self.memApp];

    self.bat = FRLabel(CGRectMake(8, 50, 180, 16), 12, UIFontWeightBold,
                       [UIColor colorWithRed:0.35 green:0.9 blue:0.35 alpha:1], NSTextAlignmentLeft);
    self.clock = FRLabel(CGRectMake(8, 67, 180, 16), 12, UIFontWeightRegular,
                         [UIColor colorWithWhite:0.7 alpha:1], NSTextAlignmentLeft);
    self.load = FRLabel(CGRectMake(8, 85, 184, 16), 11, UIFontWeightSemibold, UIColor.whiteColor, NSTextAlignmentLeft);
    [self.root addSubview:self.bat];
    [self.root addSubview:self.clock];
    [self.root addSubview:self.load];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tap:)];
    [self.root addGestureRecognizer:pan];
    [self.root addGestureRecognizer:tap];
    self.root.userInteractionEnabled = YES;

    [self applyState];
    [self attachIfNeeded];

    self.lastFPS = CACurrentMediaTime();
    self.lastStat = 0;
    self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    [self.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

#pragma mark layout / state

- (void)renderFPS {
    if (self.fpsValue < 0) { self.fps.text = self.collapsed ? @"FPS --" : @"FPS: --"; return; }
    self.fps.text = [NSString stringWithFormat:self.collapsed ? @"FPS %d" : @"FPS: %d", self.fpsValue];
}

- (void)applyState {
    BOOL c = self.collapsed;
    CGPoint o = self.root.frame.origin;
    self.root.frame = CGRectMake(o.x, o.y, c ? 74 : 196, c ? 26 : 106);
    for (UIView *v in @[self.barBg, self.memFree, self.memApp, self.bat, self.clock, self.load]) v.hidden = c;
    self.fps.font = [UIFont monospacedSystemFontOfSize:(c ? 12 : 15) weight:UIFontWeightBold];
    self.fps.frame = c ? CGRectMake(4, 3, 66, 20) : CGRectMake(8, 4, 180, 20);
    self.fps.textAlignment = c ? NSTextAlignmentCenter : NSTextAlignmentLeft;
    [self renderFPS];
    [self clamp];
    if (!c) [self updateStats];
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
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        [d setDouble:self.root.frame.origin.x forKey:@"FRX"];
        [d setDouble:self.root.frame.origin.y forKey:@"FRY"];
    }
}

- (void)tap:(UITapGestureRecognizer *)g {
    self.collapsed = !self.collapsed;
    [NSUserDefaults.standardUserDefaults setBool:self.collapsed forKey:@"FRCollapsed"];
    [self applyState];
}

#pragma mark update

- (void)updateStats {
    double used, freeB;
    FRSysMem(&used, &freeB);
    double total = used + freeB;
    self.memUsed.text = FRFmt(used);
    self.barFill.frame = CGRectMake(0, 0, total > 0 ? kBarW * (used / total) : 0, 18);
    self.memFree.text = FRFmt(freeB);
    self.memApp.text = FRFmt(FRAppBytes());

    UIDevice *dev = UIDevice.currentDevice;
    float lvl = dev.batteryLevel;
    BOOL charging = dev.batteryState == UIDeviceBatteryStateCharging || dev.batteryState == UIDeviceBatteryStateFull;
    self.bat.text = lvl < 0 ? @"BAT --" : [NSString stringWithFormat:@"BAT %d%%%@", (int)lroundf(lvl * 100), charging ? @" ⚡" : @""];

    self.clock.text = [self.df stringFromDate:NSDate.date];
    self.load.attributedText = FRLoadText(FRCPU(), FRGPU());
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
    if (now - self.lastStat >= 1.0) {
        self.lastStat = now;
        if (!self.collapsed) [self updateStats];
    }
}

@end

static FRHud *gHud;

__attribute__((constructor))
static void FRInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        gHud = [FRHud new];
        [gHud start];
    });
}
