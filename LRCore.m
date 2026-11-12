#import "LRCore.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

#pragma mark - 私有 API 声明（运行时动态调用，不静态链接）

@interface LSApplicationProxy : NSObject
- (NSString *)bundleIdentifier;
- (NSString *)localizedName;
- (NSString *)applicationType;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)applicationsAvailableForOpeningURL:(NSURL *)url;
- (NSArray *)allInstalledApplications;
@end

#pragma mark - 配置

static NSString *gConfigPath = nil;

static NSString *const kPrefsName = @"com.xiaofeifei.safarilinkrouter.plist";

static NSArray *LRConfigCandidatePaths(void) {
    NSMutableArray *a = [NSMutableArray array];
    NSString *envRoot = NSProcessInfo.processInfo.environment[@"JB_ROOT_PATH"];
    if (envRoot.length) {
        [a addObject:[envRoot stringByAppendingPathComponent:
                     [@"var/mobile/Library/Preferences" stringByAppendingPathComponent:kPrefsName]]];
    }
    [a addObject:[@"/var/mobile/Library/Preferences" stringByAppendingPathComponent:kPrefsName]];
    [a addObject:[@"/var/jb/var/mobile/Library/Preferences" stringByAppendingPathComponent:kPrefsName]];
    return a;
}

static NSString *LRConfigPath(void) {
    if (gConfigPath) return gConfigPath;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *cands = LRConfigCandidatePaths();
    for (NSString *p in cands) {
        if ([fm fileExistsAtPath:p]) { gConfigPath = p; return p; }
    }
    for (NSString *p in cands) {
        NSString *dir = [p stringByDeletingLastPathComponent];
        if ([fm isWritableFileAtPath:dir]) { gConfigPath = p; return p; }
    }
    gConfigPath = cands.firstObject;
    return gConfigPath;
}

static NSDictionary *LRDefaultConfig(void) {
    return @{
        @"enabled": @YES,
        @"interceptUnknown": @YES,
        @"schemes": @[@"magnet", @"ed2k", @"thunder", @"ftp", @"xl"],
        @"rules": @{}
    };
}

NSDictionary *LRConfigDict(void) {
    NSMutableDictionary *d = [LRDefaultConfig() mutableCopy];
    NSDictionary *raw = [NSDictionary dictionaryWithContentsOfFile:LRConfigPath()];
    if ([raw isKindOfClass:[NSDictionary class]]) {
        for (id k in raw) {
            if (![k isKindOfClass:[NSString class]]) continue;
            id v = raw[k];
            if (v) d[k] = v;
        }
    }
    if (![d[@"schemes"] isKindOfClass:[NSArray class]]) d[@"schemes"] = LRDefaultConfig()[@"schemes"];
    if (![d[@"rules"] isKindOfClass:[NSDictionary class]]) d[@"rules"] = @{};
    return d;
}

static void LRSaveRule(NSString *scheme, NSDictionary *rule) {
    if (!scheme.length) return;
    NSString *path = LRConfigPath();
    NSMutableDictionary *raw = [NSMutableDictionary dictionaryWithContentsOfFile:path];
    if (!raw) raw = [NSMutableDictionary dictionary];
    NSMutableDictionary *rules = nil;
    if ([raw[@"rules"] isKindOfClass:[NSDictionary class]]) {
        rules = [raw[@"rules"] mutableCopy];
    } else {
        rules = [NSMutableDictionary dictionary];
    }
    if (rule) rules[scheme] = rule; else [rules removeObjectForKey:scheme];
    raw[@"rules"] = rules;
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                             withIntermediateDirectories:YES attributes:nil error:nil];
    if ([raw writeToFile:path atomically:YES]) {
        gConfigPath = path;
        NSLog(@"[SLR] rule saved: %@ -> %@", scheme, rule);
    } else {
        NSLog(@"[SLR] rule save FAILED at %@", path);
    }
}

#pragma mark - 私有 API 运行时桥

static id LRWorkspace(void) {
    static id ws = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class c = NSClassFromString(@"LSApplicationWorkspace");
        if (!c) {
            dlopen("/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
            c = NSClassFromString(@"LSApplicationWorkspace");
        }
        if (!c) {
            dlopen("/System/Library/PrivateFrameworks/CoreServices.framework/CoreServices", RTLD_LAZY);
            c = NSClassFromString(@"LSApplicationWorkspace");
        }
        if ([c respondsToSelector:@selector(defaultWorkspace)]) {
            ws = [c performSelector:@selector(defaultWorkspace)];
        }
    });
    return ws;
}

static BOOL LRInvokeBool2(id target, SEL sel, id a1, id a2) {
    if (!target || ![target respondsToSelector:sel]) return NO;
    NSMethodSignature *sig = [target methodSignatureForSelector:sel];
    if (!sig) return NO;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = target;
    inv.selector = sel;
    if (a1) [inv setArgument:&a1 atIndex:2];
    if (a2) [inv setArgument:&a2 atIndex:3];
    [inv invoke];
    BOOL r = NO;
    if (sig.methodReturnLength >= sizeof(BOOL)) [inv getReturnValue:&r];
    return r;
}

static BOOL LRInvokeBool1(id target, SEL sel, id a1) {
    if (!target || ![target respondsToSelector:sel]) return NO;
    NSMethodSignature *sig = [target methodSignatureForSelector:sel];
    if (!sig) return NO;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = target;
    inv.selector = sel;
    if (a1) [inv setArgument:&a1 atIndex:2];
    [inv invoke];
    BOOL r = NO;
    if (sig.methodReturnLength >= sizeof(BOOL)) [inv getReturnValue:&r];
    return r;
}

static id LRInvokeID1(id target, SEL sel, id a1) {
    if (!target || ![target respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(target, sel, a1);
}

static NSArray *LRAppsForURL(NSURL *url) {
    id ws = LRWorkspace();
    if (!ws) return @[];
    id r = LRInvokeID1(ws, @selector(applicationsAvailableForOpeningURL:), url);
    return [r isKindOfClass:[NSArray class]] ? r : @[];
}

static void LROpenURL(NSURL *url) {
    id ws = LRWorkspace();
    if (!ws) return;
    if ([ws respondsToSelector:@selector(openSensitiveURL:withOptions:)]) {
        LRInvokeBool2(ws, @selector(openSensitiveURL:withOptions:), url, nil);
    }
}

static void LRCopy(NSString *s) {
    if (!s.length) return;
    [UIPasteboard generalPasteboard].string = s;
}

static NSString *LRBTIH(NSURL *url) {
    NSString *s = url.absoluteString ?: @"";
    NSRange r = [s rangeOfString:@"btih:" options:NSCaseInsensitiveSearch];
    if (r.location == NSNotFound) return @"";
    NSString *rest = [s substringFromIndex:NSMaxRange(r)];
    NSRange amp = [rest rangeOfString:@"&"];
    if (amp.location != NSNotFound) rest = [rest substringToIndex:amp.location];
    return rest;
}

#pragma mark - UI 辅助

static UIWindow *LRKeyWindow(void) {
    UIWindow *fallback = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) return w;
            if (!fallback && !w.isHidden && w.alpha > 0.01) fallback = w;
        }
    }
    if (!fallback) fallback = UIApplication.sharedApplication.keyWindow;
    return fallback;
}

static UIViewController *LRTopViewController(void) {
    UIWindow *w = LRKeyWindow();
    UIViewController *vc = w.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if (!vc) {
        for (UIWindow *win in UIApplication.sharedApplication.windows) {
            UIViewController *c = win.rootViewController;
            while (c.presentedViewController) c = c.presentedViewController;
            if (c) return c;
        }
    }
    return vc;
}

static void LRToast(NSString *text) {
    if (!text.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *w = LRKeyWindow();
        if (!w) return;
        UILabel *l = [UILabel new];
        l.text = text;
        l.textColor = UIColor.whiteColor;
        l.font = [UIFont boldSystemFontOfSize:14];
        l.textAlignment = NSTextAlignmentCenter;
        l.numberOfLines = 2;
        l.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.8];
        l.layer.cornerRadius = 12;
        l.layer.masksToBounds = YES;
        l.userInteractionEnabled = NO;
        [l sizeToFit];
        CGSize sz = l.bounds.size;
        CGFloat width = MIN(sz.width + 32, w.bounds.size.width - 40);
        l.frame = CGRectMake((w.bounds.size.width - width) / 2.0,
                             w.bounds.size.height - 160,
                             width, sz.height + 20);
        l.alpha = 0;
        [w addSubview:l];
        [UIView animateWithDuration:0.18 animations:^{ l.alpha = 1.0; } completion:^(BOOL f) {
            [UIView animateWithDuration:0.3 delay:1.5 options:0 animations:^{ l.alpha = 0.0; }
                             completion:^(BOOL f2) { [l removeFromSuperview]; }];
        }];
    });
}

#pragma mark - App 选择器

@interface LRAppPickerViewController : UITableViewController
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, strong) NSArray<NSDictionary *> *apps;
@end

@implementation LRAppPickerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"选择 App";
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                      target:self action:@selector(cancel)];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"手动输入" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(manual)];
    [self reloadApps];
}

- (void)reloadApps {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray *out = [NSMutableArray array];
        id ws = LRWorkspace();
        if ([ws respondsToSelector:@selector(allInstalledApplications)]) {
            NSArray *all = ((id (*)(id, SEL))objc_msgSend)(ws, @selector(allInstalledApplications));
            if ([all isKindOfClass:[NSArray class]]) {
                for (id p in all) {
                    NSString *type = nil;
                    if ([p respondsToSelector:@selector(applicationType)]) {
                        type = ((id (*)(id, SEL))objc_msgSend)(p, @selector(applicationType));
                    }
                    if (type.length && ![type isEqualToString:@"User"]) continue;
                    NSString *bid = nil, *name = nil;
                    if ([p respondsToSelector:@selector(bundleIdentifier)]) {
                        bid = ((id (*)(id, SEL))objc_msgSend)(p, @selector(bundleIdentifier));
                    }
                    if ([p respondsToSelector:@selector(localizedName)]) {
                        name = ((id (*)(id, SEL))objc_msgSend)(p, @selector(localizedName));
                    }
                    if (!bid.length) continue;
                    if (!name.length) name = bid;
                    [out addObject:@{@"id": bid, @"name": name}];
                }
            }
        }
        [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
        }];
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.apps = out;
            [weakSelf.tableView reloadData];
        });
    });
}

- (void)cancel {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)manual {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"输入 Bundle ID"
                                                                message:@"例如 com.example.app"
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"com.example.app";
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *bid = ac.textFields.firstObject.text;
        if (bid.length) [self pickBundleID:bid name:bid];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)pickBundleID:(NSString *)bundleID name:(NSString *)name {
    NSURL *url = self.url;
    NSString *scheme = url.scheme.lowercaseString ?: @"*";
    LRSaveRule(scheme, @{@"action": @"copyOpen", @"bundleID": bundleID});
    LRCopy(url.absoluteString);
    [self dismissViewControllerAnimated:YES completion:^{
        id ws = LRWorkspace();
        if ([ws respondsToSelector:@selector(openApplicationWithBundleID:)]) {
            LRInvokeBool1(ws, @selector(openApplicationWithBundleID:), bundleID);
        }
        LRToast([NSString stringWithFormat:@"已复制链接，正在打开「%@」", name]);
    }];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    return self.apps.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"app"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"app"];
    }
    NSDictionary *app = self.apps[ip.row];
    cell.textLabel.text = app[@"name"];
    cell.detailTextLabel.text = app[@"id"];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSDictionary *app = self.apps[ip.row];
    [self pickBundleID:app[@"id"] name:app[@"name"]];
}

@end

#pragma mark - 动作执行

static NSString *LRFillTemplate(NSString *tpl, NSURL *url) {
    NSString *raw = url.absoluteString ?: @"";
    NSString *esc = [raw stringByAddingPercentEncodingWithAllowedCharacters:
                        [NSCharacterSet URLQueryAllowedCharacterSet]];
    if (!esc) esc = raw;
    NSMutableString *s = [tpl mutableCopy];
    [s replaceOccurrencesOfString:@"{url}" withString:esc options:0 range:NSMakeRange(0, s.length)];
    [s replaceOccurrencesOfString:@"{raw}" withString:raw options:0 range:NSMakeRange(0, s.length)];
    [s replaceOccurrencesOfString:@"{hash}" withString:LRBTIH(url) options:0 range:NSMakeRange(0, s.length)];
    return s;
}

static void LRShowSheet(NSURL *url);

static void LROpenAppBundle(NSString *bundleID) {
    id ws = LRWorkspace();
    if (bundleID.length && [ws respondsToSelector:@selector(openApplicationWithBundleID:)]) {
        LRInvokeBool1(ws, @selector(openApplicationWithBundleID:), bundleID);
    }
}

static void LRPerformAction(NSString *action, NSString *bundleID, NSString *tpl, NSURL *url) {
    if ([action isEqualToString:@"copy"]) {
        LRCopy(url.absoluteString);
        LRToast(@"已复制链接");
        return;
    }
    if ([action isEqualToString:@"open"]) {
        if (LRAppsForURL(url).count > 0) {
            LROpenURL(url);
        } else {
            LRToast(@"没有 App 能打开该链接");
        }
        return;
    }
    if ([action isEqualToString:@"template"] && tpl.length) {
        NSURL *u = [NSURL URLWithString:LRFillTemplate(tpl, url)];
        if (u) LROpenURL(u);
        return;
    }
    if ([action isEqualToString:@"copyOpen"] && bundleID.length) {
        LRCopy(url.absoluteString);
        LROpenAppBundle(bundleID);
        return;
    }
    LRShowSheet(url);
}

static void LRPresentAppPicker(NSURL *url) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIViewController *top = LRTopViewController();
        if (!top) return;
        LRAppPickerViewController *pick = [LRAppPickerViewController new];
        pick.url = url;
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:pick];
        [top presentViewController:nav animated:YES completion:nil];
    });
}

static void LRShowSheet(NSURL *url) {
    UIViewController *vc = LRTopViewController();
    if (!vc) return;
    NSString *scheme = url.scheme.lowercaseString ?: @"链接";
    NSString *full = url.absoluteString ?: @"";
    NSString *msg = full.length > 110 ? [[full substringToIndex:110] stringByAppendingString:@"…"] : full;

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:
                                [NSString stringWithFormat:@"打开 %@ 链接", scheme]
                                                            message:msg
                                                     preferredStyle:UIAlertControllerStyleActionSheet];

    for (id proxy in LRAppsForURL(url)) {
        NSString *name = nil;
        if ([proxy respondsToSelector:@selector(localizedName)]) {
            name = ((id (*)(id, SEL))objc_msgSend)(proxy, @selector(localizedName));
        }
        if (!name.length) name = @"App";
        [ac addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"用「%@」打开", name]
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) { LROpenURL(url); }]];
    }

    [ac addAction:[UIAlertAction actionWithTitle:@"复制到剪贴板" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        LRCopy(url.absoluteString);
        LRToast(@"已复制链接");
    }]];

    [ac addAction:[UIAlertAction actionWithTitle:@"复制并用指定 App 打开…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        LRPresentAppPicker(url);
    }]];

    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    if (ac.popoverPresentationController) {
        ac.popoverPresentationController.sourceView = vc.view;
        ac.popoverPresentationController.sourceRect = CGRectMake(vc.view.bounds.size.width / 2.0,
                                                                 vc.view.bounds.size.height - 40, 1, 1);
    }
    [vc presentViewController:ac animated:YES completion:nil];
}

#pragma mark - 对外入口

static void LRHandleURLOnMain(NSURL *url) {
    NSString *scheme = url.scheme.lowercaseString ?: @"";
    NSDictionary *rules = LRConfigDict()[@"rules"];
    NSDictionary *rule = [rules isKindOfClass:[NSDictionary class]] ? rules[scheme] : nil;
    if (![rule isKindOfClass:[NSDictionary class]]) rule = [rules isKindOfClass:[NSDictionary class]] ? rules[@"*"] : nil;
    if ([rule isKindOfClass:[NSDictionary class]]) {
        LRPerformAction(rule[@"action"], rule[@"bundleID"], rule[@"template"], url);
        return;
    }
    LRShowSheet(url);
}

void LRHandleURLString(NSString *urlString) {
    if (![urlString isKindOfClass:[NSString class]] || urlString.length == 0) return;
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return;
    if (![LRConfigDict()[@"enabled"] boolValue]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            LRHandleURLOnMain(url);
        } @catch (NSException *e) {
            NSLog(@"[SLR] handle failed: %@", e);
        }
    });
}

static NSSet *LRWhitelistedSchemes(void) {
    static NSSet *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithArray:@[@"http", @"https", @"file", @"about", @"data", @"blob",
                                  @"javascript", @"ws", @"wss", @"tel", @"mailto", @"sms",
                                  @"facetime", @"facetime-audio", @"maps", @"itms", @"itms-apps",
                                  @"itms-services", @"app-settings", @"shortcuts", @"x-apple",
                                  @"safari"]];
    });
    return s;
}

BOOL LRShouldInterceptURL(NSURL *url) {
    if (!url) return NO;
    NSDictionary *cfg = LRConfigDict();
    if (![cfg[@"enabled"] boolValue]) return NO;
    NSString *scheme = url.scheme.lowercaseString;
    if (!scheme.length) return NO;
    if ([LRWhitelistedSchemes() containsObject:scheme]) return NO;
    NSArray *list = cfg[@"schemes"];
    if ([list containsObject:scheme] || [list containsObject:@"*"]) return YES;
    if ([cfg[@"interceptUnknown"] boolValue] && LRAppsForURL(url).count == 0) return YES;
    return NO;
}

#pragma mark - 注入脚本

static NSString *const kLRUserScriptTemplate = @"(function(){\n"
"  if (window.__slrInstalled) return; window.__slrInstalled = true;\n"
"  var TARGET = __SCHEMES__;\n"
"  var WL = ['http','https','file','about','data','blob','javascript','ws','wss','tel','mailto','sms','facetime','facetime-audio','maps','itms','itms-apps','itms-services','app-settings','shortcuts','x-apple','safari','ftp'];\n"
"  function schemeOf(u){ var m = /^([a-zA-Z][a-zA-Z0-9+.\\-]*):/.exec(u || ''); return m ? m[1].toLowerCase() : ''; }\n"
"  function should(u){ var s = schemeOf(u); if (!s) return false;\n"
"    if (WL.indexOf(s) >= 0) return false;\n"
"    return TARGET.indexOf(s) >= 0 || TARGET.indexOf('*') >= 0; }\n"
"  function send(u){ try { window.webkit.messageHandlers.__HANDLER__.postMessage({url: String(u), page: location.href}); } catch(e){} }\n"
"  function grab(e){\n"
"    var n = e.target;\n"
"    while (n && n.nodeType === 1) {\n"
"      if (n.tagName === 'A') {\n"
"        var u = n.href || n.getAttribute('href') || '';\n"
"        if (u && should(u)) { e.preventDefault(); e.stopPropagation(); e.stopImmediatePropagation(); send(u); return true; }\n"
"      }\n"
"      n = n.parentNode;\n"
"    }\n"
"    return false;\n"
"  }\n"
"  document.addEventListener('click', grab, true);\n"
"  document.addEventListener('auxclick', grab, true);\n"
"  var rawOpen = window.open;\n"
"  window.open = function(u){ if (u && should(String(u))) { send(String(u)); return null; } return rawOpen.apply(window, arguments); };\n"
"})();\n";

NSString *LRUserScriptSource(void) {
    NSDictionary *cfg = LRConfigDict();
    NSMutableArray *list = [NSMutableArray array];
    id schemes = cfg[@"schemes"];
    if ([schemes isKindOfClass:[NSArray class]]) [list addObjectsFromArray:schemes];
    if ([cfg[@"interceptUnknown"] boolValue]) [list addObject:@"*"];
    NSData *d = [NSJSONSerialization dataWithJSONObject:list options:0 error:nil];
    NSString *json = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"[]";
    if (!json) json = @"[]";
    NSString *src = [kLRUserScriptTemplate stringByReplacingOccurrencesOfString:@"__SCHEMES__" withString:json];
    src = [src stringByReplacingOccurrencesOfString:@"__HANDLER__" withString:@"SLRHandler"];
    return src;
}
}
