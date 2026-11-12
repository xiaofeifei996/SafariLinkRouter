#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 配置字典（带默认值）
FOUNDATION_EXPORT NSDictionary *LRConfigDict(void);
/// 拦截判断（供 native openURL 兜底用）
FOUNDATION_EXPORT BOOL LRShouldInterceptURL(NSURL *url);
/// 处理一个链接（内部会切到主线程弹 UI）
FOUNDATION_EXPORT void LRHandleURLString(NSString *urlString);
/// 注入到 WebContent 的用户脚本（带当前 scheme 配置）
FOUNDATION_EXPORT NSString *LRUserScriptSource(void);

NS_ASSUME_NONNULL_END
