/*
this project is a covered-put option trading marketplace on Sui.

This is for early trade of options before TGE.  Users who will receive the tokens after TGE can buy the covered-put options to lock in the price. 
The option writer can gain exposures before TGE and earn premium from the buyers.

Features:
- buyers can create a covered-put option order, pay premium and set strike price, waiting for writers pay collateral to accept the option
- writers can accept the option, pay collateral from existing orders.
- writers can set the strike price and premium, pay collateral. waiting for buyers to pay premiums. 
- buyers can buy the option, pay premiums.
- After TGE, buyers can exercise the option, and pay underlying asset to get the covered assets. writers will receive the underlying asset.
- If the option is not exercised, the collateral will be returned to the writers after the expiration. Buyers can't exercise the option after the expiration.


Rules:
- The collateral and premium should be paid in the same coin.
- The option price should be set in the same coin.
- The option should be exercised in the same coin. 

Buyers:
- can create a covered-put option order, pay premium and set strike price, waiting for writers pay collateral to accept the option
- can buy the option, pay premiums.
- cancel the order before the option is accepted by writers.
- sell the option to other buyers before the expiration.
- should pay 1% trading fee(premium) to the administrator.

Writers:
- can accept the option, pay collateral from existing orders.
- can set the strike price and premium, pay collateral. waiting for buyers to pay premiums. 
- cancel the order before the option is accepted by buyers.
- sell the option to other writers before the expiration.
- should pay 1% trading fee(premium) to the administrator.

Administrator:
- can set the exercise date
- can withdraw trading fees(premium)
- can set the underlying assets after TGE
*/
module earlytrade::earlytrade;
use sui::balance::{Self, Balance};
use sui::coin::Coin;
use sui::table::{Self, Table};
use sui::event;
use std::string::{Self, String};
use sui::clock::Clock;
use std::type_name;
use earlytrade::covered_put_option::{Self, CoveredPutOption, OptionInfo};


// ====== Constants ======
// Error codes
const EInvalidDate: u64 = 1;
const EUnderlyingAssetNotSet: u64 = 2;
const EUnderlyingAssetNotAligned: u64 = 3;

// ====== Core Data Structures ======

/// AdminCap is a capability object that grants administrative privileges
public struct AdminCap has key, store {
    id: UID
}

/// Market object that manages options for a specific underlying asset
public struct Market<phantom TradingCoinType> has key {
    // Object properties
    id: UID,                                // Unique object identifier
    
    // Market configuration
    market_name: String,                    // Name of the market: WAV-USDC, WAV-SUI, etc.
    trading_fee_percentage: u64,            // Fee percentage (100 = 1%)
    minimum_trading_value: u64,             // Minimum trading value
    
    // Fee balance
    fee_balance: Balance<TradingCoinType>,   // Accumulated fees for admin withdrawal
    
    // Market timeline
    creation_date: u64,                     // When market was created
    exericse_date: Option<u64>,                  // Token Generation Event date (if set)
    expiration_date: Option<u64>,         // Last date to exercise after TGE
    
    // underlying asset config
    underlying_asset_type: Option<String>,  // Address of underlying asset after TGE
    decimal: u8,
    
    // Trading metrics
    total_premium_volume: u64,              // Total premium volume traded
    total_collateral_volume: u64,           // Total collateral volume locked
    active_options_count: u64,              // Number of active options
}


/// serve as a indexer for all options
public struct OrderBook has key {
    // Object properties
    id: UID,                                // Unique object identifier
    name: String,                           // Name of the orderbook: WAV Premarket Orderbook, WAL Premarket Orderbook
    market_id: vector<ID>,                  // Reference to markets(Buck, USDC, SUI and etc.)
    
    // Primary market orders
    waiting_writer_orders: Table<ID, OptionInfo>,  
    waiting_buyer_orders: Table<ID, OptionInfo>,   
    
    // Order id tracking
    active_options: Table<ID, OptionInfo>,                // Active options
    exercised_options: Table<ID, OptionInfo>,             // Exercised options
    expired_options: Table<ID, OptionInfo>,               // Expired options
    
    created_at: u64,                        // When orderbook was created
}


// ====== Events ======
/// Event emitted when a market is created
public struct MarketCreatedEvent has copy, drop {
    market_id: ID,
    market_name: String,
    trading_coin_type: String,
    trading_fee_percentage: u64,
    minimum_trading_value: u64,
    creator: address,
    creation_date: u64,
}

public struct OrderBookCreatedEvent has copy, drop {
    orderbook_id: ID,
    orderbook_name: String,
    creator: address,
    creation_date: u64,
}

/// Event emitted when fees are withdrawn from a market
public struct FeesWithdrawnEvent has copy, drop {
    market_id: ID,
    market_name: String,
    trading_coin_type: String,
    amount: u64,
    recipient: address,
    timestamp: u64,
}

/// Event emitted when market parameters are updated
public struct MarketParametersUpdatedEvent has copy, drop {
    market_id: ID,
    market_name: String,
    exercise_date: u64,
    expiration_date: u64,
    updater: address,
    timestamp: u64,
}

/// Event emitted when underlying asset is set
public struct UnderlyingAssetUpdatedEvent has copy, drop {
    market_id: ID,
    market_name: String,
    underlying_asset_type: String,
    decimal: u8,
    updater: address,
    timestamp: u64,
}

// ====== Initialization Functions ======

/// Initialize the module and create the admin capability
fun init(ctx: &mut TxContext) {
    let admin_cap = AdminCap {
        id: object::new(ctx)
    };
    transfer::public_transfer(admin_cap,ctx.sender());
}

public fun init_orderbook(
    orderbook_name: String,
    _: &AdminCap,
    clock: &Clock,
    ctx: &mut TxContext
) {
    let current_time = clock.timestamp_ms();
    let orderbook_id = object::new(ctx);
    let orderbook = OrderBook {
        id: orderbook_id,
        name: orderbook_name,
        market_id: vector::empty(),

        waiting_writer_orders: table::new<ID,OptionInfo>(ctx),
        waiting_buyer_orders: table::new<ID,OptionInfo>(ctx),

        active_options: table::new<ID,OptionInfo>(ctx),
        exercised_options: table::new<ID,OptionInfo>(ctx),
        expired_options: table::new<ID,OptionInfo>(ctx),
        
        created_at: current_time,
    };

    event::emit(OrderBookCreatedEvent {
        orderbook_id: object::id(&orderbook),
        orderbook_name: orderbook_name,
        creator:ctx.sender(),
        creation_date: current_time,
    });


    transfer::share_object(orderbook);
}

/// Create a new market
public fun create_market<TradingCoinType>(
    _: &AdminCap,
    name: String,
    orderbook: &mut OrderBook,
    clock: &Clock,
    trading_fee_percentage: u64,
    minimum_trading_value: u64,
    ctx: &mut TxContext
) {

    let current_time = clock.timestamp_ms();
    
    let market_id = object::new(ctx);
    
    let market = Market<TradingCoinType> {
        id: market_id,
        market_name: name,

        trading_fee_percentage: trading_fee_percentage,
        minimum_trading_value: minimum_trading_value,
        fee_balance: balance::zero(),

        creation_date: current_time,
        exericse_date: option::none(),
        expiration_date: option::none(),
        
        underlying_asset_type: option::none(),
        decimal: 0u8,

        total_premium_volume: 0u64,
        total_collateral_volume: 0u64,
        active_options_count: 0u64,

    };
    
    // add market to orderbook
    vector::push_back(&mut orderbook.market_id, object::id(&market));
    
    // Emit market created event
    event::emit(MarketCreatedEvent {
        market_id: object::id(&market),
        market_name: name,
        trading_coin_type: string::from_ascii(*type_name::borrow_string(&type_name::get<TradingCoinType>())),
        trading_fee_percentage: trading_fee_percentage,
        minimum_trading_value: minimum_trading_value,
        creator: ctx.sender(),
        creation_date: current_time,
    });
    
    // Transfer market to admin and orderbook as shared
    transfer::share_object(market);
}


// ====== Market Admin Functions ======

/// Set TGE date (admin only)
public fun set_exericse_expiration_date<TradingCoinType>(
    market: &mut Market<TradingCoinType>,
    _: &AdminCap,
    clock: &Clock,
    exericse_date: u64,
    expiration_date: u64,
    ctx: &mut TxContext
) {
    // Validate dates
    let current_time = clock.timestamp_ms();
    assert!(exericse_date > current_time, EInvalidDate);
    assert!(expiration_date > exericse_date, EInvalidDate);
    
    // Set TGE date and exercise period
    market.exericse_date = option::some(exericse_date);
    market.expiration_date = option::some(expiration_date);
    
    // Emit event for market parameters update
    event::emit(MarketParametersUpdatedEvent {
        market_id: object::id(market),
        market_name: market.market_name,
        exercise_date: exericse_date,
        expiration_date: expiration_date,
        updater: ctx.sender(),
        timestamp: current_time,
    });
}

/// Withdraw accumulated fees (admin only)
public fun withdraw_fees<TradingCoinType>(
    market: &mut Market<TradingCoinType>,
    _: &AdminCap,
    ctx: &mut TxContext
): Coin<TradingCoinType> {

    // Extract all accumulated fees
    let fee_balance = balance::withdraw_all(&mut market.fee_balance);
    let amount = fee_balance.value();
    let coin = fee_balance.into_coin(ctx);
    
    // Emit event for fee withdrawal
    event::emit(FeesWithdrawnEvent {
        market_id: object::id(market),
        market_name: market.market_name,
        trading_coin_type: string::from_ascii(*type_name::borrow_string(&type_name::get<TradingCoinType>())),
        amount,
        recipient:ctx.sender(),
        timestamp: tx_context::epoch(ctx),
    });
    
    coin
}

/// set the underlying asset type and decimal(admin only)
public fun set_underlying_asset_type_and_decimal<UnderlyingAssetType, TradingCoinType>(
    market: &mut Market<TradingCoinType>,
    _: &AdminCap,
    decimal: u8,
    ctx: &mut TxContext
) {
    let asset_type = string::from_ascii(*type_name::borrow_string(&type_name::get<UnderlyingAssetType>()));
    market.underlying_asset_type = option::some(asset_type);
    market.decimal = decimal;
    
    // Emit event for underlying asset update
    event::emit(UnderlyingAssetUpdatedEvent {
        market_id: object::id(market),
        market_name: market.market_name,
        underlying_asset_type: asset_type,
        decimal,
        updater:ctx.sender(),
        timestamp: tx_context::epoch(ctx),
    });
}

// ====== Helper Functions ======

// charge the fee to the fee balance
public(package) fun charge_fee<TradingCoinType>(market: &mut Market<TradingCoinType>, fee: Balance<TradingCoinType>) {
    balance::join(&mut market.fee_balance, fee);
}

public(package) fun return_fee<TradingCoinType>(market: &mut Market<TradingCoinType>, return_amount: u64): Balance<TradingCoinType> {
    market.fee_balance.split(return_amount)
}


// check if the option is able to be exercised according the current time and the exercise date and expiration date
public fun is_option_exercisable<TradingCoinType>(market: &Market<TradingCoinType>, clock: &Clock): bool {
    let current_time = clock.timestamp_ms();
    option::is_some(&market.exericse_date) && current_time > *option::borrow(&market.exericse_date) && current_time < *option::borrow(&market.expiration_date)
}

// check if the option is expired according the current time and the expiration date
public fun is_option_expired<TradingCoinType>(market: &Market<TradingCoinType>, clock: &Clock): bool {
    let current_time = clock.timestamp_ms();
    option::is_some(&market.expiration_date) && current_time > *option::borrow(&market.expiration_date)
}

// check the market is active
public fun is_market_active<TradingCoinType>(clock: &Clock, market: &Market<TradingCoinType>): bool {
   
    // if the TGE date and expiration date are set, check if the current time is before the TGE date
    if (option::is_some(&market.exericse_date) && option::is_some(&market.expiration_date)) {
        if (clock.timestamp_ms() < *option::borrow(&market.exericse_date)) {
            return true
        }
        else{
            return false
        }
    };
    // if it is not set, return true
    true
}

// assert whether the underlying assets is aligned with the market
public fun assert_underlying_asset_aligned<TradingCoinType>(
    market: &Market<TradingCoinType>,
    underlying_asset_type: String,
) {
    // check whether the underlying asset is set
    assert!(option::is_some(&market.underlying_asset_type), EUnderlyingAssetNotSet);
    // check whether the underlying asset is aligned with the market
    assert!(market.underlying_asset_type == option::some(underlying_asset_type), EUnderlyingAssetNotAligned);
}

// check if the trading value is enough to trade
public fun is_trading_value_enough<TradingCoinType>(
    market: &Market<TradingCoinType>,
    trading_value: u64,
): bool {
    trading_value >= market.minimum_trading_value
}


// ====== Update Orderbook Functions ======   

// push covered-put option id into orderbook's waiting writer orders
public fun push_covered_put_option_id_into_waiting_writer<TradingCoinType>(
    orderbook: &mut OrderBook,
    option: &CoveredPutOption<TradingCoinType>,
) {
    table::add(&mut orderbook.waiting_writer_orders, option.get_id(), covered_put_option::get_option_info(option));
}
// push covered-put option id into orderbook's waiting buyer orders
public fun push_covered_put_option_id_into_waiting_buyer<TradingCoinType>(
    orderbook: &mut OrderBook,
    option: &CoveredPutOption<TradingCoinType>,
) {
    table::add(&mut orderbook.waiting_buyer_orders, option.get_id(), covered_put_option::get_option_info(option));
}
// push covered-put option id into orderbook's active options
public fun push_covered_put_option_id_into_active<TradingCoinType>(
    orderbook: &mut OrderBook,
    option: &CoveredPutOption<TradingCoinType>,
) {
    table::add(&mut orderbook.active_options, option.get_id(), covered_put_option::get_option_info(option));
}

// push covered-put option id into orderbook's exercised options
public fun push_covered_put_option_id_into_exercised<TradingCoinType>(
    orderbook: &mut OrderBook,
    option: &CoveredPutOption<TradingCoinType>,
) {
    table::add(&mut orderbook.exercised_options, option.get_id(), covered_put_option::get_option_info(option));
}

// push covered-put option id into orderbook's expired options
public fun push_covered_put_option_id_into_expired<TradingCoinType>(
    orderbook: &mut OrderBook,
    option: &CoveredPutOption<TradingCoinType>,
) {
    table::add(&mut orderbook.expired_options, option.get_id(), covered_put_option::get_option_info(option));
}

// pop up covered-put option id from orderbook's waiting writer orders
public fun pop_covered_put_option_id_from_waiting_writer<TradingCoinType>(
    orderbook: &mut OrderBook,
    option: &CoveredPutOption<TradingCoinType>,
) {
    table::remove(&mut orderbook.waiting_writer_orders, option.get_id());
}

// pop up covered-put option id from orderbook's waiting buyer orders
public fun pop_covered_put_option_id_from_waiting_buyer<TradingCoinType>(
    orderbook: &mut OrderBook,
    option: &CoveredPutOption<TradingCoinType>,
) {
    table::remove(&mut orderbook.waiting_buyer_orders, option.get_id());
}


// pop up covered-put option id from orderbook's active options 
public fun pop_covered_put_option_id_from_active<TradingCoinType>(
    orderbook: &mut OrderBook,
    option: &CoveredPutOption<TradingCoinType>,
) {
    table::remove(&mut orderbook.active_options, option.get_id());
}

// pop up covered-put option id from orderbook's exercised options
public fun pop_covered_put_option_id_from_exercised<TradingCoinType>(
    orderbook: &mut OrderBook,
    option: &CoveredPutOption<TradingCoinType>,
) {
    table::remove(&mut orderbook.exercised_options, option.get_id());
}

// pop up covered-put option id from orderbook's expired options
public fun pop_covered_put_option_id_from_expired(
    orderbook: &mut OrderBook,
    covered_put_option_id: ID,
) {
    table::remove(&mut orderbook.expired_options, covered_put_option_id);
}


// ====== Get Functions ======

// get the orderbook id
public fun get_orderbook_id(
    orderbook: &OrderBook,
): ID {
    object::id(orderbook)  
}

// get the market id
public fun get_market_id<TradingCoinType>(
    market: &Market<TradingCoinType>,
): ID {
    object::id(market)
}

// get underlying asset's decimal
public fun get_underlying_asset_decimal<TradingCoinType>(
    market: &Market<TradingCoinType>,
): u8 {
    market.decimal
}

// get underlying asset's type
public fun get_underlying_asset_type<TradingCoinType>(
    market: &Market<TradingCoinType>,
): String {
    *option::borrow(&market.underlying_asset_type)
}

// get the fee rate
public fun get_fee_rate<TradingCoinType>(
    market: &Market<TradingCoinType>,
): u64 {
    market.trading_fee_percentage
}


#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}