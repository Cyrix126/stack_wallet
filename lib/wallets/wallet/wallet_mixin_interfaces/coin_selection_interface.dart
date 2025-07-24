import 'package:coinselect_flutter_ffi/coinselect_flutter_ffi.dart'
    as coinselect;
import '../../../models/input.dart';
import '../../../utilities/logger.dart' show Logging;
import '../../crypto_currency/crypto_currency.dart';
import '../../models/tx_data.dart';
import '../wallet.dart';
import 'package:coinlib_flutter/coinlib_flutter.dart' as coinlib;
import 'electrumx_interface.dart';

export 'coin_selection_interface.dart';

mixin CoinSelectionInterface<T extends CryptoCurrency> on Wallet<T> {}

extension on coinlib.Output {
  /// returns the weight instead of the size
  /// size of an output is the same in vSize, we just multiply by 4
  BigInt get weight {
    return BigInt.from(size * 4);
  }
}

extension CoinSelection on ElectrumXInterface {
  /// The options for coinSelect needs to incorporate values that are tied to the cryptocurrency used since coinSelect is blockchain agnostic
  Future<coinselect.CoinSelectionOpt> createCoinSelectOpt({
    required TxData txData,
    required List<BaseInput> utxos,
    required coinlib.Network network,
    // for mweb hack, as if it was a custom fee, the algos could make a bad but still valid decision.
    required BigInt? overrideFeeAmount,
  }) async {
    // the amount for the recipient(s)
    final targetValue = txData.amount!.raw;

    // the amount of fee per weight
    final targetFeerate = txData.feeRatePerWeight!;

    // long term fee rate is used to calculate the waste
    // feeRatee is per Kb, but we want it per weight
    final longTermFeeRate = network.feePerKb / BigInt.from(1000) / 4;

    // the minimum fee
    final minAbsoluteFee = overrideFeeAmount ?? network.minFee;

    // the weight of a change output, which is really the same as any output
    final changeWeight = await weightOfChangeOutput(txData: txData);

    // baseWeight is the transaction weight without inputs.
    final baseWeight =
        BigInt.from(
          ((await buildTransaction(txData: txData, inputsWithKeys: [])).vSize! *
              4),
        ) +
        changeWeight;

    // changeCost is actually not yet used in rust-coinselect
    final changeCost = await coinselect.calculateFee(
      weight: changeWeight,
      rate: longTermFeeRate,
    );

    // we need to calculate weight of inputs like they are in the final tx
    final inputsWithSigningKeys = await addSigningKeys(utxos);
    final avgInputWeight = BigInt.from(
      (weightOfInputs(utxos: inputsWithSigningKeys) / utxos.length)
          .roundToDouble(),
    );

    final avgOutputWeight = BigInt.from(
      (weightOfOutputs(txData: txData)) /
          BigInt.from(txData.recipients!.length),
    );
    // limit above target under which no change will be created (amount under this dust will go to fee)
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
  Future<BigInt> weightOfChangeOutput({required TxData txData}) async {
    final changeAddr = await changeAddress(txType: txData.type);
    final addr = changeAddr.toString();

    Logging.instance.d(
      'calculating weight of change output using address: $addr',
    );
    return coinlib.Output.fromAddress(
      BigInt.zero,
      coinlib.Address.fromString(
        changeAddr.value,
        cryptoCurrency.networkParams,
      ),
    ).weight;
  }

  /// return the total weight of inputs in a transaction data
  int weightOfInputs({required List<BaseInput> utxos}) {
    final weightInputs = <int>[];
    for (final input in utxos) {
      weightInputs.add(input.weight);
    }
    final totalWeight = weightInputs.fold(0, (p, c) => p + c);
    return totalWeight;
  }

  /// Convert inputs to OutputGroup, type usable by rust-coinselect
  /// The inputs will be sorted by age, needed by FIFO algorithm
  Future<List<coinselect.OutputGroup>> baseInputToOutputGroup({
    required List<BaseInput> inputs,
  }) async {
    // necessary to know the creationSequence for FIFO
    final currentChainHeight = await chainHeight;
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
          weight: BigInt.from(input.weight),
          inputCount: BigInt.one,
          creationSequence: creationSequence,
        ),
      );
      creationSequence += 1;
    }
    return outputGroups;
  }
}
