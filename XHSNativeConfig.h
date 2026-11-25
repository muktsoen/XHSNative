//
//  XHSNative
//
//  Copyright (c) 2026 huami. All rights reserved.
//  Channel: @huamidev
//  Created on: 2026/11/24
//
#import <UIKit/UIKit.h>

#define XHSNativeVersion @"1.3.2(11251030)"

@class XYTabbarController;

// 开关，默认都是开的
extern NSString *const kXHSNativeSearchTab;     // 右侧的搜索
extern NSString *const kXHSNativeMinimize;      // 滚动时收起底栏
extern NSString *const kXHSNativeGlassNote;
extern NSString *const kXHSNativeGlassSearch;
extern NSString *const kXHSNativeGlassComments;
extern NSString *const kXHSNativeGlassProfile;
extern NSString *const kXHSNativeGlassChat;
extern NSString *const kXHSNativeGlassMessages;
extern NSString *const kXHSNativeGlassVideo;

// 各处玻璃的名字，用来存它们的不透明度
extern NSString *const kXHSNativeBarHome;
extern NSString *const kXHSNativeBarNoteTop;
extern NSString *const kXHSNativeBarNoteBottom;
extern NSString *const kXHSNativeBarVideoTop;
extern NSString *const kXHSNativeBarVideoBottom;
extern NSString *const kXHSNativeBarComment;
extern NSString *const kXHSNativeBarProfile;

@interface XHSNativeConfig : NSObject

+ (instancetype)shared;

#pragma mark - 运行时状态（不落盘）

@property (nonatomic, weak) XYTabbarController *tabBarController;
@property (nonatomic, weak) UIControl *searchButton;  // 首页顶栏原来的搜索按钮，被收起来了，但还能替用户点
@property (nonatomic, weak) UIView *homeBar;
@property (nonatomic, copy) NSArray<UIViewController *> *pages;  // 小红书自己的页面顺序：首页 市集 消息 我
@property (nonatomic, copy) NSArray<NSString *> *pageNames;
@property (nonatomic, strong) UIViewController *searchPage;      // 搜索标签挂的空页面，它不会真的显示
@property (nonatomic, assign) BOOL rebuilding;
@property (nonatomic, assign) BOOL tabsDirty;  // 底栏被盖住时改了设置，等露出来再重排

#pragma mark - 持久设置（NSUserDefaults）

// 标签的名字：index / shopping / message / me
@property (class, nonatomic, readonly) NSArray<NSString *> *allTabs;

- (BOOL)boolForKey:(NSString *)key;
- (void)setBool:(BOOL)value forKey:(NSString *)key;

- (NSArray<NSString *> *)tabOrder;
- (void)setTabOrder:(NSArray<NSString *> *)order;
- (BOOL)isTabHidden:(NSString *)name;
- (void)setTab:(NSString *)name hidden:(BOOL)hidden;

// 0 是纯玻璃，100 不透
- (CGFloat)fillForBar:(NSString *)bar;
- (void)setFill:(CGFloat)fill forBar:(NSString *)bar;

// 清掉所有 XHSNative 的设置
- (void)reset;

@end
