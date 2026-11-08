// TweakSection — groups every tweak's settings pane under a single "Cydia tweaks"
// entry in the iOS 6 Settings root list; tapping it opens one page with all panes.
//
// How it works: on iOS 6 the Settings root (PrefsListController) populates lazily
// through the -specifiers getter, and PreferenceLoader appends its entries inside the
// same getter. Hooking that getter is the only point that always sees the fully
// populated list. We remove the tweak specifiers (matched by normalized PreferenceLoader
// entry labels) from the root array and push a single "Cydia tweaks" row whose detail
// is a runtime PSListController subclass returning the stashed specifiers.

#define TS_DEBUG 0

// The vendor Preferences headers use SDK-12+ availability macros the old 6.1 SDK
// does not define — stub them out before importing.
#ifndef API_AVAILABLE
#define API_AVAILABLE(...)
#endif
#ifndef API_DEPRECATED
#define API_DEPRECATED(...)
#endif
#ifndef API_UNAVAILABLE
#define API_UNAVAILABLE(...)
#endif

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

#if TS_DEBUG
  #define TS_LOG(fmt, ...) NSLog(@"[TweakSection] " fmt, ##__VA_ARGS__)
#else
  #define TS_LOG(fmt, ...) do {} while (0)
#endif
#define TS_ERR(fmt, ...) NSLog(@"[TweakSection][ERR] " fmt, ##__VA_ARGS__)

static NSString * const TSGroupName = @"Cydia tweaks";

static NSArray *tsGroupedSpecifiers = nil; // specifiers moved into the sub-page
static Class tsGroupControllerClass = Nil; // runtime PSListController subclass

// The pushed sub-page: returns the stashed tweak specifiers for any plist name. Our own
// implementation shadows the hooked superclass method, so no recursion happens.
static NSArray *TSGroupLoadSpecifiers(id self, SEL _cmd, NSString *plistName, id target) {
    return tsGroupedSpecifiers ?: [NSArray array];
}

// Normalize for matching: lowercase, only a-z0-9 ("Music HUD" == "MusicHUD").
static NSString *TSNormalize(NSString *s) {
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))
            [out appendFormat:@"%C", (unsigned short)tolower(c)];
    }
    return out;
}

// Labels of every PreferenceLoader entry currently installed (normalized).
// Entries come in three shapes: plain *.plist files, extensionless files
// (e.g. com.jamied360.ncsettings), and directories holding their plist inside
// (e.g. FastLoading/). The directory name itself is also a valid label.
static NSSet *TSEntryLabels(void) {
    NSMutableSet *labels = [NSMutableSet set];
    NSString *dir = @"/Library/PreferenceLoader/Preferences";
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *f in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
        NSString *path = [dir stringByAppendingPathComponent:f];
        BOOL isDir = NO;
        [fm fileExistsAtPath:path isDirectory:&isDir];
        if (isDir) {
            [labels addObject:TSNormalize(f)]; // directory name as a fallback label
            for (NSString *inner in [fm contentsOfDirectoryAtPath:path error:NULL]) {
                if (![inner hasSuffix:@".plist"]) continue;
                NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:inner]];
                NSString *label = d[@"entry"][@"label"];
                if ([label length]) [labels addObject:TSNormalize(label)];
            }
            continue;
        }
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
        if (!d) continue;
        NSString *label = d[@"entry"][@"label"];
        if ([label length]) [labels addObject:TSNormalize(label)];
    }
    return labels;
}

// Scale any icon to the Settings row size (30x30 pt).
static UIImage *TSScaleIcon(UIImage *icon) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(30, 30), NO, 0);
    [icon drawInRect:CGRectMake(0, 0, 30, 30)];
    UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return out;
}

// The concrete Settings root controller (binary-only class; exists at runtime).
@interface PrefsListController : PSListController
- (NSMutableArray *)specifiers;
@end

%hook PrefsListController

// The root populates lazily through the specifiers getter (PreferenceLoader hooks the
// same getter), so this — not reloadSpecifiers — is the one hook point that always sees
// the fully populated list. The rendering reads the live _specifiers array directly, so
// the merge MUTATES r in place instead of returning a fresh array.
- (NSMutableArray *)specifiers {
    NSMutableArray *r = %orig;

    static BOOL firstCallLogged = NO;
    if (!firstCallLogged) {
        firstCallLogged = YES;
        TS_LOG(@"getter first call: %lu specifiers", (unsigned long)r.count);
    }

    // Already merged? The root then contains exactly one "Cydia tweaks" row.
    for (PSSpecifier *spec in r) {
        if ([[spec name] isEqualToString:TSGroupName]) return r;
    }

    // Root marker: the main Settings list always carries the system "General" pane;
    // tweak sub-pages never do. Guards against grouping inside panes.
    BOOL isRoot = NO;
    for (PSSpecifier *spec in r) {
        if ([[spec name] isEqualToString:@"General"]) { isRoot = YES; break; }
    }
    if (!isRoot) return r;

    NSSet *labels = TSEntryLabels();
    if (![labels count]) return r;

    // Collect the tweak specifiers (matched by normalized PL entry labels).
    NSMutableArray *moved = [NSMutableArray array];
    NSInteger firstIdx = NSNotFound;
    for (NSInteger i = 0; i < (NSInteger)r.count; i++) {
        PSSpecifier *spec = r[i];
        NSString *n = [spec respondsToSelector:@selector(name)] ? [spec name] : nil;
        if (n && [labels containsObject:TSNormalize(n)]) {
            if (firstIdx == NSNotFound) firstIdx = i;
            [moved addObject:spec];
        }
    }
    if (firstIdx == NSNotFound) return r;

    tsGroupedSpecifiers = [moved copy];

    if (!tsGroupControllerClass) {
        tsGroupControllerClass = objc_allocateClassPair(objc_getClass("PSListController"),
                                                        "TweakSectionGroupController", 0);
        if (!tsGroupControllerClass) {
            TS_ERR(@"cannot allocate the group controller class");
            return r;
        }
        class_addMethod(tsGroupControllerClass,
                        @selector(loadSpecifiersFromPlistName:target:),
                        (IMP)TSGroupLoadSpecifiers, "@@:@@:");
        objc_registerClassPair(tsGroupControllerClass);
    }

    PSSpecifier *tweaks = [PSSpecifier preferenceSpecifierNamed:TSGroupName
                                                         target:nil
                                                           set:NULL
                                                           get:NULL
                                                        detail:tsGroupControllerClass
                                                          cell:PSLinkCell
                                                          edit:nil];

    // Row icon: borrow the Cydia app icon at runtime (on iOS 6 Cydia is the only
    // package manager and is always present; silently skipped if it ever is not).
    // The specifier key is PSIconImageKey(@"iconImage") — @"icon" is a bundle-relative
    // PATH key and does not accept UIImages. icon@2x.png is the classic pre-styled
    // iOS 6 icon (rounded corners + gloss baked in), only a row-size scale is needed.
    NSArray *iconPaths = [NSArray arrayWithObjects:
        @"/Applications/Cydia.app/icon@2x.png",
        @"/Applications/Cydia.app/iconClassic.png",
        @"/Applications/Cydia.app/icon.png", nil];
    UIImage *icon = nil;
    for (NSString *p in iconPaths) {
        UIImage *img = [UIImage imageWithContentsOfFile:p];
        if (img) { icon = TSScaleIcon(img); break; }
    }
    if (icon) [tweaks setProperty:icon forKey:PSIconImageKey];

    // In-place: pull the panes out of the root, drop the single group row in their place.
    [r removeObjectsInArray:moved];
    [r insertObject:tweaks atIndex:firstIdx];

    TS_LOG(@"merged %lu tweak panes into '%@' row at index %ld; root now %lu",
           (unsigned long)moved.count, TSGroupName, (long)firstIdx, (unsigned long)r.count);
    return r;
}

%end

%ctor {
    TS_LOG(@"loaded");
    %init;
}
