import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:opencryptopay/opencryptopay.dart';
import 'package:tuple/tuple.dart';

import '../../pages_desktop_specific/desktop_home_view.dart';
import '../../pages_desktop_specific/my_stack_view/my_stack_view.dart';
import '../../pages_desktop_specific/my_stack_view/wallet_view/desktop_sol_token_view.dart';
import '../../pages_desktop_specific/my_stack_view/wallet_view/desktop_token_view.dart';
import '../../pages_desktop_specific/my_stack_view/wallet_view/desktop_wallet_view.dart';
import '../../providers/global/active_wallet_provider.dart';
import '../../providers/providers.dart';
import '../../route_generator.dart';
import '../../utilities/logger.dart';
import '../../utilities/logout_wallet.dart';
import '../../utilities/show_loading.dart';
import '../../utilities/show_node_tor_settings_mismatch.dart';
import '../../utilities/util.dart';
import '../../wallets/crypto_currency/crypto_currency.dart';
import '../../wallets/isar/providers/eth/current_token_wallet_provider.dart';
import '../../wallets/isar/providers/solana/current_sol_token_wallet_provider.dart';
import '../../wallets/wallet/impl/bitcoin_frost_wallet.dart';
import '../../wallets/wallet/impl/ethereum_wallet.dart';
import '../../wallets/wallet/impl/solana_wallet.dart';
import '../../wallets/wallet/impl/sub_wallets/eth_token_wallet.dart';
import '../../wallets/wallet/impl/sub_wallets/solana_token_wallet.dart';
import '../../wallets/wallet/intermediate/external_wallet.dart';
import '../../wallets/wallet/wallet.dart';
import '../../widgets/desktop/primary_button.dart';
import '../../widgets/dialogs/basic_dialog.dart';
import '../home_view/home_view.dart';
import '../send_view/send_view.dart';
import '../send_view/sol_token_send_view.dart';
import '../send_view/token_send_view.dart';
import '../token_view/sol_token_view.dart';
import '../token_view/token_view.dart';
import '../wallet_view/wallet_view.dart';
import 'open_crypto_pay_send_handler.dart';

/// A wallet, or a token held by a wallet, a payment can be made from.
typedef OpenCryptoPayCandidate = ({
  String walletId,
  String? contractAddress,
  String walletName,
  CryptoCurrency currency,
  CryptoCoin coin,
});

/// A payment resolved by the picker, waiting for the send view of its wallet.
typedef _PendingPayment = ({
  String walletId,
  String? contractAddress,
  OpenCryptoPaySuccess payment,
});

final _pendingPaymentProvider = StateProvider<_PendingPayment?>((_) => null);

/// The user's wallets and held tokens that can be offered for a payment.
List<OpenCryptoPayCandidate> openCryptoPayCandidates(WidgetRef ref) {
  final db = ref.read(mainDBProvider);
  final candidates = <OpenCryptoPayCandidate>[];
  for (final wallet in ref.read(pWallets).wallets) {
    if (wallet is BitcoinFrostWallet || wallet.info.isViewOnly) continue;
    OpenCryptoPayCandidate candidate(String? address, String? symbol) => (
      walletId: wallet.walletId,
      contractAddress: address,
      walletName: wallet.info.name,
      currency: wallet.cryptoCurrency,
      coin: cryptoCoinFor(wallet.cryptoCurrency, tokenSymbol: symbol),
    );
    candidates.add(candidate(null, null));
    if (wallet is EthereumWallet) {
      for (final address in wallet.info.tokenContractAddresses) {
        final symbol = db.getEthContractSync(address)?.symbol;
        if (symbol != null) candidates.add(candidate(address, symbol));
      }
    } else if (wallet is SolanaWallet) {
      final mints = {
        ...wallet.info.solanaTokenMintAddresses,
        ...wallet.info.solanaCustomTokenMintAddresses,
      };
      for (final mint in mints) {
        final symbol = db.getSolContractSync(mint)?.symbol;
        if (symbol != null) candidates.add(candidate(mint, symbol));
      }
    }
  }
  return candidates;
}

/// Applies the payment waiting for the send view of [state], if any.
///
/// Called by a send view once its [handler] exists. [contractAddress] is the
/// token the view sends, null for the chain's coin.
void takeOpenCryptoPayPayment(
  WidgetRef ref,
  State<StatefulWidget> state,
  OpenCryptoPaySendHandler handler, {
  required String walletId,
  String? contractAddress,
}) {
  final pending = ref.read(_pendingPaymentProvider);
  if (pending == null ||
      pending.walletId != walletId ||
      pending.contractAddress?.toLowerCase() !=
          contractAddress?.toLowerCase()) {
    return;
  }
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!state.mounted) return;
    ref.read(_pendingPaymentProvider.notifier).state = null;
    unawaited(handler.handleResult(state.context, pending.payment));
  });
}

/// Leaves the current wallet and opens the send view of [candidate] inside
/// its own wallet view, where [payment] is applied.
///
/// [context] is the send view that scanned the payment.
Future<void> openCryptoPaySwitchWallet(
  BuildContext context,
  WidgetRef ref,
  OpenCryptoPayCandidate candidate,
  OpenCryptoPaySuccess payment,
) async {
  final nav = Util.isDesktop
      ? myStackViewNavKey.currentState!
      : Navigator.of(context);
  final wallet = ref.read(pWallets).getWallet(candidate.walletId);
  final canContinue = await checkShowNodeTorSettingsMismatch(
    context: context,
    currency: wallet.cryptoCurrency,
    prefs: ref.read(prefsChangeNotifierProvider),
    nodeService: ref.read(nodeServiceChangeNotifierProvider),
    allowCancel: true,
    rootNavigator: Util.isDesktop,
  );
  if (!canContinue || !context.mounted) return;

  await showLoading(
    whileFuture: wallet is ExternalWallet
        ? wallet.init().then((_) => wallet.open())
        : wallet.init(),
    context: context,
    message: "Opening ${wallet.info.name}",
    rootNavigator: Util.isDesktop,
  );
  if (!context.mounted) return;

  final contractAddress = candidate.contractAddress;
  Wallet? tokenWallet;
  if (contractAddress != null) {
    tokenWallet = await showLoading<Wallet?>(
      whileFuture: _loadTokenWallet(ref, wallet, contractAddress),
      context: context,
      opaqueBG: true,
      message: "Loading ${candidate.coin.ticker}",
      rootNavigator: Util.isDesktop,
    );
    if (!context.mounted) return;
    if (tokenWallet == null) {
      await _showTokenLoadFailed(context);
      return;
    }
  }

  final walletId = candidate.walletId;
  // The scanning view is gone once the wallet view below it has settled.
  final read = ProviderScope.containerOf(context).read;
  ref.read(_pendingPaymentProvider.notifier).state = (
    walletId: walletId,
    contractAddress: contractAddress,
    payment: payment,
  );
  _leaveCurrentWallet(ref, nav, walletId);
  await _pushSettled(
    nav,
    Util.isDesktop ? DesktopWalletView.routeName : WalletView.routeName,
    walletId,
  );
  if (tokenWallet != null) _setCurrentTokenWallet(read, tokenWallet);

  if (Util.isDesktop) {
    if (tokenWallet != null) {
      unawaited(
        nav.pushNamed(
          tokenWallet is SolanaTokenWallet
              ? DesktopSolTokenView.routeName
              : DesktopTokenView.routeName,
          arguments: walletId,
        ),
      );
    }
    return;
  }

  if (tokenWallet == null) {
    unawaited(
      nav.pushNamed(
        SendView.routeName,
        arguments: Tuple2(walletId, wallet.cryptoCurrency),
      ),
    );
  } else if (tokenWallet is SolanaTokenWallet) {
    unawaited(nav.pushNamed(SolTokenView.routeName, arguments: walletId));
    unawaited(
      nav.pushNamed(
        SolTokenSendView.routeName,
        arguments: (walletId, tokenWallet.tokenMint),
      ),
    );
  } else if (tokenWallet is EthTokenWallet) {
    unawaited(nav.pushNamed(TokenView.routeName, arguments: walletId));
    unawaited(
      nav.pushNamed(
        TokenSendView.routeName,
        arguments: Tuple3(
          walletId,
          wallet.cryptoCurrency,
          tokenWallet.tokenContract,
        ),
      ),
    );
  }
}

/// Logs out of the current wallet, unless it is [nextWalletId], and pops
/// back to the wallet list.
void _leaveCurrentWallet(
  WidgetRef ref,
  NavigatorState nav,
  String nextWalletId,
) {
  final currentId = ref.read(currentWalletIdProvider);
  if (currentId != null && currentId != nextWalletId) {
    logoutWallet(ref, ref.read(pWallets).getWallet(currentId));
  }
  nav.popUntil(
    ModalRoute.withName(
      Util.isDesktop ? MyStackView.routeName : HomeView.routeName,
    ),
  );
}

/// Pushes [routeName] and returns once its transition is over and the views
/// popped underneath are gone.
Future<void> _pushSettled(
  NavigatorState nav,
  String routeName,
  Object arguments,
) async {
  final route = RouteGenerator.generateRoute(
    RouteSettings(name: routeName, arguments: arguments),
  );
  unawaited(nav.push(route));
  final animation = (route as TransitionRoute).animation!;
  if (animation.status != AnimationStatus.completed) {
    final done = Completer<void>();
    void onStatus(AnimationStatus status) {
      if (status != AnimationStatus.completed) return;
      animation.removeStatusListener(onStatus);
      done.complete();
    }

    animation.addStatusListener(onStatus);
    await done.future;
  }
  await WidgetsBinding.instance.endOfFrame;
}

/// Makes [tokenWallet] the current token wallet and refreshes it.
void _setCurrentTokenWallet(Reader read, Wallet tokenWallet) {
  if (tokenWallet is SolanaTokenWallet) {
    unawaited(read(solanaTokenServiceStateProvider)?.exit());
    read(solanaTokenServiceStateProvider.state).state = tokenWallet;
  } else if (tokenWallet is EthTokenWallet) {
    unawaited(read(tokenServiceStateProvider)?.exit());
    read(tokenServiceStateProvider.state).state = tokenWallet;
  }
  unawaited(tokenWallet.refresh());
}

Future<void> _showTokenLoadFailed(BuildContext context) => showDialog<void>(
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

/// Loads and initializes the token wallet. Returns null on failure.
Future<Wallet?> _loadTokenWallet(
  WidgetRef ref,
  Wallet wallet,
  String contractAddress,
) async {
  final db = ref.read(mainDBProvider);
  try {
    if (wallet is SolanaWallet) {
      final contract = db.getSolContractSync(contractAddress);
      if (contract == null) return null;
      final tokenWallet = Wallet.loadSolTokenWallet(
        solWallet: wallet,
        contract: contract,
      ) as SolanaTokenWallet;
      await tokenWallet.init();
      return tokenWallet;
    }
    if (wallet is EthereumWallet) {
      final contract = db.getEthContractSync(contractAddress);
      if (contract == null) return null;
      final tokenWallet = Wallet.loadTokenWallet(
        ethWallet: wallet,
        contract: contract,
      ) as EthTokenWallet;
      await tokenWallet.init();
      return tokenWallet;
    }
    return null;
  } catch (e, s) {
    Logging.instance.e(
      "Failed to load token wallet for $contractAddress",
      error: e,
      stackTrace: s,
    );
    return null;
  }
}
