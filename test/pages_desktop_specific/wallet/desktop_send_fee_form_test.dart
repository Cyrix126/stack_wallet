import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/models/isar/stack_theme.dart';
import 'package:stackwallet/models/paymint/fee_object_model.dart';
import 'package:stackwallet/pages_desktop_specific/my_stack_view/wallet_view/sub_widgets/desktop_send_fee_form.dart';
import 'package:stackwallet/providers/global/wallets_provider.dart';
import 'package:stackwallet/providers/ui/preview_tx_button_state_provider.dart';
import 'package:stackwallet/providers/wallet/desktop_fee_providers.dart';
import 'package:stackwallet/providers/wallet/public_private_balance_state_provider.dart';
import 'package:stackwallet/themes/stack_colors.dart';
import 'package:stackwallet/utilities/amount/amount.dart';
import 'package:stackwallet/utilities/amount/amount_formatter.dart';
import 'package:stackwallet/utilities/amount/amount_unit.dart';
import 'package:stackwallet/wallets/crypto_currency/crypto_currency.dart';
import 'package:stackwallet/wallets/isar/models/wallet_info.dart';
import 'package:stackwallet/wallets/isar/providers/eth/current_token_wallet_provider.dart';
import 'package:stackwallet/wallets/isar/providers/wallet_info_provider.dart';
import 'package:stackwallet/wallets/wallet/impl/firo_wallet.dart';
import 'package:stackwallet/wallets/wallet/impl/sub_wallets/eth_token_wallet.dart';
import 'package:stackwallet/wallets/wallet/wallet.dart';
import 'package:stackwallet/widgets/desktop/desktop_dialog_close_button.dart';
import 'package:stackwallet/widgets/desktop/desktop_fee_dialog.dart';

import '../../sample_data/theme_json.dart';
import '../../wallets/support/xelis_test_fakes.dart';

const _walletId = "wallet id";
final _coin = Bitcoin(CryptoCurrencyNetwork.main);

/// [sats] in the smallest unit of [coin], so every coin shows the fees of
/// Bitcoin.
BigInt _sats(int sats, CryptoCurrency coin) =>
    BigInt.from(sats) * BigInt.from(10).pow(coin.fractionDigits - 8);

/// Wallet estimating a fee of the fee rate plus a thousandth of the amount.
/// It counts its fee rate fetches, the first [failingFetches] of which fail.
class _FeeWallet<T extends CryptoCurrency> implements Wallet<T> {
  _FeeWallet(this.coin, {this.failingFetches = 0});

  final T coin;
  final int failingFetches;
  var feeFetches = 0;

  @override
  late final info = WalletInfo.createNew(
    coin: coin,
    name: "${coin.prettyName} wallet",
    walletIdOverride: _walletId,
  );

  @override
  Future<FeeObject> get fees async {
    feeFetches++;
    if (feeFetches <= failingFetches) throw Exception("node unreachable");
    return FeeObject(
      numberOfBlocksFast: 1,
      numberOfBlocksAverage: 5,
      numberOfBlocksSlow: 20,
      fast: _sats(20000, coin),
      medium: _sats(10000, coin),
      slow: _sats(5000, coin),
    );
  }

  @override
  Future<Amount> estimateFeeFor(Amount amount, BigInt feeRate) async => Amount(
    rawValue: feeRate + amount.raw ~/ BigInt.from(1000),
    fractionDigits: coin.fractionDigits,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Firo wallet charging 1000 sats for an OP_RETURN output.
class _FiroFeeWallet extends _FeeWallet<Firo> implements FiroWallet<Firo> {
  _FiroFeeWallet() : super(Firo(CryptoCurrencyNetwork.main));

  @override
  int estimateTxFee({required int vSize, required BigInt feeRatePerKB}) => 1000;
}

/// Token wallet estimating a fee of twice the fee rate plus a thousandth of
/// the amount.
class _TokenFeeWallet implements EthTokenWallet {
  @override
  Future<Amount> estimateFeeFor(Amount amount, BigInt feeRate) async => Amount(
    rawValue: feeRate * BigInt.two + amount.raw ~/ BigInt.from(1000),
    fractionDigits: 18,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Pump the fee form for [wallet] and return its parent's setState.
Future<StateSetter> _pumpForm(
  WidgetTester tester,
  _FeeWallet<CryptoCurrency> wallet, {
  bool isToken = false,
  List<Override> overrides = const [],
}) async {
  final theme = StackTheme.fromJson(json: lightThemeJsonMap);
  late StateSetter rebuild;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        pWallets.overrideWithValue(ConfirmationWallets(wallet)),
        pWalletCoin(_walletId).overrideWithValue(wallet.coin),
        pAmountFormatter(wallet.coin).overrideWithValue(
          AmountFormatter(
            unit: AmountUnit.normal,
            locale: "en_US",
            coin: wallet.coin,
            maxDecimals: 8,
          ),
        ),
        ...overrides,
      ],
      child: MaterialApp(
        theme: ThemeData(extensions: [StackColors.fromStackColorTheme(theme)]),
        home: Material(
          child: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return DesktopSendFeeForm(
                walletId: _walletId,
                isToken: isToken,
                onCustomFeeSliderChanged: (_) {},
                onCustomFeeOptionChanged: () {},
              );
            },
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return rebuild;
}

/// Pick the fast fee, shown as [fee] in the fee dialog.
Future<void> _pickFast(WidgetTester tester, String fee) async {
  await tester.tap(find.text("Edit", findRichText: true));
  await tester.pumpAndSettle();
  await tester.tap(find.text("Fast (~$fee)"));
  await tester.pumpAndSettle();
}

/// Set the send amount to one [coin].
Future<void> _sendOneCoin(WidgetTester tester, CryptoCurrency coin) async {
  final container = ProviderScope.containerOf(
    tester.element(find.byType(DesktopSendFeeForm)),
  );
  container.read(sendAmountProvider.notifier).state = Amount(
    rawValue: _sats(100000000, coin),
    fractionDigits: coin.fractionDigits,
  );
  await tester.pumpAndSettle();
}

void main() {
  // Lay out text with Inter from the first frame.
  setUpAll(() async {
    final font = FontLoader('Inter_500');
    font.addFont(rootBundle.load('google_fonts/Inter-Medium.ttf'));
    await font.load();
  });

  testWidgets("a rebuild keeps the fee rates and the amount", (tester) async {
    final wallet = _FeeWallet(_coin);
    final rebuild = await _pumpForm(tester, wallet);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(DesktopSendFeeForm)),
    );
    final amount = Amount(rawValue: BigInt.from(22000), fractionDigits: 8);
    container.read(sendAmountProvider.notifier).state = amount;
    await tester.pump();

    rebuild(() {});
    await tester.pump();
    await tester.pump();

    expect(wallet.feeFetches, 1);
    expect(container.read(sendAmountProvider), amount);
  });

  testWidgets("a rebuild fetches the fee rates again after a failure", (
    tester,
  ) async {
    final wallet = _FeeWallet(_coin, failingFetches: 1);
    final rebuild = await _pumpForm(tester, wallet);
    expect(find.byType(DesktopFeeItem), findsNothing);

    rebuild(() {});
    await tester.pump();
    await tester.pump();

    expect(wallet.feeFetches, 2);
    expect(find.byType(DesktopFeeItem), findsOneWidget);

    rebuild(() {});
    await tester.pump();

    expect(wallet.feeFetches, 2);
    expect(find.byType(DesktopFeeItem), findsOneWidget);
  });

  testWidgets("the amount is kept while no fee estimate is shown", (
    tester,
  ) async {
    final wallet = _FeeWallet(_coin, failingFetches: 1);
    final rebuild = await _pumpForm(tester, wallet);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(DesktopSendFeeForm)),
    );
    final amount = Amount(rawValue: BigInt.from(22000), fractionDigits: 8);
    container.read(sendAmountProvider.notifier).state = amount;
    await tester.pump();

    rebuild(() {});
    await tester.pump();
    await tester.pump();

    expect(find.byType(DesktopFeeItem), findsOneWidget);
    expect(container.read(sendAmountProvider), amount);
  });

  for (final coin in [
    _coin,
    Ethereum(CryptoCurrencyNetwork.main),
    Solana(CryptoCurrencyNetwork.main),
  ]) {
    testWidgets(
      "${coin.prettyName}: a picked fee is estimated for the current amount",
      (tester) async {
        await _pumpForm(tester, _FeeWallet(coin));
        await tester.pumpAndSettle();
        await _pickFast(tester, "0.00020000 ${coin.ticker}");
        await _sendOneCoin(tester, coin);

        expect(find.text("Fast (~0.00120000 ${coin.ticker})"), findsOneWidget);
      },
    );
  }

  testWidgets("Firo: a picked fee includes the OP_RETURN output", (
    tester,
  ) async {
    final wallet = _FiroFeeWallet();
    await _pumpForm(
      tester,
      wallet,
      overrides: [
        publicPrivateBalanceStateProvider.overrideWithValue(
          StateController(BalanceType.public),
        ),
        pOpReturnData.overrideWithValue(StateController("68656c6c6f")),
      ],
    );
    await tester.pumpAndSettle();
    await _pickFast(tester, "0.00021000 FIRO");
    await _sendOneCoin(tester, wallet.coin);

    expect(find.text("Fast (~0.00121000 FIRO)"), findsOneWidget);
  });

  testWidgets("Firo: the fee dialog includes the OP_RETURN output", (
    tester,
  ) async {
    await _pumpForm(
      tester,
      _FiroFeeWallet(),
      overrides: [
        publicPrivateBalanceStateProvider.overrideWithValue(
          StateController(BalanceType.public),
        ),
        pOpReturnData.overrideWithValue(StateController("68656c6c6f")),
      ],
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text("Edit", findRichText: true));
    await tester.pumpAndSettle();

    for (final fee in [
      "Fast (~0.00021000 FIRO)",
      "Average (~0.00011000 FIRO)",
      "Slow (~0.00006000 FIRO)",
    ]) {
      expect(
        find.descendant(
          of: find.byType(DesktopFeeDialog),
          matching: find.text(fee),
        ),
        findsOneWidget,
      );
    }
  });

  testWidgets("Ethereum token: a picked fee is estimated for the current "
      "amount", (tester) async {
    final wallet = _FeeWallet(Ethereum(CryptoCurrencyNetwork.main));
    await _pumpForm(
      tester,
      wallet,
      isToken: true,
      overrides: [pCurrentTokenWallet.overrideWithValue(_TokenFeeWallet())],
    );
    await tester.pumpAndSettle();
    await _pickFast(tester, "0.00040000 ETH");
    await _sendOneCoin(tester, wallet.coin);

    expect(find.text("Fast (~0.00140000 ETH)"), findsOneWidget);
  });

  testWidgets("closing the fee dialog keeps the picked fee", (tester) async {
    await _pumpForm(tester, _FeeWallet(_coin));
    await tester.pumpAndSettle();
    await _pickFast(tester, "0.00020000 BTC");

    await tester.tap(find.text("Edit", findRichText: true));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DesktopDialogCloseButton));
    await tester.pumpAndSettle();

    expect(find.text("Fast (~0.00020000 BTC)"), findsOneWidget);
  });

  testWidgets("closing the fee dialog retries a failed fee fetch", (
    tester,
  ) async {
    await _pumpForm(tester, _FeeWallet(_coin, failingFetches: 1));
    await tester.pumpAndSettle();
    expect(find.byType(DesktopFeeItem), findsNothing);

    await tester.tap(find.text("Edit", findRichText: true));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DesktopDialogCloseButton));
    await tester.pumpAndSettle();

    expect(find.byType(DesktopFeeItem), findsOneWidget);
  });

  testWidgets("a fee picked after the amount is estimated for it", (
    tester,
  ) async {
    final rebuild = await _pumpForm(tester, _FeeWallet(_coin));
    await tester.pumpAndSettle();
    await _sendOneCoin(tester, _coin);
    await _pickFast(tester, "0.00120000 BTC");

    expect(find.text("Fast (~0.00120000 BTC)"), findsOneWidget);

    rebuild(() {});
    await tester.pumpAndSettle();

    expect(find.text("Fast (~0.00120000 BTC)"), findsOneWidget);
  });
}
