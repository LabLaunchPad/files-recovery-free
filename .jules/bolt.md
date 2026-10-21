# Bolt's Journal - Critical Learnings

## 2025-05-18 - Memoizing Filtered Results in Flutter/Dart State Management
**Learning:** In Dart/Flutter applications with reactive models (`ChangeNotifier`), re-evaluating linear filtering (such as string matching, kind/state filtering) on every getter access (`get visibleFiles`) causes quadratic overhead during UI rebuilds or selection toggles. Caching the filtered list and invalidating only when underlying filters or data change drastically cuts rebuild times and memory allocations.
**Action:** Always memoize derived filtered lists in state objects and invalidate the cache when filter criteria or source items update.
