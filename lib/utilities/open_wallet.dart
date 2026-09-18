import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';
import '../wallets/isar/providers/eth/current_token_wallet_provider.dart';
import '../wallets/isar/providers/solana/current_sol_token_wallet_provider.dart';
import '../wallets/wallet/impl/ethereum_wallet.dart';
import '../wallets/wallet/impl/solana_wallet.dart';
import '../wallets/wallet/impl/sub_wallets/eth_token_wallet.dart';
import '../wallets/wallet/impl/sub_wallets/solana_token_wallet.dart';
import '../wallets/wallet/intermediate/external_wallet.dart';
import '../wallets/wallet/wallet.dart';
import '../widgets/desktop/primary_button.dart';
import '../widgets/dialogs/basic_dialog.dart';
import 'logger.dart';
import 'show_loading.dart';
import 'show_node_tor_settings_mismatch.dart';
import 'util.dart';

/// Checks the node settings and initializes [wallet] under a loading dialog.
/// Returns false when the user cancelled or [context] is gone.
Future<bool> openWallet(
  BuildContext context,
  WidgetRef ref,
  Wallet wallet,
) async {
  final canContinue = await checkShowNodeTorSettingsMismatch(
    context: context,
    currency: wallet.cryptoCurrency,
    prefs: ref.read(prefsChangeNotifierProvider),
    nodeService: ref.read(nodeServiceChangeNotifierProvider),
    allowCancel: true,
    rootNavigator: Util.isDesktop,
  );
  if (!canContinue || !context.mounted) return false;
  await showLoading(
    whileFuture: wallet is ExternalWallet
        ? wallet.init().then((_) => wallet.open())
        : wallet.init(),
    context: context,
    message: "Opening ${wallet.info.name}",
    rootNavigator: Util.isDesktop,
  );
  return context.mounted;
}

/// Creates and initializes the token wallet of [wallet] for
/// [contractAddress] under a loading dialog. Returns null after showing the
/// failure dialog.
Future<Wallet?> loadTokenWallet(
  BuildContext context,
  Reader read,
  Wallet wallet,
  String contractAddress,
) async {
  final db = read(mainDBProvider);
  Wallet? tokenWallet;
  String name = contractAddress;
  if (wallet is SolanaWallet) {
    final contract = db.getSolContractSync(contractAddress);
    if (contract != null) {
      name = contract.name;
      tokenWallet = Wallet.loadSolTokenWallet(
        solWallet: wallet,
        contract: contract,
      );
    }
  } else if (wallet is EthereumWallet) {
    final contract = db.getEthContractSync(contractAddress);
    if (contract != null) {
      name = contract.name;
      tokenWallet = Wallet.loadTokenWallet(
        ethWallet: wallet,
        contract: contract,
      );
    }
  }
  final loaded = tokenWallet == null
      ? null
      : await showLoading<Wallet?>(
          whileFuture: _init(tokenWallet),
          context: context,
          opaqueBG: true,
          message: "Loading $name",
          rootNavigator: Util.isDesktop,
        );
  if (loaded != null) return loaded;
  if (context.mounted) {
    await showDialog<void>(
      barrierDismissible: false,
      context: context,
      builder: (context) => BasicDialog(
        title: "Failed to load token data",
        desktopHeight: double.infinity,
        desktopWidth: 450,
        rightButton: PrimaryButton(
          label: "OK",
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }
  return null;
}

Future<Wallet?> _init(Wallet tokenWallet) async {
  try {
    await tokenWallet.init();
    return tokenWallet;
  } catch (e, s) {
    Logging.instance.e(
      "Failed to load token wallet ${tokenWallet.walletId}",
      error: e,
      stackTrace: s,
    );
    return null;
  }
}

/// Makes [tokenWallet] the current token wallet and refreshes it.
void setCurrentTokenWallet(Reader read, Wallet tokenWallet) {
  if (tokenWallet is SolanaTokenWallet) {
    unawaited(read(solanaTokenServiceStateProvider)?.exit());
    read(solanaTokenServiceStateProvider.state).state = tokenWallet;
  } else if (tokenWallet is EthTokenWallet) {
    unawaited(read(tokenServiceStateProvider)?.exit());
    read(tokenServiceStateProvider.state).state = tokenWallet;
  }
  unawaited(tokenWallet.refresh());
}
