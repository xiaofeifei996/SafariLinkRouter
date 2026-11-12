#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import "LRCore.h"

static NSString *const kSLRHandlerName = @"SLRHandler";
static const void *kSLRHandlerKey = &kSLRHandlerKey;

#pragma mark - JS → Native 消息

@interface SLRMessageHandler : NSObject <WKScriptMessageHandler>
@end

@implementation SLRMessageHandler

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.name isEqualToString:kSLRHandlerName]) return;
    id body = message.body;
    NSString *urlString = nil;
    if ([body isKindOfClass:[NSDictionary class]]) {
        id u = body[@"url"];
        if ([u isKindOfClass:[NSString class]]) urlString = u;
    } else if ([body isKindOfClass:[NSString class]]) {
        urlString = body;
    }
    if (urlString.length) LRHandleURLString(urlString);
}

@end

#pragma mark - 安装注入

static void SLRInstallIntoConfiguration(WKWebViewConfiguration *configuration) {
    if (!configuration) return;
    @try {
        WKUserContentController *ucc = configuration.userContentController;
        if (!ucc) {
            ucc = [WKUserContentController new];
            configuration.userContentController = ucc;
        }
        if (objc_getAssociatedObject(ucc, kSLRHandlerKey)) return;

        SLRMessageHandler *handler = [SLRMessageHandler new];
        objc_setAssociatedObject(ucc, kSLRHandlerKey, handler, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [ucc addScriptMessageHandler:handler name:kSLRHandlerName];

        NSString *src = LRUserScriptSource();
        WKUserScript *script = [[WKUserScript alloc] initWithSource:src
                                                       injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                    forMainFrameOnly:NO];
        [ucc addUserScript:script];
        NSLog(@"[SLR] injected into WKWebView");
    } @catch (NSException *e) {
        NSLog(@"[SLR] inject failed: %@", e);
    }
}

#pragma mark - Hooks

%hook WKWebView

- (instancetype)initWithFrame:(CGRect)frame configuration:(WKWebViewConfiguration *)configuration {
    SLRInstallIntoConfiguration(configuration);
    return %orig;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    id v = %orig;
    if (v) SLRInstallIntoConfiguration([(WKWebView *)v configuration]);
    return v;
}

%end

%hook UIApplication

- (BOOL)canOpenURL:(NSURL *)url {
    if (LRShouldInterceptURL(url)) return YES;   // 让 Safari 走 openURL，而不是直接报"网址无效"
    return %orig;
}

- (void)openURL:(NSURL *)url options:(NSDictionary *)options completionHandler:(void (^)(BOOL))completion {
    if (LRShouldInterceptURL(url)) {
        LRHandleURLString(url.absoluteString);
        if (completion) completion(YES);
        return;
    }
    %orig;
}

- (BOOL)openURL:(NSURL *)url {
    if (LRShouldInterceptURL(url)) {
        LRHandleURLString(url.absoluteString);
        return YES;
    }
    return %orig;
}

%end
