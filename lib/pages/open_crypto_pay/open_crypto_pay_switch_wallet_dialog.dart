import 'package:flutter/material.dart';

import '../../themes/stack_colors.dart';
import '../../utilities/text_styles.dart';
import '../../utilities/util.dart';
import '../../widgets/desktop/desktop_dialog.dart';
import '../../widgets/desktop/desktop_dialog_close_button.dart';
import '../../widgets/desktop/secondary_button.dart';
import '../../widgets/rounded_container.dart';
import '../../widgets/stack_dialog.dart';
import '../../widgets/wallet_info_row/sub_widgets/wallet_info_row_coin_icon.dart';
import 'open_crypto_pay_switch_wallet.dart';

const _title = "Pay with another wallet";
String _message(String ticker) =>
    "This payment does not accept $ticker. Choose a wallet to pay with.";

/// Lists [candidates] to pay with; pops with the chosen one, or null.
class OpenCryptoPaySwitchWalletDialog extends StatelessWidget {
  const OpenCryptoPaySwitchWalletDialog({
    super.key,
    required this.ticker,
    required this.candidates,
  });

  /// The rejected coin.
  final String ticker;
  final List<OpenCryptoPayCandidate> candidates;

  @override
  Widget build(BuildContext context) {
    final isDesktop = Util.isDesktop;
    final colors = Theme.of(context).extension<StackColors>()!;
    final rowStyle = isDesktop
        ? STextStyles.desktopTextSmall(context)
        : STextStyles.w500_14(context);
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _message(ticker),
          style: isDesktop
              ? STextStyles.desktopTextSmall(context)
              : STextStyles.smallMed12(context),
        ),
        const SizedBox(height: 16),
        for (final candidate in candidates) ...[
          RoundedContainer(
            color: colors.textFieldDefaultBG,
            onPressed: () => Navigator.of(context).pop(candidate),
            child: Row(
              children: [
                WalletInfoCoinIcon(
                  coin: candidate.currency,
                  contractAddress: candidate.contractAddress,
                  size: 28,
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(candidate.walletName, style: rowStyle)),
                Text(candidate.coin.ticker, style: rowStyle),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
        SecondaryButton(
          label: "Cancel",
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
    if (isDesktop) {
      return DesktopDialog(
        maxWidth: 500,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 32),
                    child: Text(_title, style: STextStyles.desktopH3(context)),
                  ),
                ),
                const DesktopDialogCloseButton(),
              ],
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(left: 32, right: 32, bottom: 32),
                child: body,
              ),
            ),
          ],
        ),
      );
    }
    return StackDialogBase(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_title, style: STextStyles.pageTitleH2(context)),
          const SizedBox(height: 8),
          body,
        ],
      ),
    );
  }
}
