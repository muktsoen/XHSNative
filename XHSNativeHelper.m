//
//  XHSNative
//
//  Copyright (c) 2026 huami. All rights reserved.
//  Channel: @huamidev
//  Created on: 2026/11/24
//
#import "XHSNativeHelper.h"
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <mach/mach.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "XHSNativeConfig.h"

#pragma mark - 底部胶囊

// 手机屏幕在底部收成 R 角（16 Pro 大概 55pt），胶囊只离屏幕边 8pt 时，
// 两头的圆会顺着 R 角走，看起来像被屏幕切掉一块。系统自己的浮起控件都留 16pt。
// 高度原来是图文 48 / 视频 44。这里取更宽一档：边距 22、高 42。
static const CGFloat kBottomSide = 22;
static const CGFloat kBottomHeight = 42;
// 右半边那组按钮整组往左让这么多，等于把输入框多余的那截宽度还回去
static const CGFloat kBottomInner = 12;
// 整条往下挪，原来贴着安全区上沿，看着偏高
static const CGFloat kBottomDrop = 6;

#pragma mark - 滚动联动

// 小红书的页面是多层嵌套的分页容器，系统找不到真正在滚的那个列表。
// 手指开始拖的时候把它登记成当前页面的内容滚动视图，系统的「滚动收起底栏」才会生效。

@interface XHSNativeScrollTracker : NSObject
@end

@implementation XHSNativeScrollTracker

+ (instancetype)shared {
    static XHSNativeScrollTracker *tracker;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ tracker = [XHSNativeScrollTracker new]; });
    return tracker;
}

- (void)pan:(UIPanGestureRecognizer *)pan {
    UIScrollView *list = (UIScrollView *)pan.view;
    if (pan.state != UIGestureRecognizerStateBegan || ![list isKindOfClass:UIScrollView.class]) return;
    // 只认竖向列表，横向分页容器不算
    if (list.contentSize.height <= CGRectGetHeight(list.bounds) && !list.alwaysBounceVertical) return;
    if (list.contentSize.width > CGRectGetWidth(list.bounds) + 1 && list.pagingEnabled) return;

    UINavigationController *navigation = (UINavigationController *)XHSNativeConfig.shared.tabBarController.selectedViewController;
    UIViewController *page = [navigation isKindOfClass:UINavigationController.class] ? navigation.topViewController : navigation;
    if (!page.isViewLoaded || ![list isDescendantOfView:page.view]) return;
    [XHSNativeHelper attachHomeBar:list];
    if ([page contentScrollViewForEdge:NSDirectionalRectEdgeBottom] != list) [page setContentScrollView:list forEdge:NSDirectionalRectEdgeBottom];
}

@end

#pragma mark - iOS 27.1 以下

// 首页的下沉布局是按 iOS 27.1 写的，用到三个更早的系统上没有的东西：
// 特征 verticalBarEdge，Swift 的 UITraitCollection.systemTraitsAffectingVerticalBarEdge
// 和 UIView.LayoutRegion.bar(onEdge:extent:)。
// 第一个补一个返回「未指定」的方法。后两个在导入表里是空的，一调就崩：
// 一个填上返回空数组的函数（没有竖排栏，也就没有要监听的特征），
// 一个填上转给 safeArea 的跳板（没有竖排栏时这个区域的上边界就是安全区，结果一样）。

static NSInteger verticalBarEdgeUnspecified(id self, SEL _cmd) {
    return 0;
}

// 跳板的目标和参数。参数是 AdaptivityAxis?，这个枚举跨模块按地址传，nil 是字节 2
__attribute__((used, visibility("hidden"))) void *gSafeAreaRegion;
__attribute__((used, visibility("hidden"))) uint64_t gNoAxis = 2;

__attribute__((naked)) static void layoutRegionBar(void) {
    __asm__ volatile("adrp x16, _gSafeAreaRegion@PAGE\n"
                     "ldr x16, [x16, _gSafeAreaRegion@PAGEOFF]\n"
                     "adrp x0, _gNoAxis@PAGE\n"
                     "add x0, x0, _gNoAxis@PAGEOFF\n"
                     "br x16\n");
}

// 在主程序的导入表里按符号名找到对应的指针槽：间接符号表 → 符号表 → 名字
static void **importSlot(const char *symbol) {
    const struct mach_header_64 *header = NULL;
    intptr_t slide = 0;
    for (uint32_t i = 0; i < _dyld_image_count() && !header; i++) {
        const struct mach_header_64 *image = (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (image->magic != MH_MAGIC_64 || image->filetype != MH_EXECUTE) continue;
        header = image;
        slide = _dyld_get_image_vmaddr_slide(i);
    }
    if (!header) return NULL;

    const struct symtab_command *symtab = NULL;
    const struct dysymtab_command *dysymtab = NULL;
    const struct segment_command_64 *linkedit = NULL;
    const struct load_command *command = (const struct load_command *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++, command = (const struct load_command *)((const char *)command + command->cmdsize)) {
        if (command->cmd == LC_SYMTAB) symtab = (const struct symtab_command *)command;
        else if (command->cmd == LC_DYSYMTAB) dysymtab = (const struct dysymtab_command *)command;
        else if (command->cmd == LC_SEGMENT_64 && !strcmp(((const struct segment_command_64 *)command)->segname, SEG_LINKEDIT)) linkedit = (const struct segment_command_64 *)command;
    }
    if (!symtab || !dysymtab || !linkedit) return NULL;
    uintptr_t base = slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *symbols = (const struct nlist_64 *)(base + symtab->symoff);
    const char *strings = (const char *)(base + symtab->stroff);
    const uint32_t *indirect = (const uint32_t *)(base + dysymtab->indirectsymoff);

    command = (const struct load_command *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++, command = (const struct load_command *)((const char *)command + command->cmdsize)) {
        if (command->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
        const struct section_64 *section = (const struct section_64 *)(segment + 1);
        for (uint32_t j = 0; j < segment->nsects; j++, section++) {
            uint32_t type = section->flags & SECTION_TYPE;
            if (type != S_NON_LAZY_SYMBOL_POINTERS && type != S_LAZY_SYMBOL_POINTERS) continue;
            void **slots = (void **)(section->addr + slide);
            for (size_t k = 0; k < section->size / sizeof(void *); k++) {
                uint32_t index = indirect[section->reserved1 + k];
                if ((index & (INDIRECT_SYMBOL_ABS | INDIRECT_SYMBOL_LOCAL)) || index >= symtab->nsyms) continue;
                if (!strcmp(strings + symbols[index].n_un.n_strx, symbol)) return &slots[k];
            }
        }
    }
    return NULL;
}

static void *noTraits(void) {
    static void *empty;
    if (!empty) empty = dlsym(RTLD_DEFAULT, "_swiftEmptyArrayStorage");
    return empty;
}

static void fillImport(const char *symbol, void *replacement) {
    void **slot = importSlot(symbol);
    if (!slot || *slot) return;  // 槽里有东西说明系统自带，不用补
    vm_address_t page = (vm_address_t)slot & ~(vm_page_size - 1);
    if (vm_protect(mach_task_self(), page, vm_page_size, false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) return;
    *slot = replacement;
    vm_protect(mach_task_self(), page, vm_page_size, false, VM_PROT_READ);
}

#pragma mark - 设置界面

// 小红书的设置组件，属性都是返回 block 的链式写法，下面几个小函数把调用包一下

static id blockOf(id target, NSString *name) {
    return ((id (*)(id, SEL))objc_msgSend)(target, NSSelectorFromString(name));
}

static id rowTitle(NSString *text) {
    id (^make)(NSString *) = blockOf(objc_getClass("StandardOptionTitle"), @"title");
    return make(text);
}

static id with(id object, NSString *name, id value) {
    id (^apply)(id) = blockOf(object, name);
    return apply(value);
}

static id withFlag(id object, NSString *name, BOOL value) {
    id (^apply)(BOOL) = blockOf(object, name);
    return apply(value);
}

static id row(NSString *kind, id title, NSString *identity) {
    id (^make)(id) = blockOf(objc_getClass("StandardOption"), kind);
    return with(make(title), @"setIdentity", identity);
}

static id gap(CGFloat height) {
    id (^make)(double) = blockOf(objc_getClass("StandardOption"), @"blank");
    return make(height);
}

static id switchRow(NSString *title, BOOL on, NSString *identity) {
    return row(@"switcher", withFlag(rowTitle(title), @"setSwitcherIsOn", on), identity);
}

static NSDictionary<NSString *, NSString *> *tabTitles(void) {
    return @{@"index": @"首页", @"shopping": @"市集", @"message": @"消息", @"me": @"我"};
}

static NSArray<NSArray *> *glassBars(void) {
    return @[@[@"首页顶栏", kXHSNativeBarHome], @[@"笔记顶栏", kXHSNativeBarNoteTop], @[@"笔记底栏", kXHSNativeBarNoteBottom],
             @[@"视频顶栏", kXHSNativeBarVideoTop], @[@"视频底栏", kXHSNativeBarVideoBottom],
             @[@"评论输入栏", kXHSNativeBarComment], @[@"个人页顶栏", kXHSNativeBarProfile]];
}

@implementation XHSNativeHelper

#pragma mark - 视图

+ (UIVisualEffectView *)plateOn:(UIView *)owner key:(const void *)key below:(UIView *)below frame:(CGRect)frame bar:(NSString *)bar {
    UIVisualEffectView *glass = objc_getAssociatedObject(owner, key);
    if (!glass) {
        glass = [[UIVisualEffectView alloc] initWithEffect:[UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular]];
        glass.cornerConfiguration = [UICornerConfiguration capsuleConfiguration];
        glass.userInteractionEnabled = NO;
        glass.contentView.layer.masksToBounds = YES;
        objc_setAssociatedObject(owner, key, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    BOOL empty = CGRectIsEmpty(frame) || !below.superview;
    if (glass.hidden != empty) glass.hidden = empty;
    if (empty) return glass;

    NSArray<UIView *> *siblings = below.superview.subviews;
    NSUInteger index = [siblings indexOfObjectIdenticalTo:below];
    if (glass.superview != below.superview || index == 0 || siblings[index - 1] != glass) [below.superview insertSubview:glass belowSubview:below];
    if (!CGRectEqualToRect(glass.frame, frame)) glass.frame = frame;

    // 不透明度：在玻璃上垫一层半透明的底色
    UIView *content = glass.contentView;
    NSInteger fill = (NSInteger)[XHSNativeConfig.shared fillForBar:bar];
    if (content.tag != fill + 1) {
        content.tag = fill + 1;
        content.backgroundColor = fill ? [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithRed:0.13 green:0.13 blue:0.15 alpha:fill / 100.0]
                                                                         : [UIColor colorWithWhite:1 alpha:fill / 100.0];
        }] : nil;
    }
    content.layer.cornerRadius = CGRectGetHeight(frame) / 2;
    return glass;
}

+ (void)clearBackground:(UIView *)view {
    if (view.backgroundColor && ![view.backgroundColor isEqual:UIColor.clearColor]) view.backgroundColor = UIColor.clearColor;
}

// 胶囊往里收了，里面那排图标也要跟着收，否则会顶出胶囊的圆头。
// 位置按容器宽度算，所以每次 layout 都是同一个结果，不会越缩越窄。
+ (void)alignRow:(UIView *)row inView:(UIView *)box inset:(CGFloat)inset drop:(CGFloat)drop {
    if (!row || !box) return;
    CGFloat width = CGRectGetWidth(box.bounds);
    if (width <= 1 || CGRectIsEmpty(row.frame)) return;
    // row 自己就是容器时（视频底栏），frame 原点是相对上一层的，不能拿来当偏移
    CGFloat originX = (row == box) ? 0 : CGRectGetMinX(row.frame);
    CGFloat middle = width / 2;
    for (UIView *view in row.subviews) {
        if (![self isVisible:view]) continue;
        CGFloat w = CGRectGetWidth(view.bounds), h = CGRectGetHeight(view.bounds);
        // 整条宽的（评论输入框）不参与：它两头都贴边，往哪边推都会把另一边顶出去
        if (w <= 1 || h <= 1 || w > width * 0.5) continue;
        // 右半边整组往左让，把位置还给输入框；左半边不动（铅笔本来就有留白）
        // 用 center 算，受 transform 影响不到，反复调用不会越让越偏
        CGFloat dx = (originX + view.center.x) < middle ? 0 : -inset;
        CGAffineTransform transform = CGAffineTransformMakeTranslation(dx, drop);
        if (!CGAffineTransformEqualToTransform(view.transform, transform)) view.transform = transform;
    }
}

// 视频页那一排是各自独立的控件，没法整体改宽度，就按左右各平移同样的量。
// 用 transform 平移不参与自动布局，不会和它的约束打架。
+ (void)nudgeRow:(UIView *)bar side:(CGFloat)side {
    CGFloat delta = side - 8, middle = CGRectGetMidX(bar.bounds);
    for (UIView *view in bar.subviews) {
        if ([view isKindOfClass:UIVisualEffectView.class] || ![self isVisible:view]) continue;
        CGFloat dx = CGRectGetMidX(view.frame) < middle ? delta : -delta;
        CGAffineTransform transform = CGAffineTransformMakeTranslation(dx, 0);
        if (!CGAffineTransformEqualToTransform(view.transform, transform)) view.transform = transform;
    }
}

+ (BOOL)isVisible:(UIView *)view {
    return view && !view.hidden && view.alpha > 0.01 && CGRectGetWidth(view.bounds) > 0 && CGRectGetHeight(view.bounds) > 0;
}

+ (UIView *)subviewOf:(UIView *)view named:(NSString *)className {
    for (UIView *subview in view.subviews)
        if ([NSStringFromClass(subview.class) isEqualToString:className]) return subview;
    return nil;
}

#pragma mark - 小红书

+ (BOOL)isAppAddress:(void *)address {
    static const void *app;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (uint32_t i = 0; i < _dyld_image_count() && !app; i++)
            if (((const struct mach_header_64 *)_dyld_get_image_header(i))->filetype == MH_EXECUTE) app = _dyld_get_image_header(i);
    });
    Dl_info info;
    return dladdr(address, &info) && info.dli_fbase == app;
}

+ (id)themeGlyph:(NSString *)name {
    Class managerClass = objc_getClass("XYThemeManager");
    if (![managerClass respondsToSelector:NSSelectorFromString(@"defaultManager")]) return nil;
    id manager = ((id (*)(id, SEL))objc_msgSend)(managerClass, NSSelectorFromString(@"defaultManager"));
    if (![manager respondsToSelector:NSSelectorFromString(@"icon")]) return nil;
    id set = ((id (*)(id, SEL))objc_msgSend)(manager, NSSelectorFromString(@"icon"));
    return [set respondsToSelector:NSSelectorFromString(name)] ? ((id (*)(id, SEL))objc_msgSend)(set, NSSelectorFromString(name)) : nil;
}

// 取成图片的写法是 .size(28).image
+ (UIImage *)themeIcon:(NSString *)name {
    id glyph = [self themeGlyph:name];
    if (![glyph respondsToSelector:NSSelectorFromString(@"size")]) return nil;
    id (^sized)(CGFloat) = ((id (*)(id, SEL))objc_msgSend)(glyph, NSSelectorFromString(@"size"));
    id result = sized ? sized(28) : nil;
    if (![result respondsToSelector:NSSelectorFromString(@"image")]) return nil;
    UIImage *image = ((id (*)(id, SEL))objc_msgSend)(result, NSSelectorFromString(@"image"));
    return [image isKindOfClass:UIImage.class] ? [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] : nil;
}

+ (UIImage *)tabIcon:(NSString *)name selected:(BOOL)selected {
    NSDictionary *theme = @{@"index": @"home", @"shopping": @"store", @"message": @"chat", @"me": @"me"};
    NSDictionary *symbols = @{@"index": @"house", @"shopping": @"bag", @"message": @"message", @"me": @"person"};
    UIImage *image = [self themeIcon:[theme[name] stringByAppendingString:selected ? @"_f" : @"_b"]];
    return image ?: [UIImage systemImageNamed:selected ? [symbols[name] stringByAppendingString:@".fill"] : symbols[name]];
}

#pragma mark - 底栏

// 当前显示着的、对应某个页面的标签
+ (UITab *)tabNamed:(NSString *)name {
    for (UITab *tab in XHSNativeConfig.shared.tabBarController.tabs)
        if ([tab.identifier isEqualToString:name]) return tab;
    return nil;
}

+ (NSArray<NSString *> *)legacyTabNames:(XYTabbarController *)controller {
    return [[controller.customtabBar valueForKey:@"tabs"] valueForKey:@"itemName"];
}

+ (void)refreshBadge:(UITabBarItem *)item {
    if ([item respondsToSelector:@selector(_updateViewBadge)]) [item _updateViewBadge];
}

+ (BOOL)isItemEnabled:(UITabBarItem *)item {
    XHSNativeConfig *config = XHSNativeConfig.shared;
    if (config.searchPage && item == config.searchPage.tabBarItem) return YES;
    for (NSUInteger i = 0; i < config.pages.count; i++) {
        if (item == config.pages[i].tabBarItem) return [self tabNamed:config.pageNames[i]].enabled;
    }
    return NO;
}

+ (BOOL)isOurTabBar:(UITabBar *)bar {
    XYTabbarController *controller = XHSNativeConfig.shared.tabBarController;
    return controller && bar == controller.tabBar;
}

+ (void)rebuildTabs {
    XHSNativeConfig *config = XHSNativeConfig.shared;
    XYTabbarController *controller = config.tabBarController;
    if (!controller || !config.pages.count) return;
    // 底栏被二级页面盖住时（比如正在设置页里改）先记一笔，等它重新露出来再换
    config.tabsDirty = controller.isTabBarHidden;
    if (config.tabsDirty) return;

    // 每次都建新的标签对象：沿用旧对象重排的话，系统会把留下来的那几个画成灰的
    NSString *selected = controller.selectedTab.identifier;
    NSMutableArray<UITab *> *tabs = [NSMutableArray array];
    NSArray *legacyNames = [self legacyTabNames:controller];
    for (NSString *name in config.tabOrder) {
        NSUInteger index = [config.pageNames indexOfObject:name];
        if (index == NSNotFound || [config isTabHidden:name]) continue;
        UIViewController *page = config.pages[index];
        UITab *tab = [[UITab alloc] initWithTitle:@"" image:[self tabIcon:name selected:NO] identifier:name viewControllerProvider:^UIViewController *(UITab *t) { return page; }];
        if ([tab respondsToSelector:@selector(setSelectedImage:)]) [(id)tab setSelectedImage:[self tabIcon:name selected:YES]];
        NSUInteger badgeIndex = [legacyNames indexOfObject:name];
        tab.badgeValue = (legacyNames && badgeIndex != NSNotFound) ? controller.badgeValueDict[@(badgeIndex)] : [self tabNamed:name].badgeValue;
        [tabs addObject:tab];
    }
    if ([config boolForKey:kXHSNativeSearchTab]) {
        // 系统的搜索标签会自己单独排在右边。它不切页面，点了直接开小红书的搜索，见 shouldSelectTab
        if (!config.searchPage) config.searchPage = [UIViewController new];
        UIViewController *page = config.searchPage;
        UISearchTab *search = [[UISearchTab alloc] initWithViewControllerProvider:^UIViewController *(UITab *t) { return page; }];
        search.automaticallyActivatesSearch = YES;
        [tabs addObject:search];
    }
    config.rebuilding = YES;
    [controller setTabs:tabs animated:NO];
    for (UITabBarItem *item in controller.tabBar.items) {
        if (!item.enabled && [self isItemEnabled:item]) item.enabled = YES;
        if (item.badgeValue) [self refreshBadge:item];
    }
    // 旧栏保留给发布和角标使用。其他插件可能在布局时重新显示它。
    if ([self tabNamed:@"index"]) controller.customtabBar.alpha = 0;
    UITab *restored = selected ? [self tabNamed:selected] : nil;
    if (restored) controller.selectedTab = restored;
    controller.tabBarMinimizeBehavior = [config boolForKey:kXHSNativeMinimize] ? UITabBarMinimizeBehaviorOnScrollDown : UITabBarMinimizeBehaviorNever;
    config.rebuilding = NO;
}

// 等同于点原来的加号
+ (void)openPublish {
    XYTabbarController *controller = XHSNativeConfig.shared.tabBarController;
    UIControl *button = [controller respondsToSelector:@selector(centerButton)] ? [controller centerButton] : nil;
    if ([button isKindOfClass:UIControl.class]) [button sendActionsForControlEvents:UIControlEventTouchUpInside];
}

// 等同于点首页顶栏原来的搜索。搜索页是从首页进的，不在首页时先切回去
+ (void)openSearch {
    XHSNativeConfig *config = XHSNativeConfig.shared;
    UITab *home = [self tabNamed:@"index"];
    if (home && config.tabBarController.selectedTab != home) config.tabBarController.selectedTab = home;
    dispatch_async(dispatch_get_main_queue(), ^{
        [config.searchButton sendActionsForControlEvents:UIControlEventTouchUpInside];
    });
}

#pragma mark - 首页顶栏

static char kBarEdgeKey, kSoftEdgeKey, kPublishKey, kSegmentGlassKey;

+ (NSHashTable *)pinnedEdgeEffects {
    static NSHashTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ table = [NSHashTable weakObjectsHashTable]; });
    return table;
}

+ (BOOL)isPinnedEdgeEffect:(UIScrollEdgeEffect *)effect {
    return [[self pinnedEdgeEffects] containsObject:effect];
}

+ (BOOL)hasSoftTopEdge:(UIScrollView *)list {
    return objc_getAssociatedObject(list, &kSoftEdgeKey) != nil;
}

+ (void)useSoftTopEdge:(UIScrollView *)list {
    if ([self hasSoftTopEdge:list]) return;
    objc_setAssociatedObject(list, &kSoftEdgeKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [[self pinnedEdgeEffects] addObject:list.topEdgeEffect];
    list.topEdgeEffect.style = UIScrollEdgeEffectStyle.softStyle;
    list.topEdgeEffect.hidden = NO;
}

// 这个列表是不是当前屏幕上、压在顶栏下面的那个竖向列表
+ (BOOL)isList:(UIScrollView *)list underBar:(UIView *)bar {
    if (list.hidden || !list.window || list.window != bar.window) return NO;
    if (list.contentSize.width > CGRectGetWidth(list.bounds) + 1 && list.pagingEnabled) return NO;
    if (list.contentSize.height <= CGRectGetHeight(list.bounds) && !list.alwaysBounceVertical) return NO;
    CGRect frame = [list convertRect:list.bounds toView:nil], barFrame = [bar convertRect:bar.bounds toView:nil];
    if (CGRectGetWidth(CGRectIntersection(frame, list.window.bounds)) < CGRectGetWidth(list.window.bounds) / 2) return NO;  // 在左右相邻的页里
    return CGRectGetMinY(frame) < CGRectGetMaxY(barFrame) - 1 && CGRectGetHeight(frame) > CGRectGetHeight(barFrame) * 2;
}

// 告诉系统顶栏压在这个列表上，边缘效果才会按顶栏的高度铺开。同一时刻只跟当前在看的那个列表
+ (void)attachHomeBar:(UIScrollView *)list {
    UIView *bar = XHSNativeConfig.shared.homeBar;
    if (!bar || ![self isList:list underBar:bar]) return;
    [self useSoftTopEdge:list];
    UIScrollEdgeElementContainerInteraction *interaction = objc_getAssociatedObject(bar, &kBarEdgeKey);
    if (!interaction) {
        interaction = [UIScrollEdgeElementContainerInteraction new];
        interaction.edge = UIRectEdgeTop;
        [bar addInteraction:interaction];
        objc_setAssociatedObject(bar, &kBarEdgeKey, interaction, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (interaction.scrollView != list) interaction.scrollView = list;
}

+ (void)findListIn:(UIView *)root underBar:(UIView *)bar best:(UIScrollView **)best {
    if ([root isKindOfClass:UIScrollView.class] && [self isList:(UIScrollView *)root underBar:bar] &&
        (!*best || CGRectGetHeight(root.bounds) > CGRectGetHeight((*best).bounds)))
        *best = (UIScrollView *)root;
    for (UIView *view in root.subviews) [self findListIn:view underBar:bar best:best];
}

// 左右切到别的页（关注 / 发现 / 同城）之后，把边缘效果接到新出现的那个列表上
+ (void)attachVisibleList {
    UIView *bar = XHSNativeConfig.shared.homeBar;
    if (!bar.window) return;
    UIScrollView *list = nil;
    [self findListIn:bar.superview underBar:bar best:&list];
    if (list) [self attachHomeBar:list];
}

// 主题图、分隔线和通栏磨砂各是一层，主题图的高度会按图片比例变化。
+ (void)stripBarBackground:(XYMHomeNaviBar *)bar {
    [self clearBackground:bar];
    UIView *theme = [bar respondsToSelector:@selector(background)] ? bar.background : nil;
    Class separator = objc_getClass("_XYSeparatorView");
    for (UIView *view in bar.subviews) {
        if (view.alpha == 0) continue;
        BOOL fullWidth = CGRectGetWidth(bar.bounds) > 0 &&
                         fabs(CGRectGetMinX(view.frame) - CGRectGetMinX(bar.bounds)) < 1 &&
                         fabs(CGRectGetWidth(view.frame) - CGRectGetWidth(bar.bounds)) < 1;
        BOOL backdrop = fullWidth && view.subviews.count <= 2 &&
            ([view isMemberOfClass:UIVisualEffectView.class] ||
             ([view isMemberOfClass:UIView.class] && (!view.userInteractionEnabled || CGRectEqualToRect(view.frame, bar.bounds))));
        if (view == theme || backdrop || (fullWidth && [view isKindOfClass:separator])) view.alpha = 0;
    }
}

+ (void)layoutHomeBar:(XYMHomeNaviBar *)bar {
    XHSNativeConfig.shared.homeBar = bar;
    [self stripBarBackground:bar];

    UIButton *publish = objc_getAssociatedObject(bar, &kPublishKey);
    UIView *menu = nil, *segment = nil, *search = nil;
    for (UIView *view in bar.subviews) {
        NSString *name = NSStringFromClass(view.class);
        if ([name isEqualToString:@"XYMenuButton"]) menu = view;
        else if ([name isEqualToString:@"XYSegmentControl"]) segment = view;
        else if (view != publish && [view isKindOfClass:UIButton.class] && (!search || CGRectGetMinX(view.frame) > CGRectGetMinX(search.frame))) search = view;
    }
    if (!menu || !search) return;
    XHSNativeConfig.shared.searchButton = (UIControl *)search;

    if (!publish) {
        UIButtonConfiguration *config = [UIButtonConfiguration glassButtonConfiguration];
        config.image = [UIImage systemImageNamed:@"plus"];
        config.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightMedium];
        config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
        config.baseForegroundColor = UIColor.labelColor;
        publish = [UIButton buttonWithConfiguration:config primaryAction:[UIAction actionWithHandler:^(UIAction *action) { [XHSNativeHelper openPublish]; }]];
        publish.accessibilityLabel = @"发布";
        objc_setAssociatedObject(bar, &kPublishKey, publish, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (publish.superview != bar) [bar addSubview:publish];
    if (!CGRectEqualToRect(publish.frame, search.frame)) publish.frame = search.frame;
    // 原搜索按钮和它背后那块玻璃都收起来（玻璃是和按钮同一位置的另一个视图）
    for (UIView *view in bar.subviews) {
        BOOL backing = [view isKindOfClass:UIVisualEffectView.class] && CGRectEqualToRect(view.frame, search.frame);
        if ((view == search || backing) && !view.hidden) view.hidden = YES;
    }

    if (!segment) return;
    // 「关注 发现 同城」垫一块玻璃，文字压在图片上才看得清；高度和两侧按钮对齐，在两个按钮之间居中
    CGFloat left = CGRectGetMaxX(menu.frame) + 8, right = CGRectGetMinX(publish.frame) - 8;
    CGFloat width = MIN(right - left, CGRectGetWidth(segment.frame) + 16);
    CGFloat x = left + (right - left - width) / 2;
    CGRect frame = segment.frame;
    frame.origin.x = x + (width - CGRectGetWidth(frame)) / 2;
    if (!CGRectEqualToRect(segment.frame, frame)) segment.frame = frame;
    CGRect plate = segment.hidden ? CGRectZero : CGRectMake(x, CGRectGetMinY(menu.frame), width, CGRectGetHeight(menu.frame));
    [self plateOn:bar key:&kSegmentGlassKey below:segment frame:plate bar:kXHSNativeBarHome];
}

#pragma mark - 滚动联动

+ (void)trackScrollView:(UIScrollView *)list {
    static char key;
    if (!list.window || objc_getAssociatedObject(list, &key)) return;
    objc_setAssociatedObject(list, &key, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [list.panGestureRecognizer addTarget:[XHSNativeScrollTracker shared] action:@selector(pan:)];
}

#pragma mark - 市集 / 消息 / 我

// 换成悬浮的系统底栏后，这几页底下会空出一条。原因有两种：
// 页面按旧底栏的高度（44 + 底部安全区）把内容区截短了（市集），或者页面不肯延伸到栏下面（消息）。

static BOOL nearlyEqual(CGFloat a, CGFloat b) {
    return fabs(a - b) < 1.5;
}

// 把一个「底边正好停在旧底栏上沿」的视图往下加长 gap
static BOOL growView(UIView *view, CGFloat gap) {
    for (NSLayoutConstraint *constraint in view.constraints) {
        if (constraint.firstItem == view && !constraint.secondItem && constraint.firstAttribute == NSLayoutAttributeHeight &&
            constraint.relation == NSLayoutRelationEqual && constraint.isActive && nearlyEqual(constraint.constant, CGRectGetHeight(view.bounds))) {
            constraint.constant += gap;
            return YES;
        }
    }
    for (NSLayoutConstraint *constraint in view.superview.constraints) {
        if (!constraint.isActive || constraint.relation != NSLayoutRelationEqual || constraint.multiplier != 1) continue;
        BOOL pinned = (constraint.firstItem == view && constraint.secondItem == view.superview) || (constraint.firstItem == view.superview && constraint.secondItem == view);
        if (!pinned || constraint.firstAttribute != NSLayoutAttributeBottom || constraint.secondAttribute != NSLayoutAttributeBottom) continue;
        if (nearlyEqual(fabs(constraint.constant), gap)) {
            constraint.constant = 0;
            return YES;
        }
    }
    if (!view.translatesAutoresizingMaskIntoConstraints) return NO;
    CGRect frame = view.frame;
    frame.size.height += gap;
    view.frame = frame;
    return YES;
}

static void extendDown(UIView *parent, UIView *root, CGFloat gap, int depth) {
    CGFloat height = CGRectGetHeight(root.bounds), width = CGRectGetWidth(root.bounds);
    for (UIView *view in [parent.subviews copy]) {
        if (view.hidden || view.alpha < 0.01) continue;
        CGRect frame = [root convertRect:view.bounds fromView:view];
        if (CGRectGetWidth(frame) < width * 0.9 || CGRectGetHeight(frame) <= gap) continue;
        if (nearlyEqual(CGRectGetMaxY(frame), height - gap) && growView(view, gap)) {
            [view.superview layoutIfNeeded];
            frame = [root convertRect:view.bounds fromView:view];
        }
        if (CGRectGetMaxY(frame) < height - gap - 1.5) continue;  // 够不到底部那一段，里面不用看
        if ([view isKindOfClass:UIScrollView.class]) {
            UIScrollView *list = (UIScrollView *)view;
            if (list.contentSize.width <= CGRectGetWidth(list.bounds) + 1) {
                // 延伸到底的竖向列表，末尾留出底栏的位置；里面是单元格，不往里找
                if (nearlyEqual(CGRectGetMaxY(frame), height) && list.adjustedContentInset.bottom < gap) {
                    UIEdgeInsets inset = list.contentInset;
                    inset.bottom += gap - list.adjustedContentInset.bottom;
                    list.contentInset = inset;
                }
                continue;
            }
        }
        if (depth < 9) extendDown(view, root, gap, depth + 1);
    }
}

+ (void)extendTabPage:(UIViewController *)page {
    UINavigationController *navigation = page.navigationController;
    if (!page.view.window || navigation.viewControllers.firstObject != page || navigation.parentViewController != XHSNativeConfig.shared.tabBarController) return;
    if (!(page.edgesForExtendedLayout & UIRectEdgeBottom)) {
        page.edgesForExtendedLayout |= UIRectEdgeBottom;
        [navigation.view setNeedsLayout];
    }
    static BOOL busy;
    if (busy) return;
    busy = YES;
    extendDown(page.view, page.view, 44 + page.view.window.safeAreaInsets.bottom, 0);
    busy = NO;
}

#pragma mark - 图文笔记页

// 正文延伸到上下两条栏的后面，栏的底色去掉，控件悬浮在玻璃胶囊上。
// 顶栏两块：返回 + 头像 + 昵称 / 关注 + 分享；底栏一块：评论框 + 点赞收藏评论。

static char kNoteLeftKey, kNoteRightKey, kNoteBottomKey, kNoteEdgeKey;

+ (void)layoutNoteTop:(UIView *)bar {
    [self clearBackground:bar];
    // 控件那一行在安全区下面
    UIView *row = nil;
    for (UIView *view in bar.subviews) {
        if ([view isKindOfClass:UIVisualEffectView.class] || view.hidden || CGRectGetHeight(view.frame) <= 30) continue;
        if (!row || CGRectGetMinY(view.frame) > CGRectGetMinY(row.frame)) row = view;
    }
    if (!row) return;
    [self clearBackground:row];

    UIView *back = nil, *author = nil;
    for (UIView *view in row.subviews) {
        if ([view isKindOfClass:UIButton.class]) back = back ?: view;
        else author = [self subviewOf:view named:@"XYNoteModule.NoteDirectionView"] ?: author;
    }
    if (!author) return;
    UIView *avatar = nil, *follow = nil, *share = nil, *name = nil;
    for (UIView *view in author.subviews) {
        if ([view isKindOfClass:objc_getClass("XYFollowBtn")]) follow = view;
        else if ([view isKindOfClass:UIButton.class]) share = view;
        else if ([view isKindOfClass:UIStackView.class]) name = name ?: view;
        else if ([NSStringFromClass(view.class) isEqualToString:@"XYUserAvatar"]) avatar = view;
    }

    CGFloat y = CGRectGetMidY(row.frame) - 24;
    // 右边：关注 + 分享
    UIView *first = [self isVisible:follow] ? follow : ([self isVisible:share] ? share : nil);
    CGRect right = CGRectZero;
    if (first) {
        CGFloat x = CGRectGetMinX([bar convertRect:first.bounds fromView:first]) - (first == follow ? 6 : 12);
        right = CGRectMake(x, y, CGRectGetWidth(bar.bounds) - 8 - x, 48);
    }
    // 左边：返回 + 头像 + 昵称，按内容收窄
    UIView *last = [self isVisible:name] ? name : ([self isVisible:avatar] ? avatar : back);
    CGFloat maxX = CGRectGetMaxX([bar convertRect:last.bounds fromView:last]) + (last == back ? 12 : 16);
    if (first) maxX = MIN(maxX, CGRectGetMinX(right) - 8);
    [self plateOn:bar key:&kNoteLeftKey below:row frame:CGRectMake(8, y, maxX - 8, 48) bar:kXHSNativeBarNoteTop];
    [self plateOn:bar key:&kNoteRightKey below:row frame:right bar:kXHSNativeBarNoteTop];
}

+ (void)layoutNoteBottom:(UIView *)bar {
    [self clearBackground:bar];
    XYNoteInteractionView *content = (id)[self subviewOf:bar named:@"XYNoteModule.InteractionView"];
    if (!content) return;
    [self clearBackground:content];
    UIView *stack = nil;
    for (UIView *view in content.subviews) {
        if ([view isKindOfClass:UIVisualEffectView.class]) continue;
        if ([view isKindOfClass:UIStackView.class]) stack = stack ?: view;
        // 顶上那条分隔线：不到 1pt 高，里面没东西
        else if (!view.subviews.count && CGRectGetHeight(view.frame) > 0 && CGRectGetHeight(view.frame) <= 1 && !view.hidden) view.hidden = YES;
    }
    if (CGRectGetHeight(stack.frame) <= 1) return;
    // 点赞动画单独绘制，图标上原本有一块与页面同色的方形遮底。
    XYLottieAnimationButton *like = [content respondsToSelector:@selector(likeButton)] ? content.likeButton : nil;
    UIView *mask = [like respondsToSelector:@selector(lottieMaskView)] ? like.lottieMaskView : nil;
    if (mask && mask.superview == like.imageView && !mask.subviews.count && mask.alpha != 0) mask.alpha = 0;
    // 评论框自带的灰色药丸底去掉，和旁边的按钮一样直接放在玻璃上
    for (UIView *group in stack.subviews)
        for (UIView *field in group.subviews)
            if ([NSStringFromClass(field.class) hasSuffix:@"Field"]) [self clearBackground:field];
    // 图标按「胶囊边缘 + 留白」摆好，并整体下移；胶囊用同一个位移，两者始终同心
    [self alignRow:stack inView:content inset:kBottomInner drop:kBottomDrop];
    CGRect frame = CGRectMake(kBottomSide,
                              CGRectGetMidY(stack.frame) + kBottomDrop - kBottomHeight / 2,
                              CGRectGetWidth(content.bounds) - kBottomSide * 2, kBottomHeight);
    [self plateOn:bar key:&kNoteBottomKey below:stack frame:frame bar:kXHSNativeBarNoteBottom];
}

+ (void)layoutNotePage:(UIViewController *)page {
    if (![XHSNativeConfig.shared boolForKey:kXHSNativeGlassNote]) return;
    UIView *root = page.view;
    UIView *top = [self subviewOf:root named:@"XYNoteModule.NavigationBar"], *bottom = [self subviewOf:root named:@"XYNoteModule.NoteDetailBottomView"];
    UICollectionView *list = nil;
    for (UIView *view in root.subviews)
        if ([view isKindOfClass:UICollectionView.class]) list = list ?: (UICollectionView *)view;
    if (!top || !bottom || !list || top.hidden || bottom.hidden) return;

    // 首图沿用导航栏下沿作为起点。滚出列表边界的部分可以透过导航栏看到。
    CGFloat start = CGRectGetMaxY(top.frame);
    CGRect viewport = CGRectMake(0, start, CGRectGetWidth(root.bounds), CGRectGetHeight(root.bounds) - start);
    if (CGRectIsEmpty(viewport)) return;
    UIEdgeInsets extra = page.additionalSafeAreaInsets;
    extra.bottom = MAX(0, CGRectGetMaxY(root.bounds) - CGRectGetMinY(bottom.frame) - root.window.safeAreaInsets.bottom);
    if (!UIEdgeInsetsEqualToEdgeInsets(page.additionalSafeAreaInsets, extra)) page.additionalSafeAreaInsets = extra;
    if (!CGRectEqualToRect(list.frame, viewport)) list.frame = viewport;
    if (list.clipsToBounds) list.clipsToBounds = NO;
    if (list.contentInsetAdjustmentBehavior != UIScrollViewContentInsetAdjustmentAlways)
        list.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAlways;

    // 顶部用系统的 soft 边缘；底部不要边缘效果，胶囊直接浮在正文上
    list.topEdgeEffect.style = UIScrollEdgeEffectStyle.softStyle;
    if (!list.bottomEdgeEffect.hidden) list.bottomEdgeEffect.hidden = YES;
    UIScrollEdgeElementContainerInteraction *interaction = objc_getAssociatedObject(top, &kNoteEdgeKey);
    if (!interaction) {
        interaction = [UIScrollEdgeElementContainerInteraction new];
        interaction.edge = UIRectEdgeTop;
        [top addInteraction:interaction];
        objc_setAssociatedObject(top, &kNoteEdgeKey, interaction, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (interaction.scrollView != list) interaction.scrollView = list;

    [self layoutNoteTop:top];
    [self layoutNoteBottom:bottom];
}

// 「头像 昵称 关注 分享」这一条是贴着安全区摆的，上面把栏高记进安全区之后它会被推到栏外，
// 用位移把它放回容器的垂直正中（位移不参与自动布局，不会和它的约束打架）
+ (void)recenterAuthorRow:(UIView *)row {
    if (![XHSNativeConfig.shared boolForKey:kXHSNativeGlassNote]) return;
    UIView *box = row.superview;
    CGFloat y = row.center.y - CGRectGetHeight(row.bounds) / 2;
    CGFloat offset = (CGRectGetHeight(box.bounds) - CGRectGetHeight(row.bounds)) / 2 - y;
    CGAffineTransform transform = fabs(offset) < 0.5 ? CGAffineTransformIdentity : CGAffineTransformMakeTranslation(0, offset);
    if (!CGAffineTransformEqualToTransform(row.transform, transform)) row.transform = transform;
    // 昵称是异步填进来的，宽度变了胶囊要跟着改
    for (UIView *view = box; view; view = view.superview) {
        if (![NSStringFromClass(view.class) isEqualToString:@"XYNoteModule.NavigationBar"]) continue;
        [self layoutNoteTop:view];
        break;
    }
}

#pragma mark - 视频页

// 顶上的按钮按左右分成两个胶囊（返回 + 小窗 / 搜索 + 分享），底部互动栏垫一个胶囊。
// 视频页永远是深色界面，玻璃固定用深色。

static char kVideoLeftKey, kVideoRightKey, kVideoBottomKey;

static void darken(UIVisualEffectView *glass) {
    if (glass.overrideUserInterfaceStyle != UIUserInterfaceStyleDark) glass.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
}

+ (void)layoutVideoHead:(UIView *)head {
    if (![XHSNativeConfig.shared boolForKey:kXHSNativeGlassVideo]) return;
    CGFloat middle = CGRectGetMidX(head.bounds);
    CGRect left = CGRectNull, right = CGRectNull;
    UIView *lowest = nil;
    for (UIView *view in head.subviews) {
        if ([view isKindOfClass:UIVisualEffectView.class]) continue;
        lowest = lowest ?: view;
        if (![view isKindOfClass:UIControl.class] || ![self isVisible:view]) continue;
        if (CGRectGetMidX(view.frame) < middle) left = CGRectUnion(left, view.frame);
        else right = CGRectUnion(right, view.frame);
    }
    if (!lowest) return;
    CGRect (^around)(CGRect) = ^CGRect(CGRect buttons) {
        return CGRectIsNull(buttons) ? CGRectZero : CGRectMake(CGRectGetMinX(buttons) - 9, CGRectGetMidY(buttons) - 22, CGRectGetWidth(buttons) + 18, 44);
    };
    darken([self plateOn:head key:&kVideoLeftKey below:lowest frame:around(left) bar:kXHSNativeBarVideoTop]);
    darken([self plateOn:head key:&kVideoRightKey below:lowest frame:around(right) bar:kXHSNativeBarVideoTop]);
}

+ (void)layoutVideoEngage:(UIView *)bar {
    if (![XHSNativeConfig.shared boolForKey:kXHSNativeGlassVideo]) return;
    CGRect row = CGRectNull;
    UIView *lowest = nil;
    for (UIView *view in bar.subviews) {
        if ([view isKindOfClass:UIVisualEffectView.class]) continue;
        lowest = lowest ?: view;
        if (![self isVisible:view]) continue;
        row = CGRectUnion(row, view.frame);
        // 评论框自带的灰色药丸底去掉
        if ([NSStringFromClass(view.class) hasSuffix:@"VFBottomWriteCmtView"])
            for (UIView *field in view.subviews) [self clearBackground:field];
    }
    if (!lowest || CGRectIsNull(row)) return;
    // 这一排控件的可见内容在各自格子的下半部分
    [self alignRow:bar inView:bar inset:kBottomInner drop:0];
    // 原来 44 高、y = maxY - 39，底边落在 maxY + 5；高度变了要跟着换算，否则胶囊会脱离图标
    CGRect frame = CGRectMake(kBottomSide, CGRectGetMaxY(row) + 5 - kBottomHeight,
                              CGRectGetWidth(bar.bounds) - kBottomSide * 2, kBottomHeight);
    darken([self plateOn:bar key:&kVideoBottomKey below:lowest frame:frame bar:kXHSNativeBarVideoBottom]);
}

#pragma mark - 设置界面

+ (NSString *)entryIdentity {
    return @"XHSNative";
}

+ (id)entryOption {
    return row(@"leftIconArrow", with(rowTitle(@"XHSNative"), @"setIconFont", [self themeGlyph:@"filters_b"]), [self entryIdentity]);
}

+ (NSArray *)settingsRows {
    XHSNativeConfig *config = XHSNativeConfig.shared;
    NSMutableArray *rows = [NSMutableArray arrayWithObject:gap(12)];
    [rows addObject:row(@"label", rowTitle(@"底部标签栏"), @"tabs.heading")];
    [rows addObject:gap(8)];
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    for (NSString *name in config.tabOrder) [order addObject:tabTitles()[name]];
    [rows addObject:row(@"arrow", with(rowTitle(@"标签顺序"), @"setTrailing", [order componentsJoinedByString:@" "]), @"order")];
    for (NSString *name in @[@"shopping", @"message", @"me"])
        [rows addObject:switchRow(tabTitles()[name], ![config isTabHidden:name], [@"tab." stringByAppendingString:name])];
    [rows addObject:switchRow(@"搜索", [config boolForKey:kXHSNativeSearchTab], [@"pref." stringByAppendingString:kXHSNativeSearchTab])];
    [rows addObject:switchRow(@"滚动时收起", [config boolForKey:kXHSNativeMinimize], [@"pref." stringByAppendingString:kXHSNativeMinimize])];
    [rows addObject:gap(24)];

    [rows addObject:row(@"label", rowTitle(@"液态玻璃"), @"glass.heading")];
    [rows addObject:gap(8)];
    for (NSArray *option in @[@[@"图文笔记", kXHSNativeGlassNote], @[@"视频", kXHSNativeGlassVideo], @[@"搜索栏", kXHSNativeGlassSearch],
                              @[@"评论输入栏", kXHSNativeGlassComments], @[@"私聊输入栏", kXHSNativeGlassChat],
                              @[@"消息顶栏", kXHSNativeGlassMessages], @[@"个人页顶栏", kXHSNativeGlassProfile]])
        [rows addObject:switchRow(option[0], [config boolForKey:option[1]], [@"pref." stringByAppendingString:option[1]])];
    [rows addObject:gap(8)];
    [rows addObject:row(@"label", rowTitle(@"下次进入页面时生效。"), @"glass.note")];
    [rows addObject:gap(24)];

    [rows addObject:row(@"label", rowTitle(@"不透明度"), @"fillHeading")];
    [rows addObject:gap(8)];
    for (NSArray *bar in glassBars()) {
        id title = with(rowTitle(bar[0]), @"setTrailing", [NSString stringWithFormat:@"%.0f%%", [config fillForBar:bar[1]]]);
        [rows addObject:row(@"arrow", title, [@"fill." stringByAppendingString:bar[1]])];
    }
    [rows addObject:gap(24)];
    [rows addObject:row(@"button", rowTitle(@"恢复默认"), @"reset")];
    return rows;
}

+ (NSArray *)orderRows {
    NSMutableArray *rows = [NSMutableArray array];
    for (NSString *name in XHSNativeConfig.shared.tabOrder)
        [rows addObject:withFlag(row(@"text", rowTitle(tabTitles()[name]), name), @"setCornerMaskUsesCellBounds", YES)];
    return rows;
}

// 选不透明度：0% 是纯玻璃，越大越不透
+ (NSArray *)percentRowsForBar:(NSString *)bar {
    NSInteger current = (NSInteger)[XHSNativeConfig.shared fillForBar:bar];
    NSMutableArray *rows = [NSMutableArray arrayWithObject:gap(12)];
    for (NSInteger percent = 0; percent <= 100; percent += 10) {
        id title = withFlag(rowTitle([NSString stringWithFormat:@"%ld%%", (long)percent]), @"setSelected", percent == current);
        [rows addObject:row(@"selector", title, [NSString stringWithFormat:@"percent.%ld", (long)percent])];
    }
    [rows addObject:gap(8)];
    [rows addObject:row(@"label", rowTitle(@"0% 是纯玻璃，数值越大越不透。"), @"note")];
    return rows;
}

+ (NSString *)titleForMode:(NSString *)mode {
    if (!mode) return @"XHSNative";
    if ([mode isEqualToString:@"order"]) return @"标签顺序";
    for (NSArray *bar in glassBars())
        if ([bar[1] isEqualToString:mode]) return [bar[0] stringByAppendingString:@"不透明度"];
    return @"XHSNative";
}

+ (UIView *)settingsFooterWithWidth:(CGFloat)width {
    UIStackView *footer = [UIStackView new];
    footer.axis = UILayoutConstraintAxisVertical;
    footer.alignment = UIStackViewAlignmentCenter;
    footer.spacing = 8;
    footer.layoutMarginsRelativeArrangement = YES;
    footer.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(14, 0, 14, 0);

    UIFont *font = [UIFont systemFontOfSize:12];
    NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    NSInteger year = [calendar component:NSCalendarUnitYear fromDate:NSDate.date];
    NSString *copyright = [NSString stringWithFormat:@"© %ld huamidev. All rights reserved.", (long)year];
    NSArray *lines = @[@"XHSNative", @"Version: " XHSNativeVersion, @"Developed by huami1314", copyright];
    CGFloat opacity[] = {0.8, 0.56, 0.56 * 0.7, 0.56 * 0.5};
    for (NSUInteger i = 0; i < lines.count; i++) {
        UILabel *label = [UILabel new];
        label.text = lines[i];
        label.font = font;
        label.textAlignment = NSTextAlignmentCenter;
        label.textColor = [UIColor.labelColor colorWithAlphaComponent:opacity[i]];
        [footer addArrangedSubview:label];
    }
    CGFloat height = [footer systemLayoutSizeFittingSize:UILayoutFittingCompressedSize].height;
    footer.frame = CGRectMake(0, 0, width, ceil(height));
    return footer;
}

+ (void)handleTap:(NSString *)identity onPage:(XHSNativeSettingsPage *)page {
    XHSNativeConfig *config = XHSNativeConfig.shared;
    if ([identity isEqualToString:@"order"] || [identity hasPrefix:@"fill."]) {
        XHSNativeSettingsPage *next = [[objc_getClass("XHSNativeSettingsPage") alloc] init];
        next.mode = [identity hasPrefix:@"fill."] ? [identity substringFromIndex:5] : identity;
        [page.navigationController pushViewController:next animated:YES];
    } else if ([identity hasPrefix:@"percent."]) {
        [config setFill:[identity substringFromIndex:8].doubleValue forBar:page.mode];
        [self applySettings];
        [page.navigationController popViewControllerAnimated:YES];
    } else if ([identity isEqualToString:@"reset"]) {
        [config reset];
        [self applySettings];
        [page reloadRows];
    }
}

+ (void)handleSwitch:(NSString *)identity on:(BOOL)on {
    XHSNativeConfig *config = XHSNativeConfig.shared;
    if ([identity hasPrefix:@"pref."]) [config setBool:on forKey:[identity substringFromIndex:5]];
    else if ([identity hasPrefix:@"tab."]) [config setTab:[identity substringFromIndex:4] hidden:!on];
    [self applySettings];
}

+ (void)applySettings {
    [self rebuildTabs];
    [XHSNativeConfig.shared.homeBar setNeedsLayout];
}

#pragma mark - iOS 27.1 以下

+ (void)patchOlderSystems {
    class_addMethod(UITraitCollection.class, NSSelectorFromString(@"verticalBarEdge"), (IMP)verticalBarEdgeUnspecified, "q@:");
    if (noTraits()) fillImport("_$sSo17UITraitCollectionC5UIKitE36systemTraitsAffectingVerticalBarEdgeSayAC0A10Definition_pXpGvgZ", (void *)noTraits);
    gSafeAreaRegion = dlsym(RTLD_DEFAULT, "$sSo6UIViewC5UIKitE12LayoutRegionV8safeArea16cornerAdaptationA2E14AdaptivityAxisOSg_tFZ");
    if (gSafeAreaRegion) fillImport("_$sSo6UIViewC5UIKitE12LayoutRegionV3bar6onEdge6extentAESo06UIRectG0V_12CoreGraphics7CGFloatVtFZ", (void *)layoutRegionBar);
}

@end
