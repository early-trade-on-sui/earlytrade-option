module earlytrade::user;

use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::event;
use sui::clock::Clock;
use std::option::{Self, Option};
use std::vector;

use earlytrade::earlytrade::{Self, Market, OrderBook};
use earlytrade::covered_put_option::{Self, CoveredPutOption};

// ====== Constants ======

// Error codes
const ENotAuthorized: u64 = 0;
const EInvalidAmount: u64 = 1;
const EInvalidStatus: u64 = 2;
const EAlreadyMatched: u64 = 3;
const EOptionExpired: u64 = 4;
const ENotExercisable: u64 = 5;
const ENotTransferable: u64 = 6;
const EInvalidTradePrice: u64 = 7;

// ====== Core Data Structures ======

public struct UserOrders has key {
    id: UID,
    owner: address,
    
    orderbook_id: ID,

    pending_orders: vector<ID>,
    active_orders: vector<ID>,
    exercised_orders: vector<ID>,
    expired_orders: vector<ID>,

    secondary_market_orders: vector<ID>,
}

// ====== Public Functions ======

/// Initialize user orders for a new user
public fun init_user_orders(orderbook: &OrderBook, ctx: &mut TxContext): UserOrders {
    UserOrders {
        id: object::new(ctx),
        owner: ctx.sender(),
        orderbook_id: orderbook.get_orderbook_id(),

        active_orders: vector::empty(),
        exercised_orders: vector::empty(),
        expired_orders: vector::empty(),
        pending_orders: vector::empty(),
        secondary_market_orders: vector::empty(),
    }
}

/// Create a covered put option as a buyer
public fun create_option_as_buyer<CoinType>(
    user_orders: &mut UserOrders,
    orderbook: &mut OrderBook,
    market: &mut Market<CoinType>,
    
    strike_price: u64, // the strike price of the option
    amount: u64, // amount of the underlying assets


    premium_coin: Coin<CoinType>,
    ctx: &mut TxContext
) {

    let option = covered_put_option::new_option(
        strike_price,
        amount,
        fee_paid_by_buyer,
        fee_paid_by_writer,
        covered_put_option::status_pending_buyer(),
    );


    vector::push_back(&mut user_orders.pending_orders, option_id);
}





/// Create a covered put option as a writer
public fun create_option_as_writer<CoinType>(
    user_orders: &mut UserOrders,
    orderbook: &mut OrderBook,
    market: &mut Market<CoinType>,
    strike_price: u64,
    premium: u64,
    expiration_date: u64,
    collateral_coin: Coin<CoinType>,
    ctx: &mut TxContext
) {
    let option_id = earlytrade::create_option_as_writer(
        orderbook,
        market,
        strike_price,
        premium,
        expiration_date,
        collateral_coin,
        ctx
    );
    
    vector::push_back(&mut user_orders.pending_orders, option_id);
}

/// Fill a covered put option as a buyer
public fun fill_option_as_buyer<CoinType>(
    user_orders: &mut UserOrders,
    orderbook: &mut OrderBook,
    market: &mut Market<CoinType>,
    option: &mut CoveredPutOption<CoinType>,
    premium_coin: Coin<CoinType>,
    ctx: &mut TxContext
) {
    assert!(option.status == covered_put_option::status_pending_buyer(), EInvalidStatus);
    assert!(option.writer.is_some(), ENotAuthorized);
    
    let option_id = covered_put_option::get_id(option);
    
    // Remove from pending orders
    let index = vector::index_of(&user_orders.pending_orders, &option_id);
    if (index != -1) {
        vector::remove(&mut user_orders.pending_orders, (index as u64));
    };
    
    // Add to active orders
    vector::push_back(&mut user_orders.active_orders, option_id);
}

/// Fill a covered put option as a writer
public fun fill_option_as_writer<CoinType>(
    user_orders: &mut UserOrders,
    orderbook: &mut OrderBook,
    market: &mut Market<CoinType>,
    option: &mut CoveredPutOption<CoinType>,
    collateral_coin: Coin<CoinType>,
    ctx: &mut TxContext
) {
    assert!(option.status == covered_put_option::status_pending_writer(), EInvalidStatus);
    assert!(option.buyer.is_some(), ENotAuthorized);
    
    let option_id = covered_put_option::get_id(option);
    
    // Remove from pending orders
    let index = vector::index_of(&user_orders.pending_orders, &option_id);
    if (index != -1) {
        vector::remove(&mut user_orders.pending_orders, (index as u64));
    };
    
    // Add to active orders
    vector::push_back(&mut user_orders.active_orders, option_id);
}

/// Exercise a covered put option as buyer
public fun exercise_option<CoinType>(
    user_orders: &mut UserOrders,
    market: &mut Market<CoinType>,
    option: &mut CoveredPutOption<CoinType>,
    underlying_coin: Coin<CoinType>,
    ctx: &mut TxContext
) {
    assert!(option.status == covered_put_option::status_active(), EInvalidStatus);
    assert!(option.buyer.is_some(), ENotAuthorized);
    assert!(option.writer.is_some(), ENotAuthorized);
    
    let buyer = option::borrow(&option.buyer);
    assert!(*buyer == tx_context::sender(ctx), ENotAuthorized);
    
    let option_id = covered_put_option::get_id(option);
    
    // Remove from active orders
    let index = vector::index_of(&user_orders.active_orders, &option_id);
    if (index != -1) {
        vector::remove(&mut user_orders.active_orders, (index as u64));
    };
    
    // Add to exercised orders
    vector::push_back(&mut user_orders.exercised_orders, option_id);
}

/// Cancel an unfilled covered put option
public fun cancel_option<CoinType>(
    user_orders: &mut UserOrders,
    orderbook: &mut OrderBook,
    market: &mut Market<CoinType>,
    option: &mut CoveredPutOption<CoinType>,
    ctx: &mut TxContext
) {
    assert!(
        option.status == covered_put_option::status_pending_buyer() ||
        option.status == covered_put_option::status_pending_writer(),
        EInvalidStatus
    );
    
    let sender = tx_context::sender(ctx);
    if (option.buyer.is_some()) {
        let buyer = option::borrow(&option.buyer);
        assert!(*buyer == sender, ENotAuthorized);
    } else if (option.writer.is_some()) {
        let writer = option::borrow(&option.writer);
        assert!(*writer == sender, ENotAuthorized);
    };
    
    let option_id = covered_put_option::get_id(option);
    
    // Remove from pending orders
    let index = vector::index_of(&user_orders.pending_orders, &option_id);
    if (index != -1) {
        vector::remove(&mut user_orders.pending_orders, (index as u64));
    };
}

/// Reclaim collateral and premium from expired covered put option
public fun reclaim_from_expired<CoinType>(
    user_orders: &mut UserOrders,
    market: &mut Market<CoinType>,
    option: &mut CoveredPutOption<CoinType>,
    ctx: &mut TxContext
) {
    assert!(option.status == covered_put_option::status_expired(), EInvalidStatus);
    
    let sender = tx_context::sender(ctx);
    if (option.buyer.is_some()) {
        let buyer = option::borrow(&option.buyer);
        assert!(*buyer == sender, ENotAuthorized);
    } else if (option.writer.is_some()) {
        let writer = option::borrow(&option.writer);
        assert!(*writer == sender, ENotAuthorized);
    };
    
    let option_id = covered_put_option::get_id(option);
    
    // Remove from active orders
    let index = vector::index_of(&user_orders.active_orders, &option_id);
    if (index != -1) {
        vector::remove(&mut user_orders.active_orders, (index as u64));
    };
    
    // Add to expired orders
    vector::push_back(&mut user_orders.expired_orders, option_id);
}

/// List a covered put option for secondary market sale
public fun list_for_secondary_market<CoinType>(
    user_orders: &mut UserOrders,
    orderbook: &mut OrderBook,
    market: &mut Market<CoinType>,
    option: &mut CoveredPutOption<CoinType>,
    asking_price: u64,
    ctx: &mut TxContext
) {
    assert!(option.status == covered_put_option::status_active(), EInvalidStatus);
    
    let sender = tx_context::sender(ctx);
    if (option.buyer.is_some()) {
        let buyer = option::borrow(&option.buyer);
        assert!(*buyer == sender, ENotAuthorized);
    } else if (option.writer.is_some()) {
        let writer = option::borrow(&option.writer);
        assert!(*writer == sender, ENotAuthorized);
    };
    
    let option_id = covered_put_option::get_id(option);
    
    // Remove from active orders
    let index = vector::index_of(&user_orders.active_orders, &option_id);
    if (index != -1) {
        vector::remove(&mut user_orders.active_orders, (index as u64));
    };
    
    // Add to secondary market orders
    vector::push_back(&mut user_orders.secondary_market_orders, option_id);
}

/// Cancel a covered put option from secondary market
public fun cancel_from_secondary_market<CoinType>(
    user_orders: &mut UserOrders,
    orderbook: &mut OrderBook,
    market: &mut Market<CoinType>,
    option: &mut CoveredPutOption<CoinType>,
    ctx: &mut TxContext
) {
    assert!(option.status == covered_put_option::status_for_sale(), EInvalidStatus);
    
    let sender = tx_context::sender(ctx);
    if (option.buyer.is_some()) {
        let buyer = option::borrow(&option.buyer);
        assert!(*buyer == sender, ENotAuthorized);
    } else if (option.writer.is_some()) {
        let writer = option::borrow(&option.writer);
        assert!(*writer == sender, ENotAuthorized);
    };
    
    let option_id = covered_put_option::get_id(option);
    
    // Remove from secondary market orders
    let index = vector::index_of(&user_orders.secondary_market_orders, &option_id);
    if (index != -1) {
        vector::remove(&mut user_orders.secondary_market_orders, (index as u64));
    };
    
    // Add back to active orders
    vector::push_back(&mut user_orders.active_orders, option_id);
}

/// Buy a covered put option from secondary market
public fun buy_from_secondary_market<CoinType>(
    user_orders: &mut UserOrders,
    orderbook: &mut OrderBook,
    market: &mut Market<CoinType>,
    option: &mut CoveredPutOption<CoinType>,
    payment_coin: Coin<CoinType>,
    ctx: &mut TxContext
) {
    assert!(option.status == covered_put_option::status_for_sale(), EInvalidStatus);
    assert!(option.listed_price.is_some(), EInvalidTradePrice);
    
    let listed_price = option::borrow(&option.listed_price);
    let payment_amount = coin::value(&payment_coin);
    assert!(payment_amount == *listed_price, EInvalidTradePrice);
    
    let option_id = covered_put_option::get_id(option);
    
    // Add to active orders
    vector::push_back(&mut user_orders.active_orders, option_id);
}
