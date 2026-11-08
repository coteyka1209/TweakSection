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

// Style a source icon into the iOS 6 Settings look: rounded corners, the classic
// top-half gloss gradient and a subtle dark border. Works on any input icon, so a
// modern flat package-manager logo still blends into the skeuomorphic list.
static UIImage *TSStyleIcon(UIImage *icon) {
    CGSize size = CGSizeMake(30, 30);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();

    UIBezierPath *clip = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, size.width, size.height)
                                                    cornerRadius:6.5];
    [clip addClip];
    [icon drawInRect:CGRectMake(0, 0, size.width, size.height)];

    // gloss: white gradient over the top half, fading out downwards
    CGContextSaveGState(ctx);
    [clip addClip];
    CGFloat comps[] = {1.0, 1.0, 1.0, 0.40, 1.0, 1.0, 1.0, 0.04};
    CGGradientRef gloss = CGGradientCreateWithColorComponents(NULL, comps, NULL, 2);
    CGContextDrawLinearGradient(ctx, gloss, CGPointMake(0, 0), CGPointMake(0, size.height / 2), 0);
    CGGradientRelease(gloss);
    CGContextRestoreGState(ctx);

    // hairline border to match the pre-styled png icons of that era
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:0.0 alpha:0.30].CGColor);
    [clip setLineWidth:1.0];
    [clip stroke];

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

    // Row icon: borrow the installed package manager's own icon at runtime (no bundled
    // assets, no new dependencies). Cydia.app ships the classic pre-styled iOS 6 icon
    // (icon@2x.png / iconClassic.png — used as-is); other package managers ship flat
    // modern logos, so those get the rounded+gloss treatment. Silently skipped when
    // none exists. The specifier key is PSIconImageKey(@"iconImage") — @"icon" is a
    // bundle-relative PATH key and does not accept UIImages.
    NSArray *classicPaths = [NSArray arrayWithObjects:
        @"/Applications/Cydia.app/icon@2x.png",
        @"/Applications/Cydia.app/iconClassic.png",
        @"/Applications/Cydia.app/icon.png", nil];
    NSArray *styledPaths = [NSArray arrayWithObjects:
        @"/var/jb/Applications/Sileo.app/icon.png",
        @"/Applications/Sileo.app/icon.png",
        @"/Applications/Zebra.app/Icon-Small-40@2x.png",
        @"/Applications/Icy.app/Icon.png", nil];
    UIImage *icon = nil;
    for (NSString *p in classicPaths) {
        UIImage *img = [UIImage imageWithContentsOfFile:p];
        if (img) { icon = TSScaleIcon(img); break; }
    }
    if (!icon) {
        for (NSString *p in styledPaths) {
            UIImage *flat = [UIImage imageWithContentsOfFile:p];
            if (flat) { icon = TSStyleIcon(flat); break; }
        }
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
