use aiken/collection/dict
use aiken/collection/list
use cardano/address.{Address, Script}
use cardano/assets.{PolicyId}
use cardano/transaction.{Input, Output, OutputReference, Transaction} as tx

pub type Action {
  Mint(Int)
  Burn
  DepositReward
}

pub type SpendTokenName = ByteArray

validator staking_fungible_lp(
  underlying_policy_id: PolicyId,
  underlying_token_name: ByteArray,
  lp_token_name: ByteArray,
  reward_policy_id: PolicyId,
  reward_token_name: ByteArray,
  admin_address: Address
) {
  spend(
    _datum: Option<SpendTokenName>,
    _redeemer: Data,
    own_ref: OutputReference,
    transaction: Transaction,
  ) {
    let Transaction { inputs, mint, outputs, extra_signatories } = transaction

    expect Some(own_input) =
      list.find(inputs, fn(input) { input.output_reference == own_ref })

    let Input { output } = own_input
    let Output { address } = output
    let Address { payment_credential } = address

    expect Script(own_validator_hash) = payment_credential

    let burned_lp_amt =
      assets.quantity_of(mint, own_validator_hash, lp_token_name)

    // Changed to check if burned_lp_amt is non-negative
    expect burned_lp_amt >= 0

    let total_staked =
      get_total_tokens_in_inputs(inputs, underlying_policy_id, underlying_token_name)

    let reward_due = calculate_rewards(total_staked, burned_lp_amt, transaction)

    let reward_available =
      get_total_tokens_in_inputs(inputs, reward_policy_id, reward_token_name)

    expect reward_due <= reward_available
  }

  mint(rdmr: Action, policy_id: PolicyId, transaction: Transaction) {
    let Transaction { inputs, mint, outputs, extra_signatories } = transaction

    let minted_assets =
      assets.tokens(mint, policy_id)
      |> dict.to_pairs()

    when rdmr is {
      Mint(n) -> {
        let total_staked =
          get_total_tokens_in_inputs(
            inputs,
            underlying_policy_id,
            underlying_token_name,
          )

        let minted_lp_amt =
          get_minted_amount_for_token(minted_assets, lp_token_name)

        expect total_staked == n && minted_lp_amt == n
      }
      Burn -> {
        let minted_lp_amt =
          get_minted_amount_for_token(minted_assets, lp_token_name)

        expect minted_lp_amt < 0
      }
      DepositReward -> {
        let admin_signed =
          list.member(extra_signatories, admin_address.payment_credential)

        expect admin_signed
      }
    }
  }

  else(_) {
    // Improved error handling
    fail("Invalid redeemer action")
  }
}

// Calculate rewards based on staked amount and duration
fn calculate_rewards(
  total_staked: Int,
  burned_lp_amt: Int,
  transaction: Transaction
) -> Int {
  let staking_duration = get_staking_duration(transaction)

  let annual_reward_rate = 8

  (total_staked * staking_duration * annual_reward_rate) / (365 * 100)
}

// Get staking duration in days
fn get_staking_duration(transaction: Transaction) -> Int {
  let Transaction { inputs } = transaction

  // Find the input UTxO with the staking information
  let staking_input =
    list.find(inputs, fn(input) {
      match input.output.datum {
        Some(datum) => datum == "staking_start_time", // Adjust this condition as needed
        None => false
      }
    })

  expect Some(Input { output: Output { datum } }) = staking_input

  // Extract the staking start time
  let staking_start_time =
    match datum {
      Some(datum) => datum |> as_int,
      None => fail("Staking datum not found")
    }

  // Assume the current transaction timestamp is the staking end time
  let staking_end_time = transaction.validity_range.upper |> as_int

  // Calculate the duration in days
  (staking_end_time - staking_start_time) / 86400
}

// Get total tokens in inputs for a specific policy and token name
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

// Get minted amount for a specific token name
fn get_minted_amount_for_token(
  minted_assets: Pairs<ByteArray, Int>,
  token_name: ByteArray,
) -> Int {
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