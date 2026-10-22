// l10n/app_strings.dart — central user-facing strings (English).
// Derived from the benchmark product's 122-string UX inventory, rewritten
// from scratch (legal: process/flows learnable, wording must be original).
library;

import '../app_brand.dart';

class S {
  S._();

  // Shell / steps
  static const String appTitle = 'Files Recovery FREE';
  static const List<String> steps = [
    'Choose',
    'Survey',
    'Back up',
    'Scan',
    'Look',
    'Recover',
  ];
  static const List<String> stepHints = [
    'Pick the drive that lost files',
    'See what is realistically recoverable',
    'Make a safety copy first',
    'Search the whole drive, block by block',
    'Browse and pick what you need',
    'Write the files out and verify them',
  ];

  // Choose step
  static const chooseTitle = 'Where did you lose files?';
  static const chooseSubtitle =
      'Select a drive or card. The app never writes to the source.';
  static const chooseSystemLocked =
      'This is your system disk. It stays locked to keep your computer safe '
      'and healthy.';
  static const chooseNotMounted = 'not mounted';
  static const chooseRefresh = 'Rescan drives';
  static const chooseContinue = 'Continue';

  // Survey step
  static const surveyTitle = 'Quick survey';
  static const surveyDataHeld = 'Blocks holding data';
  static const surveyUnreadable = 'Unreadable blocks';
  static const surveyWipe = 'Wipe pattern detected';
  static const surveyWipeYes = 'Yes — this drive may have been wiped';
  static const surveyVerdictGood =
      'Good news: this drive looks recoverable. Most data blocks are intact '
      'enough to search.';
  static const surveyVerdictCaution =
      'Caution: some blocks are unreadable. Make the safety copy before '
      'scanning.';
  static const surveyCta = 'Continue';
  static const surveyBlock = 'block';

  // Backup step
  static const backupTitle = 'Make a safety copy first';
  static const backupExplainer =
      'If the drive is failing, every minute of scanning matters. A backup '
      'copies every bit first, so the search runs on the copy — the original '
      'is never touched.';
  static const backupDestinationLabel = 'Safety copy destination';
  static const backupPick = 'Choose folder…';
  static const backupOnSource =
      'Not on the drive you are backing up — pick a different disk.';
  static const backupDo = 'Back up now';
  static const backupSkip = 'Skip — scan the original';
  static const backupSkipWarn =
      'Skipping is faster but riskier on an unstable drive.';
  static const backupDoneLabel = 'Safety copy verified';

  // Scan step
  static const scanTitle = 'Scanning';
  static const scanFound = 'files found';
  static const scanUnreadable = 'unreadable areas';
  static const scanFromCopy = 'Scanning the safety copy';
  static const scanFromOriginal = 'Scanning the original drive';
  static const scanCancel = 'Cancel scan';
  static const scanWatermark = AppBrand.simulationWatermark;

  // Look step
  static const lookTitle = 'Found files';
  static const lookSearch = 'Search by name or folder';
  static const lookSelectAll = 'Select all shown';
  static const lookClear = 'Clear selection';
  static const lookSelected = 'selected';
  static const lookHideDuplicates = 'Hide duplicates';
  static const lookAllKinds = 'All kinds';
  static const lookAllStates = 'All conditions';
  static const lookFreeNotice =
      'Free recovery covers up to ${AppBrand.freeMaxFilesPerRecovery} files '
      'per run.';
  static const lookUpgrade = 'Unlock unlimited';
  static const lookContinue = 'Recover selection';
  static const lookEmpty = 'No files match this filter.';

  // Recover step
  static const recoverTitle = 'Recover files';
  static const recoverDestination = 'Destination';
  static const recoverPickFolder = 'Choose folder…';
  static const recoverDestDefault = 'Default (temporary folder)';
  static const recoverDestWritable = 'Writable';
  static const recoverDestNotWritable = 'Not writable';
  static const recoverDestFree = 'free';
  static const recoverDestSpaceUnknown = 'Free space unknown';
  static const recoverDestOnSource = 'On the source drive';
  static const recoverDestChecking = 'Checking folder…';
  static const recoverDestWeb =
      'Browser builds hand files to your downloads — folder picking '
      'arrives with the OPFS edition.';
  static const recoverKeepFolders = 'Keep folder structure';
  static const recoverByDate = 'Sort into folders by capture date';
  static const recoverStart = 'Start recovery';
  static const recoverCancel = 'Stop';
  static const recoverDoneTitle = 'Recovered and verified';
  static const recoverDoneSummary = 'files written out';
  static const recoverVerified = 'verified';
  static const recoverNotVerified = 'check manually';
  static const recoverAgain = 'Recover more files';
  static const recoverStartOver = 'Start over';
  static const recoverCancelled = 'Recovery stopped. Nothing was changed.';

  // License
  static const licenseTitle = 'Unlock Files Recovery Pro';
  static const licenseExplainer =
      'A one-time purchase — no subscription. Your license key unlocks '
      'unlimited recovery on every platform you sign in from.';
  static const licenseField = 'License key (e.g. FRF-ABCD-2345)';
  static const licenseActivate = 'Activate';
  static const licenseBadKey = 'That key does not look right. Check the '
      'format: FRF-XXXX-XXXX.';
  static const licenseOk = 'Pro unlocked — thank you!';
  static const priceLabel = AppBrand.proPrice;

  // Badges
  static const badgeIntact = 'Intact';
  static const badgeDamaged = 'Damaged';
  static const badgeFragmented = 'Fragmented';
  static const badgeUnreadable = 'Unreadable';
  static const badgeDuplicate = 'Duplicate';
}
