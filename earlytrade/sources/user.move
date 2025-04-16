module earlytrade::user;

use sui::balance;
use sui::coin::{Coin};
use sui::event;
use std::string;
use std::type_name;
use sui::clock::Clock;
use sui::table::{Self, Table};
use earlytrade::earlytrade::{Self, Market, OrderBook};
use earlytrade::covered_put_option::{Self, CoveredPutOption, OptionInfo};
use std::u64;

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
const EOptionNotActive: u64 = 11;
const EOptionNotMatched: u64 = 12;
const EOptionNotExercisable: u64 = 13;
const EOptionNotExpired: u64 = 14;
const EInsufficientUnderlyingAsset: u64 = 15;
const EInvalidOption: u64 = 16;
const EInsufficientTradingValue: u64 = 17;

// ====== Core Data Structures ======

public struct UserOrders has key {
    id: UID,
    owner: address,
    orderbook_id: ID,
    maker_order_id_tracker: Table<ID, OptionInfo>,
    taker_order_id_tracker: Table<ID, OptionInfo>,
}

// ======== Event Structs ========
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

public struct OptionExercisedEvent has copy, drop {
    option_id: ID,
    buyer: address,
    writer: address,
    strike_price: u64,
    premium_value: u64,
    collateral_value: u64,
    amount: u64,
    market_id: ID,
}

public struct OptionExpiredEvent has copy, drop {
    option_id: ID,
    buyer: address,
    writer: address,
    strike_price: u64,
    premium_value: u64,
    collateral_value: u64,
    amount: u64,
    market_id: ID,
}

public struct UserOrdersInitializedEvent has copy, drop {
    user_orders_id: ID,
    owner: address,
    orderbook_id: ID,
}

// ====== Public Functions ======

/// Initialize user orders for a new user
public fun init_user_orders(orderbook: &OrderBook, ctx: &mut TxContext){
    let user_orders = UserOrders {
        id: object::new(ctx),
        owner: ctx.sender(),
        orderbook_id: orderbook.get_orderbook_id(),
        maker_order_id_tracker: table::new<ID, OptionInfo>(ctx),
        taker_order_id_tracker: table::new<ID, OptionInfo>(ctx),
    };


    // Emit event for user orders initialization
    event::emit(UserOrdersInitializedEvent {
        user_orders_id: object::id(&user_orders),
        owner: ctx.sender(),
        orderbook_id: orderbook.get_orderbook_id(),
    });

    transfer::transfer(user_orders, ctx.sender());
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

    // assert the premium_balance.value is same as premium_value
    assert!(premium_balance.value() == premium_value, EInvalidOption);
    // check if the trading value is enough to trade

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
    table::add(&mut user_orders.maker_order_id_tracker, option.get_id(), covered_put_option::get_option_info(&option));
    // push the option id into the orderbook
    earlytrade::push_covered_put_option_id_into_waiting_writer(orderbook, &option);


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
    let writer = option::some(ctx.sender());
    let buyer = option::none();

    // assert the collateral_balance.value is same as collateral_value
    assert!(collateral_balance.value() == collateral_value, EInvalidOption);
    // check if the trading value is enough to trade
    assert!(earlytrade::is_trading_value_enough(market, collateral_balance.value()), EInsufficientTradingValue);



    let premium_balance = balance::zero<TradingCoinType>();
    let market_id = market.get_market_id();
    let creator_is_buyer = false;

    let option = covered_put_option::new_option<TradingCoinType>(
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
    table::add(&mut user_orders.maker_order_id_tracker, option.get_id(), covered_put_option::get_option_info(&option));

    // push the option id into the orderbook
    earlytrade::push_covered_put_option_id_into_waiting_buyer(orderbook, &option);


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
    table::remove(&mut user_orders.maker_order_id_tracker, option.get_id());

    // Emit event for option cancellation
    event::emit(OptionCancelledEvent {
        option_id: option.get_id(),
        canceller: ctx.sender(),
        market_id: market.get_market_id(),
    });

    let fee_paid_by_buyer = option.get_fee_paid_by_buyer();
    let fee_paid_by_writer = option.get_fee_paid_by_writer();
    let mut withdraw_balance = balance::zero<TradingCoinType>();
    let mut return_fee = balance::zero<TradingCoinType>();

    if (option.get_status() == covered_put_option::status_waiting_buyer()) {
        // this is the a covered put option seller
        // pop up the option id from the orderbook
        earlytrade::pop_covered_put_option_id_from_waiting_buyer(orderbook, &option);
        return_fee.join( earlytrade::return_fee(market, fee_paid_by_writer));
        
    } else if (option.get_status() == covered_put_option::status_waiting_writer()) {
        // pop up the option id from the orderbook
        earlytrade::pop_covered_put_option_id_from_waiting_writer(orderbook, &option);
        return_fee.join(earlytrade::return_fee(market, fee_paid_by_buyer));        
    };

    let ( premium_balance, collateral_balance) = covered_put_option::destroy_option<TradingCoinType>(option);

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
    let option_amount = option.get_underlying_asset_amount();

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
    table::add(&mut user_orders.taker_order_id_tracker, option_id, covered_put_option::get_option_info(option));
    // pop up the option id from the orderbook
    earlytrade::pop_covered_put_option_id_from_waiting_buyer(orderbook, option);
    // push the option id into the orderbook
    earlytrade::push_covered_put_option_id_into_active(orderbook, option);
    
    // Emit event for option fill
    event::emit(OptionFilledEvent {
        option_id,
        buyer: ctx.sender(),
        writer: option::extract(&mut option.get_writer()),
        strike_price: option.get_strike_price(),
        premium_value: option.get_premium(),
        amount: option.get_underlying_asset_amount(),
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

    // check the market is active
    assert!(earlytrade::is_market_active(clock, market), EMarketNotActive);
    
    let option_id = option.get_id();
    let option_strike_price = option.get_strike_price();
    let option_collateral_amount = option.get_collateral_value();
    let option_amount = option.get_underlying_asset_amount();

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
    table::add(&mut user_orders.taker_order_id_tracker, option_id, covered_put_option::get_option_info(option));
    // pop up the option id from the orderbook
    earlytrade::pop_covered_put_option_id_from_waiting_writer(orderbook, option);
    // push the option id into the orderbook
    earlytrade::push_covered_put_option_id_into_active(orderbook, option);

    // Emit event for option fill
    event::emit(OptionFilledEvent {
        option_id,
        buyer: option::extract(&mut option.get_buyer()),
        writer: ctx.sender(),
        strike_price: option.get_strike_price(),
        premium_value: option.get_premium(),
        amount: option.get_underlying_asset_amount(),
        market_id: market.get_market_id(),
    });
}

// exericese option
public fun buyer_exercise_option<UnderlyingAssetType, TradingCoinType>(
    option: &mut CoveredPutOption<TradingCoinType>, 
    orderbook: &mut OrderBook, 
    underlying_asset: Coin<UnderlyingAssetType>,
    market: &Market<TradingCoinType>, 
    clock: &Clock, 
    ctx: &mut TxContext) {

    // check option status and is matched
    assert!(option.get_status() == covered_put_option::status_matched(), EOptionNotActive);
    assert!(*option::borrow(&option.get_buyer()) == ctx.sender(), ENotAuthorized);
    assert!(option.get_writer().is_some(), EOptionNotMatched);

    // update the orderbook move option id from the active to the exercised
    earlytrade::pop_covered_put_option_id_from_active(orderbook, option);
    earlytrade::push_covered_put_option_id_into_exercised(orderbook, option);

    // check if the option is able to be exercised
    assert!(earlytrade::is_option_exercisable<TradingCoinType>(market, clock), EOptionNotExercisable);

    let underlying_asset_type = string::from_ascii(*type_name::borrow_string(&type_name::get<UnderlyingAssetType>()));
    // check if the underlying assets is alinged with the market config
    earlytrade::assert_underlying_asset_aligned<TradingCoinType>(market, underlying_asset_type);
    
    // check if the underlying asset amount is enough to exercise the option
    let required_underlying_asset_value = option.get_underlying_asset_amount() * u64::pow(10, earlytrade::get_underlying_asset_decimal<TradingCoinType>(market));
    assert!(underlying_asset.value() >= required_underlying_asset_value, EInsufficientUnderlyingAsset);

    std::debug::print(&underlying_asset.value());
    // transfer the the underlying assets to the seller
    transfer::public_transfer(underlying_asset, *option::borrow(&option.get_writer()));

    // take the premium and collateral balance from the option
    let mut premium_collateral_balance = option.withdraw_premium();
    premium_collateral_balance.join(option.withdraw_collateral());

    std::debug::print(&premium_collateral_balance.value());
    // transfer the premium and collateral balance to the seller
    transfer::public_transfer(premium_collateral_balance.into_coin(ctx), *option::borrow(&option.get_writer()));

    // set the option status to exercised
    option.set_status(clock, covered_put_option::status_exercised());

    // Emit event for option exercise
    event::emit(OptionExercisedEvent {
        option_id: option.get_id(),
        buyer: *option::borrow(&option.get_buyer()),
        writer: *option::borrow(&option.get_writer()),
        strike_price: option.get_strike_price(),
        premium_value: option.get_premium(),
        collateral_value: option.get_collateral_value(),
        amount: option.get_underlying_asset_amount(),
        market_id: market.get_market_id(),
    });
}

// seller take back premium and collateral balance from the expired option
public fun seller_take_back_premium_and_collateral<TradingCoinType>(
    option: &mut CoveredPutOption<TradingCoinType>, 
    orderbook: &mut OrderBook, 
    market: &Market<TradingCoinType>, 
    clock: &Clock, 
    ctx: &mut TxContext) {
    
    // check option status and is matched
    assert!(option.get_status() == covered_put_option::status_matched(), EOptionNotExpired);
    assert!(option.get_buyer().is_some(), EOptionNotMatched);
    assert!(*option::borrow(&option.get_writer()) == ctx.sender(), ENotAuthorized);
    
    // update the orderbook move option id from the active to the expired
    earlytrade::pop_covered_put_option_id_from_active(orderbook, option);
    earlytrade::push_covered_put_option_id_into_expired(orderbook, option);
    
    // check if the option is expired
    assert!(earlytrade::is_option_expired<TradingCoinType>(market, clock), EOptionNotExpired);

    // take the premium and collateral balance from the option
    let mut premium_collateral_balance = option.withdraw_premium();
    premium_collateral_balance.join(option.withdraw_collateral());

    std::debug::print(&premium_collateral_balance.value());
    // transfer the premium and collateral balance to the seller
    transfer::public_transfer(premium_collateral_balance.into_coin(ctx), *option::borrow(&option.get_writer()));

    // set the option status to expired
    option.set_status(clock, covered_put_option::status_expired());

    // Emit event for option expiration
    event::emit(OptionExpiredEvent {
        option_id: option.get_id(),
        buyer: *option::borrow(&option.get_buyer()),
        writer: *option::borrow(&option.get_writer()),
        strike_price: option.get_strike_price(),
        premium_value: option.get_premium(),
        collateral_value: option.get_collateral_value(),
        amount: option.get_underlying_asset_amount(),
        market_id: market.get_market_id(),
    });
}