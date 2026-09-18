import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/global/active_wallet_provider.dart';
import '../providers/global/auto_swb_service_provider.dart';
import '../providers/providers.dart';
import '../providers/ui/transaction_filter_provider.dart';
import '../wallets/wallet/wallet.dart';
import 'enums/backup_frequency_type.dart';
import 'enums/sync_type_enum.dart';

/// Leaves [wallet]: stops auto sync, backs up if configured and closes the
/// wallet according to the syncing preference.
void logoutWallet(WidgetRef ref, Wallet wallet) {
  wallet.shouldAutoSync = false;
  ref.read(transactionFilterProvider.state).state = null;
  final prefs = ref.read(prefsChangeNotifierProvider);
  if (prefs.isAutoBackupEnabled &&
      prefs.backupFrequencyType == BackupFrequencyType.afterClosingAWallet) {
    unawaited(ref.read(autoSWBServiceProvider).doBackup());
  }

  switch (prefs.syncType) {
    case SyncingType.currentWalletOnly:
      unawaited(wallet.exit());
    case SyncingType.selectedWalletsAtStartup:
      if (!prefs.walletIdsSyncOnStartup.contains(wallet.walletId)) {
        unawaited(wallet.exit());
      }
    case SyncingType.allWalletsOnStartup:
      break;
  }

  ref.read(currentWalletIdProvider.notifier).state = null;
}
