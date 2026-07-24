# Plan Fix YTLite Settings and Empty Home Feed

## Goal
Fix two critical bugs in YTLite:
1. YTLite Settings menu not showing up in YouTube settings due to rigid category index matching.
2. Home feed / "All" chip feed rendering blank because `YTIElementRenderer` returns `nil` for organic videos containing `hasAdLoggingData`.

## Proposed Changes

### [Settings.x](file:///Users/bez/Workspace/repos/bez/YTLite/Settings.x)
- Update `+ (NSArray *)settingsCategoryOrder` to fallback to appending `YTLiteSection` (789) to `mutableOrder` if `@(1)` (General category ID) is missing or not found in `order`.

### [YTLite.x](file:///Users/bez/Workspace/repos/bez/YTLite/YTLite.x)
- Remove `if (self.hasCompatibilityOptions && self.compatibilityOptions.hasAdLoggingData && ytlBool(@"noAds")) return nil;` in `-[YTIElementRenderer elementData]` which accidentally drops organic videos on YouTube v19+.

## Verification Plan
- Build the tweak using `make` or the project build pipeline if available.
