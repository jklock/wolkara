// Wolkara: the launcher's colours, and the two or three pieces of style every
// screen in it shares.
//
// They are here rather than repeated in each screen because they drifted. The
// add-on screen and the voice screens were written at different times and ended up
// with two different golds, and the voice screens were built out of system colours
// on a page that is otherwise navy and gold - which is what "correct the colour and
// style to match" was about. A screen that wants to look like the launcher asks
// this file, so matching is the default and drifting takes deliberate effort.
//
// The values are the Add-on Manager's, because that is the screen the rest of the
// layer is expected to match.

#import <UIKit/UIKit.h>

/// The page behind everything.
UIColor *WKInk(void);
/// The accent: headings, selected controls, the Done button, primary actions.
UIColor *WKGold(void);
/// Secondary text, and anything that explains rather than says.
UIColor *WKMuted(void);
/// A raised panel on the ink, for grouping rows.
UIColor *WKPanel(void);
/// What sits on top of the accent, for filled buttons.
UIColor *WKOnGold(void);

/// A wrapping label in the launcher's body font at the given size.
UILabel *WKLabel(CGFloat size, UIFontWeight weight, UIColor *color);
/// A section heading: small, uppercase, gold.
UILabel *WKHeading(NSString *text);
/// An explanatory line: footnote, muted, wrapping.
UILabel *WKNote(NSString *text);
/// A rounded panel in the launcher's fill, with no content yet.
UIView *WKCard(void);
/// A row action, in the launcher's style and with an accessibility identifier.
UIButton *WKRowButton(NSString *identifier);

/// Closes a page whether it was presented as a sheet or pushed onto the launcher's
/// own navigation stack, so one Done button is right either way. The launcher
/// presents these pages as popups now; the push path is kept because the layer's
/// tests drive it and because a page must never become undismissable.
void WKDismissPage(UIViewController *page);
