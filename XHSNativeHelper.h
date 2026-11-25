//
//  XHSNative
//
//  Copyright (c) 2026 huami. All rights reserved.
//  Channel: @huamidev
//  Created on: 2026/11/24
//
#import <UIKit/UIKit.h>
#import "XHSNativeHeaders.h"

@interface XHSNativeHelper : NSObject

#pragma mark - 视图

// 垫在一组现有控件后面的胶囊形玻璃，控件本身不动。frame 传空矩形表示收起
+ (UIVisualEffectView *)plateOn:(UIView *)owner key:(const void *)key below:(UIView *)below frame:(CGRect)frame bar:(NSString *)bar;
+ (void)clearBackground:(UIView *)view;
// 把一排图标整体往里收，收的量按容器宽度算，反复调用结果一样
+ (void)insetRow:(UIView *)row to:(CGFloat)side;
+ (void)nudgeRow:(UIView *)bar side:(CGFloat)side;
+ (BOOL)isVisible:(UIView *)view;
+ (UIView *)subviewOf:(UIView *)view named:(NSString *)className;

#pragma mark - 小红书

// 调用是不是来自小红书主程序（而不是系统框架）
+ (BOOL)isAppAddress:(void *)address;
// 小红书图标库里的图标对象：XYThemeManager.defaultManager.icon.<name>
+ (id)themeGlyph:(NSString *)name;
+ (UIImage *)tabIcon:(NSString *)name selected:(BOOL)selected;

#pragma mark - 底栏

+ (UITab *)tabNamed:(NSString *)name;
+ (NSArray<NSString *> *)legacyTabNames:(XYTabbarController *)controller;
+ (void)refreshBadge:(UITabBarItem *)item;
+ (BOOL)isItemEnabled:(UITabBarItem *)item;
+ (BOOL)isOurTabBar:(UITabBar *)bar;
+ (void)rebuildTabs;
+ (void)openPublish;
+ (void)openSearch;

#pragma mark - 首页顶栏

+ (BOOL)isPinnedEdgeEffect:(UIScrollEdgeEffect *)effect;
+ (BOOL)hasSoftTopEdge:(UIScrollView *)list;
+ (void)useSoftTopEdge:(UIScrollView *)list;
+ (void)attachHomeBar:(UIScrollView *)list;
+ (void)attachVisibleList;
+ (void)stripBarBackground:(XYMHomeNaviBar *)bar;
+ (void)layoutHomeBar:(XYMHomeNaviBar *)bar;

#pragma mark - 滚动联动

+ (void)trackScrollView:(UIScrollView *)list;

#pragma mark - 页面

+ (void)extendTabPage:(UIViewController *)page;
+ (void)layoutNotePage:(UIViewController *)page;
+ (void)layoutNoteTop:(UIView *)bar;
+ (void)recenterAuthorRow:(UIView *)row;
+ (void)layoutVideoHead:(UIView *)head;
+ (void)layoutVideoEngage:(UIView *)bar;

#pragma mark - 设置界面

+ (NSString *)entryIdentity;
+ (id)entryOption;
+ (NSArray *)settingsRows;
+ (NSArray *)orderRows;
+ (NSArray *)percentRowsForBar:(NSString *)bar;
+ (NSString *)titleForMode:(NSString *)mode;
+ (UIView *)settingsFooterWithWidth:(CGFloat)width;
+ (void)handleTap:(NSString *)identity onPage:(XHSNativeSettingsPage *)page;
+ (void)handleSwitch:(NSString *)identity on:(BOOL)on;
+ (void)applySettings;

#pragma mark - iOS 27.1 以下

+ (void)patchOlderSystems;

@end
