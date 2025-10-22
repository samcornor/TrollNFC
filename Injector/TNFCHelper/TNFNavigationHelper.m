#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>
#import <stdlib.h>

#pragma mark - Utility helpers

static Class TNFCGetClass(NSString *name) {
    Class cls = NSClassFromString(name);
    if (cls) {
        return cls;
    }
    if ([name containsString:@"."]) {
        NSArray<NSString *> *parts = [name componentsSeparatedByString:@"."];
        if (parts.count == 2) {
            NSString *swiftMangled = [NSString stringWithFormat:@"_TtC%lu%@%lu%@",
                                      (unsigned long)parts[0].length, parts[0],
                                      (unsigned long)parts[1].length, parts[1]];
            cls = NSClassFromString(swiftMangled);
        }
    }
    return cls;
}

static BOOL TNFCSwizzleInstanceMethod(Class cls, SEL original, IMP replacement, IMP *originalOut) {
    if (!cls) {
        return NO;
    }
    Method originalMethod = class_getInstanceMethod(cls, original);
    if (!originalMethod) {
        return NO;
    }
    const char *encoding = method_getTypeEncoding(originalMethod);
    if (!class_addMethod(cls, original, replacement, encoding)) {
        if (originalOut) {
            *originalOut = method_getImplementation(originalMethod);
        }
        method_setImplementation(originalMethod, replacement);
    } else {
        Method newMethod = class_getInstanceMethod(cls, original);
        if (originalOut) {
            *originalOut = method_getImplementation(newMethod);
        }
    }
    return YES;
}

static UIViewController *TNFCViewControllerForView(UIView *view) {
    UIResponder *responder = view;
    while (responder) {
        if ([responder isKindOfClass:[UIViewController class]]) {
            return (UIViewController *)responder;
        }
        responder = responder.nextResponder;
    }
    return nil;
}

static UIScrollView *TNFCFindPrimaryScrollView(UIView *view) {
    if (!view) {
        return nil;
    }
    if ([view isKindOfClass:[UIScrollView class]]) {
        return (UIScrollView *)view;
    }
    for (UIView *subview in view.subviews) {
        UIScrollView *found = TNFCFindPrimaryScrollView(subview);
        if (found) {
            return found;
        }
    }
    return nil;
}

static NSArray<UIView *> *TNFCCollectCardViews(UIScrollView *scrollView, Class cardViewClass) {
    if (!scrollView) {
        return @[];
    }
    NSMutableArray<UIView *> *cards = [NSMutableArray array];
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:scrollView];
    while (stack.count) {
        UIView *candidate = stack.lastObject;
        [stack removeLastObject];
        if (cardViewClass && [candidate isKindOfClass:cardViewClass]) {
            [cards addObject:candidate];
            continue;
        }
        for (UIView *sub in candidate.subviews) {
            [stack addObject:sub];
        }
    }
    [cards sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        CGFloat ay = [a.superview convertPoint:a.frame.origin toView:scrollView].y;
        CGFloat by = [b.superview convertPoint:b.frame.origin toView:scrollView].y;
        if (fabs(ay - by) < 0.5) {
            return NSOrderedSame;
        }
        return ay < by ? NSOrderedAscending : NSOrderedDescending;
    }];
    return cards;
}

static NSInteger TNFCCardIndexAtPoint(UIScrollView *scrollView, Class cardViewClass, CGPoint point) {
    NSArray<UIView *> *cards = TNFCCollectCardViews(scrollView, cardViewClass);
    for (NSInteger index = 0; index < (NSInteger)cards.count; index++) {
        UIView *card = cards[index];
        CGRect frame = [card.superview convertRect:card.frame toView:scrollView];
        if (CGRectContainsPoint(frame, point)) {
            return index;
        }
    }
    return NSNotFound;
}

static UIView *TNFCCardViewAtIndex(UIScrollView *scrollView, Class cardViewClass, NSInteger index) {
    NSArray<UIView *> *cards = TNFCCollectCardViews(scrollView, cardViewClass);
    if (index < 0 || index >= (NSInteger)cards.count) {
        return nil;
    }
    return cards[index];
}

#pragma mark - Associated keys

static void *const kTNFCScrollViewKey = &kTNFCScrollViewKey;
static void *const kTNFCScrollOffsetKey = &kTNFCScrollOffsetKey;
static void *const kTNFCRestoreFlagKey = &kTNFCRestoreFlagKey;
static void *const kTNFCTouchLocationKey = &kTNFCTouchLocationKey;
static void *const kTNFCSelectedIndexKey = &kTNFCSelectedIndexKey;
static void *const kTNFCCardArrayKey = &kTNFCCardArrayKey;
static void *const kTNFCHighlightOverlayKey = &kTNFCHighlightOverlayKey;
static void *const kTNFCHasTapObserverKey = &kTNFCHasTapObserverKey;

#pragma mark - Gesture proxy

@interface TNFCTapProxy : NSObject <UIGestureRecognizerDelegate>
@end

@implementation TNFCTapProxy

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

@end

static TNFCTapProxy *TNFCTapProxyShared(void) {
    static TNFCTapProxy *proxy;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        proxy = [TNFCTapProxy new];
    });
    return proxy;
}

#pragma mark - Forward declarations

@class TNFCardPageViewController;

@interface TNFCardPageCoordinator : NSObject <UIPageViewControllerDataSource, UIPageViewControllerDelegate>
@property (nonatomic, weak) TNFCardPageViewController *container;
@property (nonatomic, weak) UIViewController *listController;
@property (nonatomic, strong) NSArray *cards;
@property (nonatomic, assign) NSInteger currentIndex;
@property (nonatomic, strong) UIPageViewController *pageViewController;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, UIViewController *> *cache;
@property (nonatomic, assign) NSInteger cacheRadius;
@property (nonatomic, assign) Class recordControllerClass;
@property (nonatomic, copy) UIViewController *(^factory)(NSInteger index, id card);
- (instancetype)initWithListController:(UIViewController *)listController
                                 cards:(NSArray *)cards
                          currentIndex:(NSInteger)index
                 recordControllerClass:(Class)cls
                               factory:(UIViewController *(^)(NSInteger, id))factory;
- (UIViewController *)controllerAtIndex:(NSInteger)index;
- (NSInteger)indexOfController:(UIViewController *)controller;
- (void)prepareNeighborsAroundIndex:(NSInteger)index;
- (BOOL)moveToIndex:(NSInteger)index
          direction:(UIPageViewControllerNavigationDirection)direction
         completion:(void (^)(BOOL finished))completion;
@end

#pragma mark - Globals

static Class gCardListControllerClass;
static Class gRecordListControllerClass;
static Class gCardViewClass;

static IMP gOrigCardListViewDidLoad;
static IMP gOrigCardListViewWillAppear;
static IMP gOrigCardListViewWillDisappear;
static IMP gOrigCardViewDidMoveToWindow;
static IMP gOrigApplicationSendEvent;
static IMP gOrigNavPush;
static IMP gOrigNavPop;

#pragma mark - Touch capture & highlight

static void TNFCStoreTouchLocation(UIViewController *controller, CGPoint location) {
    if (!controller) {
        return;
    }
    objc_setAssociatedObject(controller, kTNFCTouchLocationKey, [NSValue valueWithCGPoint:location], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static NSValue *TNFCRetrieveTouchLocation(UIViewController *controller) {
    return controller ? objc_getAssociatedObject(controller, kTNFCTouchLocationKey) : nil;
}

static void TNFCPurgeHighlights(UIScrollView *scrollView, Class cardViewClass) {
    NSArray<UIView *> *cards = TNFCCollectCardViews(scrollView, cardViewClass);
    for (UIView *card in cards) {
        UIView *overlay = objc_getAssociatedObject(card, kTNFCHighlightOverlayKey);
        if (overlay) {
            [overlay removeFromSuperview];
            objc_setAssociatedObject(card, kTNFCHighlightOverlayKey, nil, OBJC_ASSOCIATION_ASSIGN);
        }
    }
}

static void TNFCHighlightCardView(UIView *cardView) {
    if (!cardView) {
        return;
    }
    UIView *existing = objc_getAssociatedObject(cardView, kTNFCHighlightOverlayKey);
    if (existing) {
        [existing removeFromSuperview];
    }
    UIView *overlay = [[UIView alloc] initWithFrame:cardView.bounds];
    overlay.userInteractionEnabled = NO;
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.layer.cornerRadius = cardView.layer.cornerRadius ?: 12.0;
    overlay.layer.masksToBounds = YES;
    overlay.layer.borderWidth = 2.0;
    overlay.layer.borderColor = [UIColor colorWithRed:0.18 green:0.47 blue:1 alpha:0.85].CGColor;
    overlay.backgroundColor = [[UIColor colorWithRed:0.18 green:0.47 blue:1 alpha:0.15] colorWithAlphaComponent:0.12];
    [cardView addSubview:overlay];
    objc_setAssociatedObject(cardView, kTNFCHighlightOverlayKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - Scroll persistence helpers

static void TNFCEnsureScrollReference(UIViewController *controller) {
    if (!controller) {
        return;
    }
    UIScrollView *scroll = objc_getAssociatedObject(controller, kTNFCScrollViewKey);
    if (!scroll) {
        scroll = TNFCFindPrimaryScrollView(controller.view);
        if (scroll) {
            objc_setAssociatedObject(controller, kTNFCScrollViewKey, scroll, OBJC_ASSOCIATION_ASSIGN);
        }
    }
}

static void TNFCRecordScrollState(UIViewController *controller) {
    if (!controller) {
        return;
    }
    TNFCEnsureScrollReference(controller);
    UIScrollView *scroll = objc_getAssociatedObject(controller, kTNFCScrollViewKey);
    if (!scroll) {
        return;
    }
    objc_setAssociatedObject(controller, kTNFCScrollOffsetKey, [NSValue valueWithCGPoint:scroll.contentOffset], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controller, kTNFCRestoreFlagKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSValue *touchValue = TNFCRetrieveTouchLocation(controller);
    if (touchValue) {
        CGPoint listPoint = [touchValue CGPointValue];
        CGPoint scrollPoint = [controller.view convertPoint:listPoint toView:scroll];
        NSInteger index = TNFCCardIndexAtPoint(scroll, gCardViewClass, scrollPoint);
        if (index != NSNotFound) {
            objc_setAssociatedObject(controller, kTNFCSelectedIndexKey, @(index), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

static void TNFCRestoreScrollState(UIViewController *controller) {
    if (!controller) {
        return;
    }
    NSNumber *flag = objc_getAssociatedObject(controller, kTNFCRestoreFlagKey);
    if (!flag.boolValue) {
        return;
    }
    objc_setAssociatedObject(controller, kTNFCRestoreFlagKey, nil, OBJC_ASSOCIATION_ASSIGN);

    TNFCEnsureScrollReference(controller);
    UIScrollView *scroll = objc_getAssociatedObject(controller, kTNFCScrollViewKey);
    if (!scroll) {
        return;
    }
    NSValue *offsetValue = objc_getAssociatedObject(controller, kTNFCScrollOffsetKey);
    if (offsetValue) {
        [scroll setContentOffset:[offsetValue CGPointValue] animated:NO];
    }
    NSNumber *indexValue = objc_getAssociatedObject(controller, kTNFCSelectedIndexKey);
    if (indexValue) {
        UIView *card = TNFCCardViewAtIndex(scroll, gCardViewClass, indexValue.integerValue);
        if (card) {
            TNFCPurgeHighlights(scroll, gCardViewClass);
            TNFCHighlightCardView(card);
        }
    }
}

#pragma mark - Card data extraction

static NSArray *TNFCExtractCardArray(UIViewController *controller) {
    if (!controller) {
        return nil;
    }
    NSArray *cached = objc_getAssociatedObject(controller, kTNFCCardArrayKey);
    if (cached) {
        return cached;
    }

    NSArray *keys = @[ @"tags", @"tagItems", @"items", @"cards", @"dataSource", @"displayItems" ];
    for (NSString *key in keys) {
        @try {
            id value = [controller valueForKey:key];
            if ([value isKindOfClass:[NSArray class]] && [value count]) {
                objc_setAssociatedObject(controller, kTNFCCardArrayKey, value, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                return value;
            }
        } @catch (__unused NSException *error) {
        }
    }

    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList([controller class], &count);
    for (unsigned int idx = 0; idx < count; idx++) {
        Ivar ivar = ivars[idx];
        id value = object_getIvar(controller, ivar);
        if ([value isKindOfClass:[NSArray class]] && [value count]) {
            objc_setAssociatedObject(controller, kTNFCCardArrayKey, value, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            free(ivars);
            return value;
        }
    }
    free(ivars);
    return nil;
}

static id TNFCExtractTagFromDetail(UIViewController *detail) {
    if (!detail) {
        return nil;
    }
    NSArray *keys = @[ @"tag", @"card", @"model", @"tagItem" ];
    for (NSString *key in keys) {
        @try {
            id value = [detail valueForKey:key];
            if (value) {
                return value;
            }
        } @catch (__unused NSException *error) {
        }
    }
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList([detail class], &count);
    for (unsigned int idx = 0; idx < count; idx++) {
        Ivar ivar = ivars[idx];
        const char *type = ivar_getTypeEncoding(ivar);
        if (type && strstr(type, "@")) {
            id value = object_getIvar(detail, ivar);
            if (value) {
                free(ivars);
                return value;
            }
        }
    }
    free(ivars);
    return nil;
}

static BOOL TNFCAssignTagToDetail(UIViewController *detail, id tag) {
    if (!detail || !tag) {
        return NO;
    }
    NSArray *selectors = @[ @"setTag:", @"setCard:", @"setModel:", @"setTagItem:" ];
    for (NSString *selectorName in selectors) {
        SEL selector = NSSelectorFromString(selectorName);
        if ([detail respondsToSelector:selector]) {
            ((void(*)(id, SEL, id))objc_msgSend)(detail, selector, tag);
            return YES;
        }
    }
    NSArray *keys = @[ @"tag", @"card", @"model", @"tagItem" ];
    for (NSString *key in keys) {
        @try {
            [detail setValue:tag forKey:key];
            return YES;
        } @catch (__unused NSException *error) {
        }
    }
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList([detail class], &count);
    for (unsigned int idx = 0; idx < count; idx++) {
        Ivar ivar = ivars[idx];
        const char *type = ivar_getTypeEncoding(ivar);
        if (type && strstr(type, "@")) {
            object_setIvar(detail, ivar, tag);
            free(ivars);
            return YES;
        }
    }
    free(ivars);
    return NO;
}

#pragma mark - Page coordinator implementation

@implementation TNFCardPageCoordinator

- (instancetype)initWithListController:(UIViewController *)listController
                                 cards:(NSArray *)cards
                          currentIndex:(NSInteger)index
                 recordControllerClass:(Class)cls
                               factory:(UIViewController *(^)(NSInteger, id))factory {
    self = [super init];
    if (self) {
        _listController = listController;
        _cards = cards ?: @[];
        _currentIndex = index;
        _recordControllerClass = cls;
        _factory = [factory copy];
        _cache = [NSMutableDictionary dictionary];
        _cacheRadius = 1;
        _pageViewController = [[UIPageViewController alloc] initWithTransitionStyle:UIPageViewControllerTransitionStyleScroll
                                                              navigationOrientation:UIPageViewControllerNavigationOrientationHorizontal
                                                                            options:@{ UIPageViewControllerOptionInterPageSpacingKey : @(8.0) }];
        _pageViewController.dataSource = self;
        _pageViewController.delegate = self;
    }
    return self;
}

- (UIViewController *)controllerAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.cards.count) {
        return nil;
    }
    NSNumber *key = @(index);
    UIViewController *controller = self.cache[key];
    if (!controller) {
        id card = self.cards[index];
        if (self.factory) {
            controller = self.factory(index, card);
        }
        if (!controller && self.recordControllerClass) {
            controller = [[self.recordControllerClass alloc] init];
            TNFCAssignTagToDetail(controller, card);
        }
        if (controller) {
            self.cache[key] = controller;
        }
    }
    return controller;
}

- (NSInteger)indexOfController:(UIViewController *)controller {
    for (NSNumber *key in self.cache) {
        if (self.cache[key] == controller) {
            return key.integerValue;
        }
    }
    return NSNotFound;
}

- (void)prepareNeighborsAroundIndex:(NSInteger)index {
    (void)[self controllerAtIndex:index - 1];
    (void)[self controllerAtIndex:index + 1];
    NSArray<NSNumber *> *keys = self.cache.allKeys;
    for (NSNumber *key in keys) {
        if (labs(key.integerValue - index) > self.cacheRadius) {
            [self.cache removeObjectForKey:key];
        }
    }
}

- (BOOL)moveToIndex:(NSInteger)index
          direction:(UIPageViewControllerNavigationDirection)direction
         completion:(void (^)(BOOL finished))completion {
    UIViewController *target = [self controllerAtIndex:index];
    if (!target) {
        if (completion) {
            completion(NO);
        }
        return NO;
    }
    [self prepareNeighborsAroundIndex:index];
    __weak typeof(self) weakSelf = self;
    [self.pageViewController setViewControllers:@[target]
                                      direction:direction
                                       animated:YES
                                     completion:^(BOOL finished) {
        if (finished) {
            weakSelf.currentIndex = index;
            [weakSelf prepareNeighborsAroundIndex:index];
            if (weakSelf.container) {
                [weakSelf.container tnf_updateNavigationForController:target];
            }
        }
        if (completion) {
            completion(finished);
        }
    }];
    return YES;
}

- (UIViewController *)pageViewController:(UIPageViewController *)pageViewController viewControllerBeforeViewController:(UIViewController *)viewController {
    NSInteger index = [self indexOfController:viewController];
    if (index == NSNotFound) {
        return nil;
    }
    return [self controllerAtIndex:index - 1];
}

- (UIViewController *)pageViewController:(UIPageViewController *)pageViewController viewControllerAfterViewController:(UIViewController *)viewController {
    NSInteger index = [self indexOfController:viewController];
    if (index == NSNotFound) {
        return nil;
    }
    return [self controllerAtIndex:index + 1];
}

- (void)pageViewController:(UIPageViewController *)pageViewController
 didFinishAnimating:(BOOL)finished
previousViewControllers:(NSArray<UIViewController *> *)previousViewControllers
   transitionCompleted:(BOOL)completed {
    if (!completed) {
        return;
    }
    UIViewController *visible = pageViewController.viewControllers.firstObject;
    NSInteger index = [self indexOfController:visible];
    if (index != NSNotFound) {
        self.currentIndex = index;
        [self prepareNeighborsAroundIndex:index];
        if (self.container) {
            [self.container tnf_updateNavigationForController:visible];
        }
    }
}

@end

#pragma mark - Page container

@interface TNFCardPageViewController : UIViewController
@property (nonatomic, strong, readonly) TNFCardPageCoordinator *coordinator;
@property (nonatomic, strong) UIViewController *initialController;
- (void)tnf_updateNavigationForController:(UIViewController *)controller;
@end

@implementation TNFCardPageViewController

- (instancetype)initWithCoordinator:(TNFCardPageCoordinator *)coordinator
                  initialController:(UIViewController *)controller {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _coordinator = coordinator;
        _initialController = controller;
        _coordinator.container = self;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    UIViewController *initial = self.initialController ?: [self.coordinator controllerAtIndex:self.coordinator.currentIndex];
    if (!initial) {
        return;
    }
    self.coordinator.cache[@(self.coordinator.currentIndex)] = initial;

    UIPageViewController *pageVC = self.coordinator.pageViewController;
    [self addChildViewController:pageVC];
    pageVC.view.frame = self.view.bounds;
    pageVC.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:pageVC.view];
    [pageVC didMoveToParentViewController:self];
    [pageVC setViewControllers:@[initial]
                     direction:UIPageViewControllerNavigationDirectionForward
                      animated:NO
                    completion:nil];

    [self tnf_updateNavigationForController:initial];
    [self.coordinator prepareNeighborsAroundIndex:self.coordinator.currentIndex];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self becomeFirstResponder];
}

- (BOOL)canBecomeFirstResponder {
    return YES;
}

- (NSArray<UIKeyCommand *> *)keyCommands {
    UIKeyCommand *left = [UIKeyCommand keyCommandWithInput:UIKeyInputLeftArrow modifierFlags:0 action:@selector(tnf_handleKeyCommand:)];
    left.discoverabilityTitle = @"Previous Card";
    UIKeyCommand *right = [UIKeyCommand keyCommandWithInput:UIKeyInputRightArrow modifierFlags:0 action:@selector(tnf_handleKeyCommand:)];
    right.discoverabilityTitle = @"Next Card";
    return @[left, right];
}

- (void)tnf_handleKeyCommand:(UIKeyCommand *)command {
    if ([command.input isEqualToString:UIKeyInputLeftArrow]) {
        NSInteger target = self.coordinator.currentIndex - 1;
        [self.coordinator moveToIndex:target
                             direction:UIPageViewControllerNavigationDirectionReverse
                            completion:nil];
    } else if ([command.input isEqualToString:UIKeyInputRightArrow]) {
        NSInteger target = self.coordinator.currentIndex + 1;
        [self.coordinator moveToIndex:target
                             direction:UIPageViewControllerNavigationDirectionForward
                            completion:nil];
    }
}

- (void)tnf_updateNavigationForController:(UIViewController *)controller {
    self.title = controller.title;
    self.navigationItem.prompt = controller.navigationItem.prompt;
    self.navigationItem.leftBarButtonItems = controller.navigationItem.leftBarButtonItems;
    self.navigationItem.rightBarButtonItems = controller.navigationItem.rightBarButtonItems;
}

@end

#pragma mark - Swizzled implementations

static void TNFCCardListViewDidLoad(id self, SEL _cmd) {
    if (gOrigCardListViewDidLoad) {
        ((void(*)(id, SEL))gOrigCardListViewDidLoad)(self, _cmd);
    }
    TNFCEnsureScrollReference(self);
}

static void TNFCCardListViewWillAppear(id self, SEL _cmd, BOOL animated) {
    if (gOrigCardListViewWillAppear) {
        ((void(*)(id, SEL, BOOL))gOrigCardListViewWillAppear)(self, _cmd, animated);
    }
    TNFCRestoreScrollState(self);
}

static void TNFCCardListViewWillDisappear(id self, SEL _cmd, BOOL animated) {
    TNFCRecordScrollState(self);
    if (gOrigCardListViewWillDisappear) {
        ((void(*)(id, SEL, BOOL))gOrigCardListViewWillDisappear)(self, _cmd, animated);
    }
}

static void TNFCCardInternalTap(UIView *view, SEL _cmd, UITapGestureRecognizer *recognizer) {
    if (recognizer.state != UIGestureRecognizerStateEnded) {
        return;
    }
    UIViewController *controller = TNFCViewControllerForView(view);
    if ([controller isKindOfClass:gCardListControllerClass]) {
        CGPoint point = [recognizer locationInView:controller.view];
        TNFCStoreTouchLocation(controller, point);
    }
}

static void TNFCCardViewDidMoveToWindow(UIView *self, SEL _cmd) {
    if (gOrigCardViewDidMoveToWindow) {
        ((void(*)(UIView *, SEL))gOrigCardViewDidMoveToWindow)(self, _cmd);
    }
    if (!objc_getAssociatedObject(self, kTNFCHasTapObserverKey)) {
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tnf_internalCardTapped:)];
        tap.cancelsTouchesInView = NO;
        tap.delegate = TNFCTapProxyShared();
        [self addGestureRecognizer:tap];
        objc_setAssociatedObject(self, kTNFCHasTapObserverKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void TNFCApplicationSendEvent(UIApplication *self, SEL _cmd, UIEvent *event) {
    if (gOrigApplicationSendEvent) {
        ((void(*)(UIApplication *, SEL, UIEvent *))gOrigApplicationSendEvent)(self, _cmd, event);
    }
    if (event.type != UIEventTypeTouches) {
        return;
    }
    for (UITouch *touch in event.allTouches) {
        if (touch.phase != UITouchPhaseEnded && touch.phase != UITouchPhaseCancelled) {
            continue;
        }
        UIViewController *controller = TNFCViewControllerForView(touch.view);
        if ([controller isKindOfClass:gCardListControllerClass]) {
            CGPoint point = [touch locationInView:controller.view];
            TNFCStoreTouchLocation(controller, point);
        }
    }
}

static UIViewController *TNFCPopViewController(UINavigationController *self, SEL _cmd, BOOL animated) {
    UIViewController *result = nil;
    if (gOrigNavPop) {
        result = ((UIViewController *(*)(UINavigationController *, SEL, BOOL))gOrigNavPop)(self, _cmd, animated);
    }
    UIViewController *top = self.topViewController;
    if ([top isKindOfClass:gCardListControllerClass]) {
        TNFCRestoreScrollState(top);
    }
    if ([result isKindOfClass:[TNFCardPageViewController class]]) {
        UIViewController *list = ((TNFCardPageViewController *)result).coordinator.listController;
        if ([list isKindOfClass:gCardListControllerClass]) {
            TNFCRestoreScrollState(list);
        }
    }
    return result;
}

static void TNFCNavigationPush(UINavigationController *self, SEL _cmd, UIViewController *controller, BOOL animated) {
    UIViewController *top = self.topViewController;
    BOOL handled = NO;
    if ([top isKindOfClass:gCardListControllerClass] && [controller isKindOfClass:gRecordListControllerClass]) {
        TNFCRecordScrollState(top);
        NSArray *cards = TNFCExtractCardArray(top);
        id tag = TNFCExtractTagFromDetail(controller);
        NSInteger index = NSNotFound;
        if (tag && cards) {
            index = [cards indexOfObject:tag];
        }
        if (index == NSNotFound) {
            NSNumber *storedIndex = objc_getAssociatedObject(top, kTNFCSelectedIndexKey);
            if (storedIndex) {
                index = storedIndex.integerValue;
            }
        }
        if (cards && index != NSNotFound && index < (NSInteger)cards.count) {
            objc_setAssociatedObject(top, kTNFCSelectedIndexKey, @(index), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            TNFCardPageCoordinator *coordinator = [[TNFCardPageCoordinator alloc] initWithListController:top
                                                                                                   cards:cards
                                                                                            currentIndex:index
                                                                                   recordControllerClass:gRecordListControllerClass
                                                                                                 factory:^UIViewController * (NSInteger idx, id card) {
                if (idx == index) {
                    return controller;
                }
                UIViewController *detail = [[gRecordListControllerClass alloc] init];
                TNFCAssignTagToDetail(detail, card);
                return detail;
            }];
            TNFCardPageViewController *page = [[TNFCardPageViewController alloc] initWithCoordinator:coordinator initialController:controller];
            handled = YES;
            if (gOrigNavPush) {
                ((void(*)(UINavigationController *, SEL, UIViewController *, BOOL))gOrigNavPush)(self, _cmd, page, animated);
            }
        }
    }
    if (!handled && gOrigNavPush) {
        ((void(*)(UINavigationController *, SEL, UIViewController *, BOOL))gOrigNavPush)(self, _cmd, controller, animated);
    }
}

#pragma mark - Card view additions

@interface UIView (TNFCardInternal)
- (void)tnf_internalCardTapped:(UITapGestureRecognizer *)recognizer;
@end

@implementation UIView (TNFCardInternal)

- (void)tnf_internalCardTapped:(UITapGestureRecognizer *)recognizer {
    TNFCCardInternalTap(self, _cmd, recognizer);
}

@end

#pragma mark - Hook installation

static void TNFCInstallHooks(void) {
    gCardListControllerClass = TNFCGetClass(@"TrollNFC.CardListController");
    gRecordListControllerClass = TNFCGetClass(@"TrollNFC.RecordListController");
    gCardViewClass = TNFCGetClass(@"TrollNFC.CardView");

    TNFCSwizzleInstanceMethod(gCardListControllerClass, @selector(viewDidLoad), (IMP)TNFCCardListViewDidLoad, &gOrigCardListViewDidLoad);
    TNFCSwizzleInstanceMethod(gCardListControllerClass, @selector(viewWillAppear:), (IMP)TNFCCardListViewWillAppear, &gOrigCardListViewWillAppear);
    TNFCSwizzleInstanceMethod(gCardListControllerClass, @selector(viewWillDisappear:), (IMP)TNFCCardListViewWillDisappear, &gOrigCardListViewWillDisappear);

    if (gCardViewClass) {
        TNFCSwizzleInstanceMethod(gCardViewClass, @selector(didMoveToWindow), (IMP)TNFCCardViewDidMoveToWindow, &gOrigCardViewDidMoveToWindow);
    }

    TNFCSwizzleInstanceMethod([UIApplication class], @selector(sendEvent:), (IMP)TNFCApplicationSendEvent, &gOrigApplicationSendEvent);
    TNFCSwizzleInstanceMethod([UINavigationController class], @selector(pushViewController:animated:), (IMP)TNFCNavigationPush, &gOrigNavPush);
    TNFCSwizzleInstanceMethod([UINavigationController class], @selector(popViewControllerAnimated:), (IMP)TNFCPopViewController, &gOrigNavPop);
}

__attribute__((constructor))
static void TNFCNavigationHelperInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        TNFCInstallHooks();
    });
}
