module earlytrade::covered_put_option;
use sui::balance::{Self, Balance};
use sui::event;
use sui::clock::Clock;
use earlytrade::earlytrade::{Self, Market, OrderBook};
use sui::coin::{Self, Coin};
use std::type_name;
use std::string;
use std::u64;

// ====== Constants ======
// Status constants for CoveredPutOption
const STATUS_PENDING_BUYER: u8 = 0;        // Created by writer, waiting for buyer
const STATUS_PENDING_WRITER: u8 = 1;       // Created by buyer, waiting for writer
const STATUS_ACTIVE: u8 = 2;               // Matched and active
const STATUS_EXERCISED: u8 = 3;            // Exercised by buyer(only allow fully exercised)
const STATUS_EXPIRED: u8 = 4;              // Expired without exercise



// ====== Error Codes ======
const EInvalidOption: u64 = 0;
const EOptionNotActive: u64 = 1;
const EOptionNotMatched: u64 = 2;
const EInsufficientUnderlyingAsset: u64 = 3;
const EOptionNotExpired: u64 = 4;
const EOptionNotExercisable: u64 = 5;

// ====== Core Data Structures ======

/// Represents a Covered Put Option that can be traded on the marketplace
public struct CoveredPutOption<phantom TradingCoinType> has key {
    // Object properties
    id: UID,                                // Unique object identifier

    // Option terms
    // suppose the decimal of the underlying asset is 6
    // if the strike_price is 1_000_000, it means 1_000_000/10^6 = 1
    // if the strike_price is 100_000_000, it means 100_000_000/10^6 = 100
    // price = The value of the TradingCoinType/ the value of the UnderlyingAsset
    // However, the decimal of the underlying asset is undetermined
    // For example, if you palce an order strike price 1usdc/wav token, then the strike_price is 1_000_000
    // the value of the USDC / the amount of WAV token
    // So we get: strike_price * underlying_asset_amount = premium_balance.value + collateral_balance.value
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
    creator_address: address,
    created_at: u64,                        // Timestamp when option was created
    last_updated_at: u64,                   // Timestamp of last status change
    
    // Market reference
    market_id: ID,                          // Reference to parent market
}

// ====== Events ======

/// Event emitted when an option is created (by buyer or writer)
public struct OptionCreatedEvent has copy, drop {
    option_id: ID,
    market_id: ID,
    creator_address: address,
    is_buyer_created: bool,
    strike_price: u64,
    premium: u64,
    collateral_amount: u64,
    created_at: u64,
}

/// Event emitted when an option is matched
public struct OptionMatchedEvent has copy, drop {
    option_id: ID,
    market_id: ID,
    buyer: address,
    writer: address,
    strike_price: u64,
    premium: u64,
    collateral_amount: u64,
    matched_at: u64,
}

/// Event emitted when an option is exercised
public struct OptionExercisedEvent has copy, drop {
    option_id: ID,
    market_id: ID,
    buyer: address,
    writer: address,
    exercise_amount: u64,
    exercised_at: u64,
}

/// Event emitted when an option expires
public struct OptionExpiredEvent has copy, drop {
    option_id: ID,
    market_id: ID,
    status: u8,
    expired_at: u64,
}

/// Event emitted when an option is listed for sale
public struct OptionListedEvent has copy, drop {
    option_id: ID,
    market_id: ID,
    seller: address,
    is_buyer_selling: bool,
    asking_price: u64,
    listed_at: u64,
}

/// Event emitted when an option is traded on secondary market
public struct OptionTradedEvent has copy, drop {
    option_id: ID,
    market_id: ID,
    seller: address,
    buyer: address,
    trade_price: u64,
    trade_time: u64,
    is_buyer_role: bool,          // Whether seller was holding buyer role in option
}


// Getter for option info
public fun get_option_info<TradingCoinType>(option: &CoveredPutOption<TradingCoinType>): (
    u64, // strike_price
    u64, // premium
    u64, // collateral_amount
    u8,  // status
    Option<address>, // buyer
    Option<address>, // writer
    Option<u64>, // listed_price
    u64, // created_at
    ID   // market_id
) {
    (
        option.strike_price,
        option.premium_value,
        option.collateral_value,
        option.status,
        option.buyer,
        option.writer,
        option.listed_price,
        option.created_at,
        option.market_id
    )
}

// ====== Public Status Getters ======

public fun status_pending_buyer(): u8 { STATUS_PENDING_BUYER }
public fun status_pending_writer(): u8 { STATUS_PENDING_WRITER }
public fun status_active(): u8 { STATUS_ACTIVE }
public fun status_exercised(): u8 { STATUS_EXERCISED }
public fun status_expired(): u8 { STATUS_EXPIRED }
public fun status_for_sale(): u8 { STATUS_FOR_SALE }



// ====== Internal Option Utilities ======
public(package) fun new_option<TradingCoinType>(
    strike_price: u64,
    underlying_asset_amount: u64,
    fee_paid_by_buyer: u64,
    fee_paid_by_writer: u64,
    status: u8,
    buyer: Option<address>,
    writer: Option<address>,
    premium_balance: Balance<TradingCoinType>,
    collateral_balance: Balance<TradingCoinType>,
    market_id: ID,
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
        premium_value: premium_balance.value(),
        collateral_value: collateral_balance.value(),

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
        creator_address: ctx.sender(),
        created_at: current_time,                        // Timestamp when option was created
        last_updated_at: current_time,                   // Timestamp of last status change
        
        // Market reference
        market_id: market_id,  
    }
}

public(package) fun share_option<TradingCoinType>(option: CoveredPutOption<TradingCoinType>) {
    transfer::share_object(option);
}

// exericese option
public(package) fun buyer_exercise_option<UnderlyingAssetType, TradingCoinType>(option: &mut CoveredPutOption<TradingCoinType>, orderbook: &mut OrderBook, underlying_asset: Coin<UnderlyingAssetType>, market: &Market<TradingCoinType>, clock: &Clock, ctx: &mut TxContext) {

    // check option status and is matched
    assert!(option.status == status_active(), EOptionNotActive);
    assert!(option.buyer.is_some(), EOptionNotMatched);
    assert!(option.writer.is_some(), EOptionNotMatched);

    // update the orderbook move option id from the active to the exercised
    earlytrade::pop_covered_put_option_id_from_active(orderbook, object::id(option));
    earlytrade::push_covered_put_option_id_into_exercised(orderbook, object::id(option));

    // check if the option is able to be exercised
    assert!(earlytrade::is_option_exercisable<TradingCoinType>(market, clock), EOptionNotExercisable);

    let underlying_asset_type = string::from_ascii(*type_name::borrow_string(&type_name::get<UnderlyingAssetType>()));
    // check if the underlying assets is alinged with the market config
    earlytrade::assert_underlying_asset_aligned<TradingCoinType>(market, underlying_asset_type);
    
    // check if the underlying asset amount is enough to exercise the option
    let required_underlying_asset_value = option.underlying_asset_amount * u64::pow(10, earlytrade::get_underlying_asset_decimal<TradingCoinType>(market));
    assert!(underlying_asset.value() >= required_underlying_asset_value, EInsufficientUnderlyingAsset);

    // transfer the the underlying assets to the seller
    transfer::public_transfer(underlying_asset, *option::borrow(&option.writer));

    // take the premium and collateral balance from the option
    let mut premium_collateral_balance = option.premium_balance.withdraw_all();
    premium_collateral_balance.join(option.collateral_balance.withdraw_all());

    // transfer the premium and collateral balance to the seller
    transfer::public_transfer(premium_collateral_balance.into_coin(ctx), *option::borrow(&option.writer));

    // set the option status to exercised
    option.status = status_exercised();
}

// seller take back premium and collateral balance from the expired option
public(package) fun seller_take_back_premium_and_collateral<TradingCoinType>(option: &mut CoveredPutOption<TradingCoinType>, orderbook: &mut OrderBook, market: &Market<TradingCoinType>, clock: &Clock, ctx: &mut TxContext) {
    // check option status and is matched
    assert!(option.status == status_active(), EOptionNotExpired);
    assert!(option.buyer.is_some(), EOptionNotMatched);
    assert!(option.writer.is_some(), EOptionNotMatched);

    // update the orderbook move option id from the active to the expired
    earlytrade::pop_covered_put_option_id_from_active(orderbook, object::id(option));
    earlytrade::push_covered_put_option_id_into_expired(orderbook, object::id(option));
    
    // check if the option is expired
    assert!(earlytrade::is_option_expired<TradingCoinType>(market, clock), EOptionNotExpired);

    // take the premium and collateral balance from the option
    let mut premium_collateral_balance = option.premium_balance.withdraw_all();
    premium_collateral_balance.join(option.collateral_balance.withdraw_all());

    // transfer the premium and collateral balance to the seller
    transfer::public_transfer(premium_collateral_balance.into_coin(ctx), *option::borrow(&option.writer));

    // set the option status to expired
    option.status = status_expired();
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


public fun get_buyer<TradingCoinType>(option: &CoveredPutOption<TradingCoinType>): Option<address> {
    option.buyer
}

public fun get_writer<TradingCoinType>(option: &CoveredPutOption<TradingCoinType>): Option<address> {
    option.writer
}

public fun get_market_id<TradingCoinType>(option: &CoveredPutOption<TradingCoinType>): ID {
    option.market_id
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


// ====== Event Emitters (friend-only) ======
public(package) fun emit_option_created<TradingCoinType>(
    option: &CoveredPutOption<TradingCoinType>,
    creator_address: address,
    is_buyer_created: bool
) {
    event::emit(OptionCreatedEvent {
        option_id: object::id(option),
        market_id: option.market_id,
        creator_address,
        is_buyer_created,
        strike_price: option.strike_price,
        premium: option.premium_value,
        collateral_amount: option.collateral_value,
        created_at: option.created_at,
    });
}

public(package) fun emit_option_matched<TradingCoinType>(
    option: &CoveredPutOption<TradingCoinType>,
    matched_at: u64
) {
    event::emit(OptionMatchedEvent {
        option_id: object::id(option),
        market_id: option.market_id,
        buyer: *option::borrow(&option.buyer),
        writer: *option::borrow(&option.writer),
        strike_price: option.strike_price,
        premium: option.premium_value,
        collateral_amount: option.collateral_value,
        matched_at,
    });
}

public(package) fun emit_option_exercised<TradingCoinType>(
    option: &CoveredPutOption<TradingCoinType>,
    exercise_amount: u64,
    exercised_at: u64
) {
    event::emit(OptionExercisedEvent {
        option_id: object::id(option),
        market_id: option.market_id,
        buyer: *option::borrow(&option.buyer),
        writer: *option::borrow(&option.writer),
        exercise_amount,
        exercised_at,
    });
}

public(package) fun emit_option_expired<TradingCoinType>(
    option: &CoveredPutOption<TradingCoinType>,
    expired_at: u64
) {
    event::emit(OptionExpiredEvent {
        option_id: object::id(option),
        market_id: option.market_id,
        status: option.status,
        expired_at,
    });
}

public(package) fun emit_option_listed<TradingCoinType>(
    option: &CoveredPutOption<TradingCoinType>,
    seller: address,
    is_buyer_selling: bool,
    asking_price: u64,
    listed_at: u64
) {
    event::emit(OptionListedEvent {
        option_id: object::id(option),
        market_id: option.market_id,
        seller,
        is_buyer_selling,
        asking_price,
        listed_at,
    });
}

public(package) fun emit_option_traded<TradingCoinType>(
    option: &CoveredPutOption<TradingCoinType>,
    seller: address,
    buyer: address,
    trade_price: u64,
    trade_time: u64,
    is_buyer_role: bool
) {
    event::emit(OptionTradedEvent {
        option_id: object::id(option),
        market_id: option.market_id,
        seller,
        buyer,
        trade_price,
        trade_time,
        is_buyer_role,
    });
}

