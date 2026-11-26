/// Shared streak-freeze rules.
///
/// Kept free of imports so any layer can read the numbers without pulling in
/// [StreakFreezeService] (which itself depends on gamification) and creating an
/// import cycle.
class StreakRules {
  StreakRules._();

  /// Free freezes granted at the start of each week.
  static const int weeklyFreeFreezes = 1;

  /// How many freezes can be banked at once.
  static const int maxFreezes = 3;

  /// XP price of one purchased freeze.
  static const int freezeCostXP = 100;

  /// Frozen dates kept for history (older entries are trimmed).
  static const int maxFrozenHistory = 60;
}
