import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../models/paymint/fee_object_model.dart';
import '../../../../providers/providers.dart';
import '../../../../providers/ui/fee_rate_type_state_provider.dart';
import '../../../../providers/wallet/desktop_fee_providers.dart';
import '../../../../providers/wallet/public_private_balance_state_provider.dart';
import '../../../../themes/stack_colors.dart';
import '../../../../utilities/enums/fee_rate_type_enum.dart';
import '../../../../utilities/eth_commons.dart';
import '../../../../utilities/text_styles.dart';
import '../../../../wallets/crypto_currency/crypto_currency.dart';
import '../../../../wallets/crypto_currency/interfaces/electrumx_currency_interface.dart';
import '../../../../wallets/isar/providers/wallet_info_provider.dart';
import '../../../../widgets/animated_text.dart';
import '../../../../widgets/conditional_parent.dart';
import '../../../../widgets/custom_buttons/blue_text_button.dart';
import '../../../../widgets/desktop/desktop_fee_dialog.dart';
import '../../../../widgets/eth_fee_form.dart';
import '../../../../widgets/fee_slider.dart';

class DesktopSendFeeForm extends ConsumerStatefulWidget {
  const DesktopSendFeeForm({
    super.key,
    required this.walletId,
    required this.isToken,
    required this.onCustomFeeSliderChanged,
    required this.onCustomFeeOptionChanged,
    this.onCustomEip1559FeeOptionChanged,
  });

  final String walletId;
  final bool isToken;
  final void Function(int) onCustomFeeSliderChanged;
  final VoidCallback onCustomFeeOptionChanged;
  final void Function(EthEIP1559Fee?)? onCustomEip1559FeeOptionChanged;

  @override
  ConsumerState<DesktopSendFeeForm> createState() => _DesktopSendFeeFormState();
}

class _DesktopSendFeeFormState extends ConsumerState<DesktopSendFeeForm> {
  final stringsToLoopThrough = [
    "Calculating",
    "Calculating.",
    "Calculating..",
    "Calculating...",
  ];

  late final CryptoCurrency cryptoCurrency;
  Future<FeeObject>? _fees;

  bool get isEth => cryptoCurrency is Ethereum;

  @override
  void initState() {
    super.initState();
    cryptoCurrency = ref.read(pWalletCoin(widget.walletId));

    // The fee rate type provider is global and never disposed. Reset it here
    // so a stale custom selection from another wallet/send form can't cause a
    // send using an unset custom fee rate.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(feeRateTypeDesktopStateProvider.state).state =
            FeeRateType.average;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // Keep the send amount alive for the fee estimates.
    ref.listen(sendAmountProvider, (_, __) {});
    final selectedFeeRateType = ref.watch(feeRateTypeDesktopStateProvider);
    final isCustomFee = selectedFeeRateType.isCustom;
    final locale = ref.watch(
      localeServiceChangeNotifierProvider.select((value) => value.locale),
    );
    final canEditFees =
        isEth ||
        cryptoCurrency is Solana ||
        (cryptoCurrency is ElectrumXCurrencyInterface &&
            !(((cryptoCurrency is Firo) &&
                (ref.watch(publicPrivateBalanceStateProvider.state).state ==
                    BalanceType.private))));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ConditionalParent(
          condition: canEditFees,
          builder: (child) => Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              child,
              CustomTextButton(
                text: "Edit",
                onTap: () async {
                  final wasCustomFee = isCustomFee;
                  await showDialog<void>(
                    context: context,
                    builder: (_) => DesktopFeeDialog(
                      walletId: widget.walletId,
                      isToken: widget.isToken,
                    ),
                  );
                  if (!mounted) return;

                  final selectedIsCustomFee = ref
                      .read(feeRateTypeDesktopStateProvider)
                      .isCustom;
                  if (wasCustomFee != selectedIsCustomFee) {
                    widget.onCustomFeeOptionChanged.call();
                  }

                  setState(() {});
                },
              ),
            ],
          ),
          child: Text(
            "Transaction fee"
            "${isCustomFee ? "" : " (${isEth ? "max" : "estimated"})"}",
            style: STextStyles.desktopTextExtraSmall(context).copyWith(
              color: Theme.of(context)
                  .extension<StackColors>()!
                  .textFieldActiveSearchIconRight,
            ),
            textAlign: TextAlign.left,
          ),
        ),
        const SizedBox(height: 10),
        if (!isCustomFee)
          Padding(
            padding: const EdgeInsets.all(10),
            child: cryptoCurrency is! Xelis
                ? FutureBuilder(
                    future: _fees ??= ref
                        .read(pWallets)
                        .getWallet(widget.walletId)
                        .fees,
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.done &&
                          snapshot.hasError) {
                        _fees = null;
                      }
                      if (snapshot.connectionState == ConnectionState.done &&
                          snapshot.hasData) {
                        return DesktopFeeItem(
                          feeObject: snapshot.data,
                          feeRateType: selectedFeeRateType,
                          walletId: widget.walletId,
                          isButton: false,
                          isToken: widget.isToken,
                          isSelected: true,
                        );
                      } else {
                        return Row(
                          children: [
                            AnimatedText(
                              stringsToLoopThrough: stringsToLoopThrough,
                              style:
                                  STextStyles.desktopTextExtraExtraSmall(
                                    context,
                                  ).copyWith(
                                    color: Theme.of(context)
                                        .extension<StackColors>()!
                                        .textFieldActiveText,
                                  ),
                            ),
                          ],
                        );
                      }
                    },
                  )
                : const Text('Calculated when reviewing'),
          ),
        if (isCustomFee && isEth)
          EthFeeForm(
            locale: locale,
            minGasLimit: widget.isToken
                ? kEthereumTokenMinGasLimit
                : kEthereumMinGasLimit,
            stateChanged: (value) =>
                widget.onCustomEip1559FeeOptionChanged?.call(value),
          ),
        if (isCustomFee && !isEth)
          Padding(
            padding: const EdgeInsets.only(bottom: 12, top: 16),
            child: FeeSlider(
              coin: cryptoCurrency,
              onSatVByteChanged: widget.onCustomFeeSliderChanged,
            ),
          ),
      ],
    );
  }
}
