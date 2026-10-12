import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/models/isar/stack_theme.dart';
import 'package:stackwallet/models/paymint/fee_object_model.dart';
import 'package:stackwallet/pages_desktop_specific/my_stack_view/wallet_view/sub_widgets/desktop_send_fee_form.dart';
import 'package:stackwallet/providers/global/wallets_provider.dart';
import 'package:stackwallet/providers/wallet/desktop_fee_providers.dart';
import 'package:stackwallet/themes/stack_colors.dart';
import 'package:stackwallet/utilities/amount/amount.dart';
import 'package:stackwallet/utilities/amount/amount_formatter.dart';
import 'package:stackwallet/utilities/amount/amount_unit.dart';
import 'package:stackwallet/wallets/crypto_currency/crypto_currency.dart';
import 'package:stackwallet/wallets/isar/models/wallet_info.dart';
import 'package:stackwallet/wallets/isar/providers/wallet_info_provider.dart';
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
}
