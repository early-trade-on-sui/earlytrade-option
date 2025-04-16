module earlytrade::covered_put_option;
use sui::balance::{Self, Balance};
use sui::clock::Clock;


// ====== Constants ======
// Status constants for CoveredPutOption
const STATUS_WAITING_BUYER: u8 = 0;        // Created by writer, waiting for buyer
const STATUS_WAITING_WRITER: u8 = 1;       // Created by buyer, waiting for writer
const STATUS_ACTIVE: u8 = 2;               // Matched and active
const STATUS_EXERCISED: u8 = 3;            // Exercised by buyer(only allow fully exercised)
const STATUS_EXPIRED: u8 = 4;              // Expired without exercise


// ====== Error Codes ======
const EInvalidOption: u64 = 0;

// ====== Core Data Structures =====
/// Contains the core information about an option that can be stored separately
public struct OptionInfo has copy, drop, store {
    // Option terms
    strike_price: u64,                      // Price at which option can be exercised
    underlying_asset_amount: u64,           // Amount of the underlying asset (ignore decimals)
    premium_value: u64,                     // Premium value
    collateral_value: u64,                  // Collateral value
    
    // Option state
    status: u8,                             // Status code (see constants)
    buyer: Option<address>,                 // Address of option buyer (None if created by writer)
    writer: Option<address>,                // Address of option writer (None if created by buyer)
    
    // Fee information
    fee_paid_by_buyer: u64,                 // Fee paid by buyer
    fee_paid_by_writer: u64,                // Fee paid by writer
    
    // Creator information
    creator_is_buyer: bool,                 // Whether creator is buyer or writer
    creator_address: address,               // Creator's address
    
    // Metadata
    market_id: ID,                          // Reference to parent market
}

/// Represents a Covered Put Option that can be traded on the marketplace
public struct CoveredPutOption<phantom TradingCoinType> has key {
    // Object properties
    id: UID,                                // Unique object identifier
    
    // Core option data
    info: OptionInfo,                       // Core option information
    
    // Premium and collateral balances
    premium_balance: Balance<TradingCoinType>,     // Premium paid, held in escrow
    collateral_balance: Balance<TradingCoinType>,  // Collateral locked, held in escrow
    
    // Secondary market information
    listed_price: Option<u64>,              // Price at which option is listed for sale (if for sale)
    
    // Timestamps
    created_at: u64,                        // Timestamp when option was created
    last_updated_at: u64,                   // Timestamp of last status change
}

// ====== Public Status Getters ======

public fun status_waiting_buyer(): u8 { STATUS_WAITING_BUYER }
public fun status_waiting_writer(): u8 { STATUS_WAITING_WRITER }
public fun status_matched(): u8 { STATUS_ACTIVE }
public fun status_exercised(): u8 { STATUS_EXERCISED }
public fun status_expired(): u8 { STATUS_EXPIRED }



// ====== Internal Option Utilities ======
public(package) fun new_option<TradingCoinType>(
    strike_price: u64,
    premium_value: u64,
    collateral_value: u64,
    underlying_asset_amount: u64,
    fee_paid_by_buyer: u64,
    fee_paid_by_writer: u64,
    status: u8,
    buyer: Option<address>,
    writer: Option<address>,
    premium_balance: Balance<TradingCoinType>,
    collateral_balance: Balance<TradingCoinType>,
    market_id: ID,
    creator_is_buyer: bool,
    ctx: &mut TxContext
): CoveredPutOption<TradingCoinType> {
    let current_time = tx_context::epoch(ctx);
    let creator_address = ctx.sender();

    //assert strike_price * underlying_asset_amount = premium_value + collateral_value
    assert!((strike_price * underlying_asset_amount) == (premium_value + collateral_value), EInvalidOption);

    let info = OptionInfo {
        strike_price,
        underlying_asset_amount,
        premium_value,
        collateral_value,
        status,
        buyer,
        writer,
        fee_paid_by_buyer,
        fee_paid_by_writer,
        creator_is_buyer,
        creator_address,
        market_id,
    };

    CoveredPutOption<TradingCoinType> {
        id: object::new(ctx),
        info,
        premium_balance,
        collateral_balance,
        listed_price: option::none(),
        created_at: current_time,
        last_updated_at: current_time,
    }
}

// destroy the option
public(package) fun destroy_option<TradingCoinType>(option: CoveredPutOption<TradingCoinType>):(Balance<TradingCoinType>, Balance<TradingCoinType>) {
    let CoveredPutOption {
        id,
        info: _,
        premium_balance,
        collateral_balance,
        listed_price: _,
        created_at: _,
        last_updated_at: _,
    } = option;

    // Delete the ID
    object::delete(id);

    // Return the balances and status
    (premium_balance, collateral_balance)
}

// share the option
public(package) fun share_option<TradingCoinType>(option: CoveredPutOption<TradingCoinType>) {
    transfer::share_object(option);
}


// ====== Option Getters ======
public fun get_option_info<TradingCoinType>(option: &CoveredPutOption<TradingCoinType>): OptionInfo {
    option.info
}

public fun get_id<TradingCoinType>(option: &CoveredPutOption<TradingCoinType>): ID {
    object::id(option)
}

public fun get_strike_price<TradingCoinType>(option: &CoveredPutOption<TradingCoinType>): u64 {
    option.info.strike_price
}

public fun get_premium<TradingCoinType>(option: &CoveredPutOption<TradingCoinType>): u64 {
    option.info.premium_value
}

public fun get_collateral_value<TradingCoinType>(option: &CoveredPutOption<TradingCoinType>): u64 {
    option.info.collateral_value
}

public fun get_status<TradingCoinType>(option: &CoveredPutOption<TradingCoinType>): u8 {
    option.info.status
}

public fun get_underlying_asset_amount<TradingCoinType>(option: &CoveredPutOption<TradingCoinType>): u64 {
    option.info.underlying_asset_amount
}

public fun get_buyer<TradingCoinType>(option: &CoveredPutOption<TradingCoinType>): Option<address> {
    option.info.buyer
}

public fun get_writer<TradingCoinType>(option: &CoveredPutOption<TradingCoinType>): Option<address> {
    option.info.writer
}

public fun get_market_id<TradingCoinType>(option: &CoveredPutOption<TradingCoinType>): ID {
    option.info.market_id
}

public fun get_creator_address<TradingCoinType>(option: &CoveredPutOption<TradingCoinType>): address {
    option.info.creator_address
}

public fun get_fee_paid_by_buyer<TradingCoinType>(option: &CoveredPutOption<TradingCoinType>): u64 {
    option.info.fee_paid_by_buyer
}

public fun get_fee_paid_by_writer<TradingCoinType>(option: &CoveredPutOption<TradingCoinType>): u64 {
    option.info.fee_paid_by_writer
}

// ====== Option Mutators (friend-only) ======

public(package) fun set_status<TradingCoinType>(option: &mut CoveredPutOption<TradingCoinType>, clock: &Clock, status: u8) {
    option.info.status = status;
    option.last_updated_at = clock.timestamp_ms();
}

public(package) fun set_buyer<TradingCoinType>(option: &mut CoveredPutOption<TradingCoinType>, buyer: address) {
    option.info.buyer = option::some(buyer);
}

public(package) fun set_writer<TradingCoinType>(option: &mut CoveredPutOption<TradingCoinType>, writer: address) {
    option.info.writer = option::some(writer);
}

public(package) fun set_listed_price<TradingCoinType>(option: &mut CoveredPutOption<TradingCoinType>, price: Option<u64>) {
    option.listed_price = price;
}

public(package) fun join_premium<TradingCoinType>(option: &mut CoveredPutOption<TradingCoinType>, premium: Balance<TradingCoinType>) {
    balance::join(&mut option.premium_balance, premium);
}

public(package) fun join_collateral<TradingCoinType>(option: &mut CoveredPutOption<TradingCoinType>, collateral: Balance<TradingCoinType>) {
    balance::join(&mut option.collateral_balance, collateral);
}

public(package) fun withdraw_premium<TradingCoinType>(option: &mut CoveredPutOption<TradingCoinType>): Balance<TradingCoinType> {
    balance::withdraw_all(&mut option.premium_balance)
}

public(package) fun withdraw_collateral<TradingCoinType>(option: &mut CoveredPutOption<TradingCoinType>): Balance<TradingCoinType> {
    balance::withdraw_all(&mut option.collateral_balance)
}

public(package) fun update_fee_paid_by_buyer<TradingCoinType>(option: &mut CoveredPutOption<TradingCoinType>, fee: u64) {
    option.info.fee_paid_by_buyer = fee;
}

public(package) fun update_fee_paid_by_writer<TradingCoinType>(option: &mut CoveredPutOption<TradingCoinType>, fee: u64) {
    option.info.fee_paid_by_writer = fee;
}

public(package) fun add_premium_balance<TradingCoinType>(option: &mut CoveredPutOption<TradingCoinType>, premium: Balance<TradingCoinType>) {
    balance::join(&mut option.premium_balance, premium);
}

public(package) fun add_collateral_balance<TradingCoinType>(option: &mut CoveredPutOption<TradingCoinType>, collateral: Balance<TradingCoinType>) {
    balance::join(&mut option.collateral_balance, collateral);
}