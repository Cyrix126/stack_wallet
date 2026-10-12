import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/models.dart';
import '../../pages/send_view/sub_widgets/transaction_fee_selection_sheet.dart';
import '../../providers/global/wallets_provider.dart';
import '../../providers/ui/fee_rate_type_state_provider.dart';
import '../../providers/ui/preview_tx_button_state_provider.dart';
import '../../providers/wallet/desktop_fee_providers.dart';
import '../../providers/wallet/public_private_balance_state_provider.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/address_utils.dart';
import '../../utilities/amount/amount.dart';
import '../../utilities/amount/amount_formatter.dart';
import '../../utilities/enums/fee_rate_type_enum.dart';
import '../../utilities/text_styles.dart';
import '../../wallets/crypto_currency/crypto_currency.dart';
import '../../wallets/isar/providers/eth/current_token_wallet_provider.dart';
import '../../wallets/wallet/impl/firo_wallet.dart';
import '../../wallets/wallet/intermediate/cryptonote_wallet.dart';
import '../animated_text.dart';
import '../conditional_parent.dart';
import 'desktop_dialog.dart';
import 'desktop_dialog_close_button.dart';

class DesktopFeeDialog extends ConsumerStatefulWidget {
  const DesktopFeeDialog({
    super.key,
    required this.walletId,
    this.isToken = false,
  });

  final String walletId;
  final bool isToken;

  @override
  ConsumerState<DesktopFeeDialog> createState() => _DesktopFeeDialogState();
}

class _DesktopFeeDialogState extends ConsumerState<DesktopFeeDialog> {
  FeeObject? feeObject;

  @override
  Widget build(BuildContext context) {
    return DesktopDialog(
      maxWidth: 450,
      maxHeight: double.infinity,
      child: FutureBuilder(
        future: ref.watch(
          pWallets.select((value) => value.getWallet(widget.walletId).fees),
        ),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done &&
              snapshot.hasData) {
            feeObject = snapshot.data!;
          }

          return Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 32),
                    child: Text(
                      "Choose fee",
                      style: STextStyles.desktopH3(context),
                    ),
                  ),
                  const DesktopDialogCloseButton(),
                ],
              ),
              ...FeeRateType.values.map(
                (e) => Padding(
                  padding: const EdgeInsets.only(
                    left: 32,
                    right: 32,
                    bottom: 16,
                  ),
                  child: DesktopFeeItem(
                    feeObject: feeObject,
                    feeRateType: e,
                    walletId: widget.walletId,
                    isToken: widget.isToken,
                    isSelected: false,
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
          );
        },
      ),
    );
  }
}

class DesktopFeeItem extends ConsumerStatefulWidget {
  const DesktopFeeItem({
    super.key,
    required this.feeObject,
    required this.feeRateType,
    required this.walletId,
    required this.isToken,
    required this.isSelected,
    this.isButton = true,
  });

  final FeeObject? feeObject;
  final FeeRateType feeRateType;
  final String walletId;
  final bool isToken;
  final bool isSelected;
  final bool isButton;

  @override
  ConsumerState<DesktopFeeItem> createState() => _DesktopFeeItemState();
}

class _DesktopFeeItemState extends ConsumerState<DesktopFeeItem> {
  String? feeString;
  String? timeString;

  static const stringsToLoopThrough = [
    "Calculating",
    "Calculating.",
    "Calculating..",
    "Calculating...",
  ];

  Amount _addFiroOpReturnFee({
    required Amount fee,
    required BigInt feeRate,
    required FiroWallet wallet,
    required CryptoCurrency coin,
  }) {
    final opReturnData = ref.read(pOpReturnData);
    if (opReturnData == null ||
        opReturnData.isEmpty ||
        ref.read(publicPrivateBalanceStateProvider) != BalanceType.public) {
      return fee;
    }

    final extraOutputVSize = AddressUtils.opReturnOutputVSizeFromHex(
      opReturnData,
    );
    final extraFee = wallet.estimateTxFee(
      vSize: extraOutputVSize,
      feeRatePerKB: feeRate,
    );

    return fee +
        Amount(
          rawValue: BigInt.from(extraFee),
          fractionDigits: coin.fractionDigits,
        );
  }

  Future<Amount> feeFor({
    required Amount amount,
    required FeeRateType feeRateType,
    required BigInt feeRate,
    required CryptoCurrency coin,
  }) async {
    if (!widget.isToken &&
        coin is Firo &&
        ref.read(publicPrivateBalanceStateProvider) == BalanceType.public &&
        (ref.read(pOpReturnData)?.isNotEmpty ?? false)) {
      final wallet =
          ref.read(pWallets).getWallet(widget.walletId) as FiroWallet;
      final fee = await wallet.estimateFeeFor(amount, feeRate);
      return _addFiroOpReturnFee(
        fee: fee,
        feeRate: feeRate,
        wallet: wallet,
        coin: coin,
      );
    }

    final cache = ref.read(
      widget.isToken
          ? tokenFeeSessionCacheProvider
          : feeSheetSessionCacheProvider,
    );
    final Map<Amount, Amount> fees;
    switch (feeRateType) {
      case FeeRateType.fast:
        fees = cache.fast;
      case FeeRateType.average:
        fees = cache.average;
      case FeeRateType.slow:
        fees = cache.slow;
      case FeeRateType.custom:
        return Amount.zero;
    }

    if (fees[amount] == null) {
      if (widget.isToken) {
        try {
          final tokenWallet = ref.read(pCurrentTokenWallet)!;
          fees[amount] = await tokenWallet.estimateFeeFor(amount, feeRate);
        } catch (_) {
          debugPrint("Token fee estimation not available");
        }
      } else {
        final wallet = ref.read(pWallets).getWallet(widget.walletId);

        if (wallet is CryptonoteWallet) {
          final priority = switch (feeRateType) {
            FeeRateType.fast => wallet.getTxPriorityHigh(),
            FeeRateType.slow => wallet.getTxPriorityNormal(),
            _ => wallet.getTxPriorityMedium(),
          };
          fees[amount] = await wallet.estimateFeeFor(
            amount,
            BigInt.from(priority),
          );
        } else if (coin is Firo) {
          switch (ref.read(publicPrivateBalanceStateProvider.state).state) {
            case BalanceType.private:
              fees[amount] = await (wallet as FiroWallet).estimateFeeForSpark(
                amount,
              );
            case BalanceType.public:
              fees[amount] = await (wallet as FiroWallet).estimateFeeFor(
                amount,
                feeRate,
              );
          }
        } else {
          fees[amount] = await wallet.estimateFeeFor(amount, feeRate);
        }
      }
    }
    return fees[amount]!;
  }

  String estimatedTimeToBeIncludedInNextBlock(
    int targetBlockTime,
    int estimatedNumberOfBlocks,
  ) {
    final int time = targetBlockTime * estimatedNumberOfBlocks;

    final int hours = (time / 3600).floor();
    if (hours > 1) {
      return "~$hours hours";
    } else if (hours == 1) {
      return "~$hours hour";
    }

    // less than an hour

    final string = (time / 60).toStringAsFixed(1);

    if (string == "1.0") {
      return "~1 minute";
    } else {
      if (string.endsWith(".0")) {
        return "~${(time / 60).floor()} minutes";
      }
      return "~$string minutes";
    }
  }

  @override
  Widget build(BuildContext context) {
    debugPrint("BUILD: $runtimeType : ${widget.feeRateType}");

    return ConditionalParent(
      condition: widget.isButton,
      builder: (child) => MaterialButton(
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        onPressed: () {
          ref.read(feeRateTypeDesktopStateProvider.state).state =
              widget.feeRateType;
          Navigator.of(context)
              .pop((widget.feeRateType, feeString, timeString));
        },
        child: child,
      ),
      child: Builder(
        builder: (_) {
          if (widget.feeRateType == FeeRateType.custom) {
            return Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  widget.feeRateType.prettyName,
                  style: STextStyles.desktopTextExtraExtraSmall(context)
                      .copyWith(
                        color: Theme.of(context)
                            .extension<StackColors>()!
                            .textFieldActiveText,
                      ),
                  textAlign: TextAlign.left,
                ),
              ],
            );
          }

          final wallet = ref.watch(
            pWallets.select((value) => value.getWallet(widget.walletId)),
          );

          if (widget.feeObject == null) {
            return AnimatedText(
              stringsToLoopThrough: stringsToLoopThrough,
              style: STextStyles.desktopTextExtraExtraSmall(context).copyWith(
                color: Theme.of(context)
                    .extension<StackColors>()!
                    .textFieldActiveText,
              ),
            );
          } else {
            return FutureBuilder(
              future: feeFor(
                coin: wallet.info.coin,
                feeRateType: widget.feeRateType,
                feeRate: widget.feeRateType == FeeRateType.fast
                    ? widget.feeObject!.fast
                    : widget.feeRateType == FeeRateType.slow
                    ? widget.feeObject!.slow
                    : widget.feeObject!.medium,
                amount: ref.watch(sendAmountProvider.state).state,
              ),
              builder: (_, AsyncSnapshot<Amount> snapshot) {
                if (snapshot.connectionState == ConnectionState.done &&
                    snapshot.hasData) {
                  feeString =
                      "${widget.feeRateType.prettyName} "
                      "(~${ref.watch(pAmountFormatter(wallet.info.coin)).format(snapshot.data!, indicatePrecisionLoss: false)})";

                  timeString = wallet.info.coin is Ethereum
                      ? ""
                      : estimatedTimeToBeIncludedInNextBlock(
                          wallet.info.coin.targetBlockTimeSeconds,
                          widget.feeRateType == FeeRateType.fast
                              ? widget.feeObject!.numberOfBlocksFast
                              : widget.feeRateType == FeeRateType.slow
                              ? widget.feeObject!.numberOfBlocksSlow
                              : widget.feeObject!.numberOfBlocksAverage,
                        );

                  return Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        feeString!,
                        style: STextStyles.desktopTextExtraExtraSmall(context)
                            .copyWith(
                              color: Theme.of(context)
                                  .extension<StackColors>()!
                                  .textFieldActiveText,
                            ),
                        textAlign: TextAlign.left,
                      ),
                      if (widget.feeObject != null)
                        Text(
                          timeString!,
                          style: STextStyles.desktopTextExtraExtraSmall(context)
                              .copyWith(
                                color: Theme.of(context)
                                    .extension<StackColors>()!
                                    .textFieldActiveSearchIconRight,
                              ),
                        ),
                    ],
                  );
                } else {
                  return AnimatedText(
                    stringsToLoopThrough: stringsToLoopThrough,
                    style: STextStyles.desktopTextExtraExtraSmall(context)
                        .copyWith(
                          color: Theme.of(context)
                              .extension<StackColors>()!
                              .textFieldActiveText,
                        ),
                  );
                }
              },
            );
          }
        },
      ),
    );
  }
}
