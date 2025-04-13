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

// ====== Core Data Structures ======

/// Represents a Covered Put Option that can be traded on the marketplace
public struct CoveredPutOption<phantom TradingCoinType> has key {
    // Object properties
    id: UID,                                // Unique object identifier

    // Option terms
    // the decimal of the underlying asset is undetermined
    // For example, if you palce an order strike price 1 usdc/wav token, then the strike_price is 1_000_000
    // the value of the USDC / the amount of WAV token
    // So we get: strike_price * underlying_asset_amount = premium_balance.value + collateral_balance.value
    // when call it amount it means without decimals, value means with decimals
    strike_price: u64,                      // Price at which option can be exercised
    underlying_asset_amount: u64,           // Amount of the underlying asset (ignore decimals)
    premium_value: u64,
    collateral_value: u64,


    // fee records
    fee_paid_by_buyer: u64,
    fee_paid_by_writer: u64,

    // Option status
    status: u8,                             // Status code (see constants)
    
    // Participant information
    buyer: Option<address>,                 // Address of option buyer (None if created by writer)
    writer: Option<address>,                // Address of option writer (None if created by buyer)
    
    // Premium and collateral balances
    premium_balance: Balance<TradingCoinType>,     // Premium paid, held in escrow
    collateral_balance: Balance<TradingCoinType>,  // Collateral locked, held in escrow
    
    // Secondary market information
    listed_price: Option<u64>,              // Price at which option is listed for sale (if for sale)
    
    // Metadata
    creator_is_buyer: bool,
    creator_address: address,
    created_at: u64,                        // Timestamp when option was created
    last_updated_at: u64,                   // Timestamp of last status change
    
    // Market reference
    market_id: ID,                          // Reference to parent market
}

public struct OptionInfo has copy, drop, store {
    id: ID,
    status: u8,
    buyer: Option<address>,
    writer: Option<address>,
    strike_price: u64,
    amount: u64,
    premium_value: u64,
    collateral_value: u64,
}

// ====== Option Info Functions ======
// Getter for option info
public fun get_option_info<TradingCoinType>(option: &CoveredPutOption<TradingCoinType>): OptionInfo {
    OptionInfo {
        id: object::id(option),
        status: option.status,
        buyer: option.buyer,
        writer: option.writer,
        strike_price: option.strike_price,
        amount: option.underlying_asset_amount,
        premium_value: option.premium_value,
        collateral_value: option.collateral_value,
    }
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

    //assert strike_price * underlying_asset_amount = premium_balance.value + collateral_balance.value
    assert!(strike_price * underlying_asset_amount == premium_balance.value() + collateral_balance.value(), EInvalidOption);
    
    CoveredPutOption<TradingCoinType> {
        id: object::new(ctx),                                // Unique object identifier

        // Option terms
        strike_price: strike_price,                      // Price at which option can be exercised
        underlying_asset_amount: underlying_asset_amount,           // Amount of the underlying asset (ignore decimals)
        premium_value: premium_value,
        collateral_value: collateral_value,

        // fee records
        fee_paid_by_buyer: fee_paid_by_buyer,
        fee_paid_by_writer: fee_paid_by_writer,

        // Option status
        status: status,                             // Status code (see constants)
        
        // Participant information
        buyer: buyer,                 // Address of option buyer (None if created by writer)
        writer: writer,                // Address of option writer (None if created by buyer)
        premium_balance: premium_balance,     // Premium paid, held in escrow
        collateral_balance: collateral_balance,  // Collateral locked, held in escrow
        
        // Secondary market information
        listed_price: option::none(),              // secondary market price should be none when option is created
        
        // Metadata
        creator_is_buyer: creator_is_buyer,
        creator_address: ctx.sender(),
        created_at: current_time,                        // Timestamp when option was created
        last_updated_at: current_time,                   // Timestamp of last status change
        
        // Market reference
        market_id: market_id,  
    }
}

// destroy the option
public(package) fun destroy_option<TradingCoinType>(option: CoveredPutOption<TradingCoinType>):(Balance<TradingCoinType>, Balance<TradingCoinType>) {
    let CoveredPutOption {
        id,
        strike_price: _,
        underlying_asset_amount: _,
        premium_value: _,
        collateral_value: _,
        fee_paid_by_buyer: _,
        fee_paid_by_writer: _,
        status: _,
        buyer: _,
        writer: _,
        premium_balance,
        collateral_balance,
        listed_price: _,
        creator_is_buyer: _,
        creator_address: _,
        created_at: _,
        last_updated_at: _,
        market_id: _,
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

public fun get_id<TradingCoinType>(option: &CoveredPutOption<TradingCoinType>): ID {
    object::id(option)
}

public fun get_strike_price<TradingCoinType>(option: &CoveredPutOption<TradingCoinType>): u64 {
    option.strike_price
}

public fun get_premium<TradingCoinType>(option: &CoveredPutOption<TradingCoinType>): u64 {
    option.premium_value
}

public fun get_collateral_amount<TradingCoinType>(option: &CoveredPutOption<TradingCoinType>): u64 {
    option.collateral_value
}

public fun get_status<TradingCoinType>(option: &CoveredPutOption<TradingCoinType>): u8 {
    option.status
}

public fun get_underlying_asset_amount<TradingCoinType>(option: &CoveredPutOption<TradingCoinType>): u64 {
    option.underlying_asset_amount
}

public fun get_buyer<TradingCoinType>(option: &CoveredPutOption<TradingCoinType>): Option<address> {
    option.buyer
}

public fun get_writer<TradingCoinType>(option: &CoveredPutOption<TradingCoinType>): Option<address> {
    option.writer
}

public fun get_market_id<TradingCoinType>(option: &CoveredPutOption<TradingCoinType>): ID {
    option.market_id
}

public fun get_creator_address<TradingCoinType>(option: &CoveredPutOption<TradingCoinType>): address {
    option.creator_address
}

public fun get_fee_paid_by_buyer<TradingCoinType>(option: &CoveredPutOption<TradingCoinType>): u64 {
    option.fee_paid_by_buyer
}

public fun get_fee_paid_by_writer<TradingCoinType>(option: &CoveredPutOption<TradingCoinType>): u64 {
    option.fee_paid_by_writer
}

// ====== Option Mutators (friend-only) ======

public(package) fun set_status<TradingCoinType>(option: &mut CoveredPutOption<TradingCoinType>, clock: &Clock, status: u8) {
    option.status = status;
    option.last_updated_at = clock.timestamp_ms();
}

public(package) fun set_buyer<TradingCoinType>(option: &mut CoveredPutOption<TradingCoinType>, buyer: address) {
    option.buyer = option::some(buyer);
}

public(package) fun set_writer<TradingCoinType>(option: &mut CoveredPutOption<TradingCoinType>, writer: address) {
    option.writer = option::some(writer);
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
    option.fee_paid_by_buyer = fee;
}

public(package) fun update_fee_paid_by_writer<TradingCoinType>(option: &mut CoveredPutOption<TradingCoinType>, fee: u64) {
    option.fee_paid_by_writer = fee;
}

public(package) fun add_premium_balance<TradingCoinType>(option: &mut CoveredPutOption<TradingCoinType>, premium: Balance<TradingCoinType>) {
    balance::join(&mut option.premium_balance, premium);
}

public(package) fun add_collateral_balance<TradingCoinType>(option: &mut CoveredPutOption<TradingCoinType>, collateral: Balance<TradingCoinType>) {
    balance::join(&mut option.collateral_balance, collateral);
}