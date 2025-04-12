module earlytrade::user;

use sui::balance;
use sui::coin::{Coin};
use sui::event;
use sui::clock::Clock;

use earlytrade::earlytrade::{Self, Market, OrderBook};
use earlytrade::covered_put_option::{Self, CoveredPutOption};

// ====== Constants ======

const PERCENTAGE_DIVISOR: u64 = 10_000;

// Error codes
const ENotAuthorized: u64 = 0;
const EInvalidAmount: u64 = 1;
const EInvalidStatus: u64 = 2;
const EAlreadyMatched: u64 = 3;
const EInsufficientCollateral: u64 = 6;
const EInsufficientPremium: u64 = 7;
const EMarketNotActive: u64 = 8;
const EInvalidStrikePrice: u64 = 9;
const EOptionNotFound: u64 = 10;

// ====== Core Data Structures ======

public struct UserOrders has key {
    id: UID,
    owner: address,
    orderbook_id: ID,
    maker_order_id_tracker: vector<ID>,
    taker_order_id_tracker: vector<ID>,
}

// ====== Public Functions ======

/// Initialize user orders for a new user
public fun init_user_orders(orderbook: &OrderBook, ctx: &mut TxContext): UserOrders {
    UserOrders {
        id: object::new(ctx),
        owner: ctx.sender(),
        orderbook_id: orderbook.get_orderbook_id(),
        maker_order_id_tracker: vector::empty(),
        taker_order_id_tracker: vector::empty(),
    }
}

/// Create a covered put option as a buyer
public fun create_option_as_buyer<TradingCoinType>(
    user_orders: &mut UserOrders,
    orderbook: &mut OrderBook,
    market: &mut Market<TradingCoinType>,
    strike_price: u64, // the strike price of the option
    premium_value: u64, // the premium of the option
    collateral_value: u64, // the collateral of the option
    amount: u64, // amount of the underlying assets
    premium_coin: Coin<TradingCoinType>,
    clock: &Clock,
    ctx: &mut TxContext
) {
    // check if the market is active
    assert!(earlytrade::is_market_active(clock, market), EMarketNotActive);

    // check if the strike price is valid
    assert!(strike_price > 0, EInvalidStrikePrice);

    // check if the amount is valid
    assert!(amount > 0, EInvalidAmount);

    // handle the fee logic
    let fee_paid_by_buyer = strike_price * amount * market.get_fee_rate()/PERCENTAGE_DIVISOR;
    let mut premium_balance = premium_coin.into_balance();

    
    // charge the fee to the fee balance first, leave the remaining premium balance
    earlytrade::charge_fee(market, premium_balance.split(fee_paid_by_buyer));


    let fee_paid_by_writer = 0;
    let status = covered_put_option::status_waiting_writer();
    let buyer = option::some(ctx.sender());
    let writer = option::none();
    let collateral_balance = balance::zero<TradingCoinType>();
    let market_id = market.get_market_id();
    let creator_is_buyer = true;

    let option = covered_put_option::new_option(
    strike_price,
    premium_value,
    collateral_value,
    amount,
    fee_paid_by_buyer,
    fee_paid_by_writer,
    status,
    buyer,
    writer,
    premium_balance,
    collateral_balance,
    market_id,
    creator_is_buyer,
    ctx
    );

    // push the option into the waiting orders
    vector::push_back(&mut user_orders.maker_order_id_tracker, option.get_id());
    // push the option id into the orderbook
    earlytrade::push_covered_put_option_id_into_waiting_writer(orderbook, option.get_id());


    // Emit event for option creation
    event::emit(OptionCreatedEvent {
        option_id: option.get_id(),
        creator: ctx.sender(),
        strike_price,
        premium_value,
        collateral_value,
        amount,
        is_buyer: true,
        market_id,
    });

     // share the option
    covered_put_option::share_option(option);
}

/// Create a covered put option as a writer
public fun create_option_as_writer<TradingCoinType>(
    user_orders: &mut UserOrders,
    orderbook: &mut OrderBook,
    market: &mut Market<TradingCoinType>,
    strike_price: u64,
    premium_value: u64,
    collateral_value: u64,
    amount: u64,
    clock: &Clock,
    collateral_coin: Coin<TradingCoinType>,
    ctx: &mut TxContext
) {

    // check if the market is active
    assert!(earlytrade::is_market_active(clock, market), EMarketNotActive);
    // check if the strike price is valid
    assert!(strike_price > 0, EInvalidStrikePrice);

    // check if the amount is valid
    assert!(amount > 0, EInvalidAmount);

    // handle the fee logic
    let fee_paid_by_writer = strike_price * amount * market.get_fee_rate()/PERCENTAGE_DIVISOR;
    let mut collateral_balance = collateral_coin.into_balance();

    let fee_paid_by_buyer = 0;

    // charge the fee to the fee balance first, leave the remaining collateral balance
    earlytrade::charge_fee(market, collateral_balance.split(fee_paid_by_writer));

    let status = covered_put_option::status_waiting_buyer();
    let buyer = option::some(ctx.sender());
    let writer = option::none();

    let premium_balance = balance::zero<TradingCoinType>();
    let market_id = market.get_market_id();
    let creator_is_buyer = false;

    let option = covered_put_option::new_option(
    strike_price,
    premium_value,
    collateral_value,
    amount,
    fee_paid_by_buyer,
    fee_paid_by_writer,
    status,
    buyer,
    writer,
    premium_balance,
    collateral_balance,
    market_id,
    creator_is_buyer,
    ctx
    );
    // push the option into the waiting orders
    vector::push_back(&mut user_orders.maker_order_id_tracker, option.get_id());
    // push the option id into the orderbook
    earlytrade::push_covered_put_option_id_into_waiting_buyer(orderbook, option.get_id());


    // Emit event for option creation
    event::emit(OptionCreatedEvent {
        option_id: option.get_id(),
        creator: ctx.sender(),
        strike_price,
        premium_value,
        collateral_value,
        amount,
        is_buyer: false,
        market_id,
    });

    // share the option
    covered_put_option::share_option(option);
}

/// Cancel an unfilled covered put option
public fun cancel_option<TradingCoinType>(
    user_orders: &mut UserOrders,
    orderbook: &mut OrderBook,
    market: &mut Market<TradingCoinType>,
    option: CoveredPutOption<TradingCoinType>,
    ctx: &mut TxContext
): Coin<TradingCoinType> {
    // check if the option is waiting buyer or waiting writer
    assert!(option.get_status() == covered_put_option::status_waiting_buyer() || option.get_status() == covered_put_option::status_waiting_writer(), EInvalidStatus);

    // check if the option is matched
    assert!(option.get_buyer() == option::none() || option.get_writer() == option::none(), EAlreadyMatched);

    // assert ctx.sender() is the owner of the option
    assert!(ctx.sender() == option.get_creator_address(), ENotAuthorized);

    // pop up the option id from the waiting orders
    // Find the index of the option ID in the waiting orders vector
    let (found, index) = vector::index_of(&user_orders.maker_order_id_tracker, &option.get_id());
    
    // If the option ID is found, remove it from the vector
    if (found) {
        vector::remove(&mut user_orders.maker_order_id_tracker, index);
    } else {
        // Option ID not found in the waiting orders
        abort EOptionNotFound
    };

    // Emit event for option cancellation
    event::emit(OptionCancelledEvent {
        option_id: option.get_id(),
        canceller: ctx.sender(),
        market_id: market.get_market_id(),
    });

    let fee_paid_by_buyer = option.get_fee_paid_by_buyer();
    let fee_paid_by_writer = option.get_fee_paid_by_writer();
    let option_id = option.get_id();
    let mut withdraw_balance = balance::zero<TradingCoinType>();
    let mut return_fee = balance::zero<TradingCoinType>();

    let (status, premium_balance, collateral_balance) = covered_put_option::destroy_option<TradingCoinType>(option);

    if (status == covered_put_option::status_waiting_buyer()) {
        // this is the a covered put option seller
        // pop up the option id from the orderbook
        earlytrade::pop_covered_put_option_id_from_waiting_buyer(orderbook, option_id);
        return_fee.join( earlytrade::return_fee(market, fee_paid_by_writer));
        
    } else if (status == covered_put_option::status_waiting_writer()) {
        // pop up the option id from the orderbook
        earlytrade::pop_covered_put_option_id_from_waiting_writer(orderbook, option_id);
        return_fee.join(earlytrade::return_fee(market, fee_paid_by_buyer));        
    };

    withdraw_balance.join(collateral_balance);
    withdraw_balance.join(premium_balance);
    withdraw_balance.join(return_fee);

    let withdraw_coin = withdraw_balance.into_coin(ctx);



    withdraw_coin
}

/// Fill a covered put option as a buyer
public fun fill_option_as_buyer<CoinType>(
    user_orders: &mut UserOrders,
    orderbook: &mut OrderBook,
    market: &mut Market<CoinType>,
    option: &mut CoveredPutOption<CoinType>,
    clock: &Clock,
    premium_coin: Coin<CoinType>,
    ctx: &mut TxContext
) {
    // check if the option is waiting buyer
    assert!(option.get_status() == covered_put_option::status_waiting_buyer(), EInvalidStatus);


    // check the market is active
    assert!(earlytrade::is_market_active(clock, market), EMarketNotActive);
    
    let option_id = option.get_id();
    let option_strike_price = option.get_strike_price();
    let option_premium_value = option.get_premium();
    let option_amount = option.get_amount();

    // calculate the fee paid by the buyer
    let fee_paid_by_buyer = option_strike_price * option_amount * market.get_fee_rate()/PERCENTAGE_DIVISOR;
    let mut premium_balance = premium_coin.into_balance();

    // update the fee paid by the buyer
    covered_put_option::update_fee_paid_by_buyer(option, fee_paid_by_buyer);
    // charge fees
    earlytrade::charge_fee(market, premium_balance.split(fee_paid_by_buyer));

    // assert the premium balance is enough
    assert!(premium_balance.value() >= option_premium_value, EInsufficientPremium);

    // update the premium balance
    covered_put_option::add_premium_balance(option, premium_balance);
    
    // update option status
    covered_put_option::set_status(option, clock, covered_put_option::status_matched());
    // update the buyer
    covered_put_option::set_buyer(option, ctx.sender());

    // update user orders
    vector::push_back(&mut user_orders.taker_order_id_tracker, option_id);
    // pop up the option id from the orderbook
    earlytrade::pop_covered_put_option_id_from_waiting_buyer(orderbook, option_id);
    // push the option id into the orderbook
    earlytrade::push_covered_put_option_id_into_active(orderbook, option_id);
    
    // Emit event for option fill
    event::emit(OptionFilledEvent {
        option_id,
        buyer: ctx.sender(),
        writer: option::extract(&mut option.get_writer()),
        strike_price: option.get_strike_price(),
        premium_value: option.get_premium(),
        amount: option.get_amount(),
        market_id: market.get_market_id(),
    });
}

/// Fill a covered put option as a writer
public fun fill_option_as_writer<CoinType>(
    user_orders: &mut UserOrders,
    orderbook: &mut OrderBook,
    market: &mut Market<CoinType>,
    option: &mut CoveredPutOption<CoinType>,
    clock: &Clock,
    collateral_coin: Coin<CoinType>,
    ctx: &mut TxContext
) {
    // check if the option is waiting writer
    assert!(option.get_status() == covered_put_option::status_waiting_writer(), EInvalidStatus);

    // check if the option is matched
    assert!(option.get_writer() == option::some(ctx.sender()), ENotAuthorized);

    // check the market is active
    assert!(earlytrade::is_market_active(clock, market), EMarketNotActive);
    
    let option_id = option.get_id();
    let option_strike_price = option.get_strike_price();
    let option_collateral_amount = option.get_collateral_amount();
    let option_amount = option.get_amount();

    // calculate the fee paid by the writer
    let fee_paid_by_writer = option_strike_price * option_amount * market.get_fee_rate()/PERCENTAGE_DIVISOR;


    let mut collateral_balance = collateral_coin.into_balance();

    // update the fee paid by the writer
    covered_put_option::update_fee_paid_by_writer(option, fee_paid_by_writer);
    // charge fees
    earlytrade::charge_fee(market, collateral_balance.split(fee_paid_by_writer));

    // assert the collateral balance is enough
    assert!(collateral_balance.value() >= option_collateral_amount, EInsufficientCollateral);

    // update the collateral balance
    covered_put_option::add_collateral_balance(option, collateral_balance);
    
    // update option status
    covered_put_option::set_status(option, clock, covered_put_option::status_matched());
    // update the seller
    covered_put_option::set_writer(option, ctx.sender());

    // update user orders
    vector::push_back(&mut user_orders.taker_order_id_tracker, option_id);
    // pop up the option id from the orderbook
    earlytrade::pop_covered_put_option_id_from_waiting_writer(orderbook, option_id);
    // push the option id into the orderbook
    earlytrade::push_covered_put_option_id_into_active(orderbook, option_id);

    // Emit event for option fill
    event::emit(OptionFilledEvent {
        option_id,
        buyer: option::extract(&mut option.get_buyer()),
        writer: ctx.sender(),
        strike_price: option.get_strike_price(),
        premium_value: option.get_premium(),
        amount: option.get_amount(),
        market_id: market.get_market_id(),
    });
}

// Add event structs at the top of the file after the constants
public struct OptionCreatedEvent has copy, drop {
    option_id: ID,
    creator: address,
    strike_price: u64,
    premium_value: u64,
    collateral_value: u64,
    amount: u64,
    is_buyer: bool,
    market_id: ID,
}

public struct OptionCancelledEvent has copy, drop {
    option_id: ID,
    canceller: address,
    market_id: ID,
}

public struct OptionFilledEvent has copy, drop {
    option_id: ID,
    buyer: address,
    writer: address,
    strike_price: u64,
    premium_value: u64,
    amount: u64,
    market_id: ID,
}
