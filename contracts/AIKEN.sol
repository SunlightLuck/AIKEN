use aiken/collection/dict
use aiken/collection/list
use cardano/address.{Address, Script}
use cardano/assets.{PolicyId}
use cardano/transaction.{Input, Output, OutputReference, Transaction} as tx

//
// Redeemer type:
//   - Mint(Int) => Stake flow, mint that many LP tokens
//   - Burn      => Unstake flow, burn LP tokens and return underlying
//
pub type Action {
  Mint(Int)
  Burn
}

// Optionally, you can store additional information in the datum if you want
// to track something. For simplicity, we omit it or keep it as ByteArray here.
pub type SpendTokenName =
  ByteArray

validator staking_fungible_lp(
  // The underlying token's policy ID (the token we are staking).
  // E.g. for an existing “MyToken” with policy ID X, and name Y.
  underlying_policy_id: PolicyId,
  // The *token name* of the underlying token we expect to stake.
  // For example: `b"MyToken"`.
  underlying_token_name: ByteArray,
  // The LP token name to be minted by this policy.
  // For example: `b"LP"`.
  lp_token_name: ByteArray,
) {
  //---------------------------------------------------------------------------
  // SPEND ENTRY POINT
  //---------------------------------------------------------------------------
  spend(
    _datum: Option<SpendTokenName>,
    _redeemer: Data,
    own_ref: OutputReference,
    transaction: Transaction,
  ) {
    let Transaction { inputs, mint, .. } = transaction

    // Identify the script input
    expect Some(own_input) =
      list.find(inputs, fn(input) { input.output_reference == own_ref })

    let Input {
      output: Output { address: Address { payment_credential, .. }, .. },
      ..
    } = own_input

    // Confirm it is indeed this script
    expect Script(own_validator_hash) = payment_credential

    // Example minimal check: we expect a single LP token to be burned
    // to allow spending.
    (
      mint
        |> assets.quantity_of(own_validator_hash, lp_token_name)
    ) == -1
    // If this fails, the transaction fails
  }

  //---------------------------------------------------------------------------
  // MINT (POLICY) ENTRY POINT
  //---------------------------------------------------------------------------
  mint(rdmr: Action, policy_id: PolicyId, transaction: Transaction) {
    let Transaction { inputs, mint, .. } = transaction  // Removed extra_signatories

    // Gather minted assets under "this" policy
    let minted_assets =
      mint
        |> assets.tokens(policy_id)
        |> dict.to_pairs()

    when rdmr is {
      //-----------------------------------------------------------------------
      // STAKE => Mint(n)
      //-----------------------------------------------------------------------
      Mint(n) -> {
        // Check how many underlying tokens are actually provided in the inputs.
        let total_staked =
          get_total_tokens_in_inputs(
            inputs,
            underlying_policy_id,
            underlying_token_name,
          )

        // Check minted quantity for our chosen LP token name
        let minted_lp_amt =
          get_minted_amount_for_token(minted_assets, lp_token_name)

        total_staked == n && minted_lp_amt == n
      }

      //-----------------------------------------------------------------------
      // UNSTAKE => Burn
      //-----------------------------------------------------------------------
      Burn -> {
        let minted_lp_amt =
          get_minted_amount_for_token(minted_assets, lp_token_name)

        minted_lp_amt < 0
      }
    }
  }

  // Default fallback
  else(_) {
    fail
  }
}

// -----------------------------------------------------------------------------
// Helper: Return how many of the `underlying_policy_id` + `underlying_token_name` 
//         exist across the inputs being spent. This is a simplified approach
//         (ignores partial/other tokens).
// -----------------------------------------------------------------------------
fn get_total_tokens_in_inputs(
  inputs: List<Input>,
  policy_id: PolicyId,
  token_name: ByteArray,
) -> Int {
  let amounts =
    list.map(
      inputs,
      fn(input) {
        let quantity =
          assets.quantity_of(input.output.value, policy_id, token_name)
        quantity
      },
    )

  list.foldl(amounts, 0, fn(acc, qty) { acc + qty })
}

// -----------------------------------------------------------------------------
// Helper: Return how many of `token_name` are minted (can be negative if burning).
// -----------------------------------------------------------------------------
fn get_minted_amount_for_token(
  minted_assets: Pairs<ByteArray, Int>,
  token_name: ByteArray,
) -> Int {
  // minted_assets is a list of (tokenName, quantity).
  // We find the pair with the matching token_name and return its quantity.
  when minted_assets is {
    [] -> 0
    [Pair(name, amt), ..rest] ->
      if name == token_name {
        amt
      } else {
        get_minted_amount_for_token(rest, token_name)
      }
  }
}
