import 'package:coinselect_flutter_ffi/coinselect_flutter_ffi.dart'
    as coinselect;
import '../../../models/input.dart';
import '../../crypto_currency/crypto_currency.dart';
import '../../models/tx_data.dart';
import '../wallet.dart';
import 'package:coinlib_flutter/coinlib_flutter.dart' as coinlib;
import 'electrumx_interface.dart';

export 'coin_selection_interface.dart';

mixin CoinSelectionInterface<T extends CryptoCurrency> on Wallet<T> {}

extension on coinlib.Output {
  BigInt get weight {
    return BigInt.from(size * 4);
  }
}

/// todo: does every units correspond to the scale ?
extension CoinSelection on ElectrumXInterface {
  Future<coinselect.CoinSelectionOpt> createCoinSelectOpt({
    required TxData txData,
    required List<BaseInput> utxos,
    required coinlib.Network network,
    // for mweb hack, as if it was a custom fee, the algos could make a bad but still valid decision.
    required BigInt? overrideFeeAmount,
  }) async {
    final targetValue = txData.amount!.raw;
    // sats per Kb to sats per weight
    final targetFeerate = txData.feeRatePerWeight!;
    // feeRatee is per Kb, but we want it per weight
    var longTermFeeRate = network.feePerKb / BigInt.from(1000);
    longTermFeeRate = longTermFeeRate * 4;
    final minAbsoluteFee = overrideFeeAmount ?? network.minFee;
    final changeWeight = weightOfChangeOutput(txData: txData);
    // needs to adapt to different blockchains ?
    final baseWeight = await coinselect.calculateBaseWeightBtc(
      outputWeight: weightOfOutputs(txData: txData) + changeWeight,
    );
    // TODO: changeCost should also include the fees to send the output as input, even if example of rust-coinselect doesn't do it
    final changeCost = await coinselect.calculateFee(
      weight: changeWeight,
      rate: longTermFeeRate,
    );
    final avgInputWeight =
        weightOfInputs(utxos: utxos) / utxos.length as BigInt;
    final avgOutputWeight =
        weightOfOutputs(txData: txData) / (txData.recipients!.length as BigInt)
            as BigInt;
    final minChangeValue = cryptoCurrency.dustLimit.raw;
    return coinselect.CoinSelectionOpt(
      targetValue: targetValue,
      targetFeerate: targetFeerate,
      longTermFeerate: longTermFeeRate,
      minAbsoluteFee: minAbsoluteFee,
      baseWeight: baseWeight,
      changeWeight: changeWeight,
      changeCost: changeCost,
      avgInputWeight: avgInputWeight,
      avgOutputWeight: avgOutputWeight,
      minChangeValue: minChangeValue,
      excessStrategy: coinselect.ExcessStrategy.toChange,
    );
  }

  /// calculate the weight of outputs included in a transaction data
  BigInt weightOfOutputs({required TxData txData}) {
    final weightOutputs = <BigInt>[];
    for (final txRecipient in txData.recipients!) {
      if (txRecipient.isChange) {
        continue;
      }
      weightOutputs.add(
        coinlib.Output.fromAddress(
          BigInt.zero,
          coinlib.Address.fromString(
            txRecipient.address,
            cryptoCurrency.networkParams,
          ),
        ).weight,
      );
    }
    return weightOutputs.fold(BigInt.zero, (p, c) => p + c);
  }

  /// returns the weight of a change output
  BigInt weightOfChangeOutput({required TxData txData}) =>
      coinlib.Output.fromAddress(
        BigInt.zero,
        coinlib.Address.fromString(
          changeAddress(txType: txData.type).toString(),
          cryptoCurrency.networkParams,
        ),
      ).weight;

  /// return the total weight of inputs in a transaction data
  int weightOfInputs({required List<BaseInput> utxos}) {
    final weightInputs = <int>[];
    for (final input in utxos) {
      weightInputs.add(input.weight);
    }
    return weightInputs.fold(0, (p, c) => p + c);
  }

  Future<List<coinselect.OutputGroup>> baseInputToOutputGroup({
    required List<BaseInput> inputs,
    required bool sortedByAge,
  }) async {
    final currentChainHeight = await chainHeight;
    // necessary to know the creationSequence for FIFO
    final inputsSorted = inputs;
    inputsSorted.sort(
      (a, b) => (b.blockTime ?? currentChainHeight).compareTo(
        (a.blockTime ?? currentChainHeight),
      ),
    );
    final outputGroups = <coinselect.OutputGroup>[];

    var creationSequence = 0;
    for (final input in inputs) {
      outputGroups.add(
        coinselect.OutputGroup(
          value: input.value,
          weight: input.weight as BigInt,
          inputCount: BigInt.one,
          creationSequence: creationSequence,
        ),
      );
      creationSequence += 1;
    }
    return outputGroups;
  }
}
