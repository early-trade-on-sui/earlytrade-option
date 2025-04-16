#[test_only]
module earlytrade::tests;

use earlytrade::test_coin::{Self, TEST_COIN};
use usdc::usdc::{Self, USDC};
use sui::sui::{Self, SUI};
use sui::test_scenario::{Self, Scenario};
use earlytrade::earlytrade::{Self, AdminCap, OrderBook, Market};
use std::string;
use sui::clock::{Self, Clock};
use earlytrade::user::{Self, UserOrders};
use earlytrade::covered_put_option::{Self, CoveredPutOption};
use sui::coin::{Self, Coin};

const ADMIN: address = @0x1;
const BUYER: address = @0x2;
const WRITER: address = @0x3;
const ONE_DAY_IN_MS: u64 = 24 * 60 * 60 * 1000;
const USDC_DECIMALS: u64 = 1_000_000;
const PERCENTAGE_DIVISOR: u64 = 10_000;
const MINIMUM_TRADING_VALUE: u64 = 5 * USDC_DECIMALS;





public fun setup(): (Scenario, Clock) {
    // step 1 publish the package by admin wallet
    let mut scenario = test_scenario::begin(ADMIN);
    let clock = clock::create_for_testing(scenario.ctx());
    earlytrade::init_for_testing(scenario.ctx());

    // step 2 initialize an orderbook
    scenario.next_tx(ADMIN);{
        let admin_cap = scenario.take_from_sender<AdminCap>();
        let orderbook_name = string::utf8(b"test_orderbook");
        earlytrade::init_orderbook(orderbook_name, &admin_cap, &clock, scenario.ctx());
        test_scenario::return_to_sender(&scenario, admin_cap);
    };
    
    // step 3 Create TEST_COIN - USDC Market
    scenario.next_tx(ADMIN);{
        let admin_cap = scenario.take_from_sender<AdminCap>();
        let market_name = string::utf8(b"test_usdc_market");
        let mut orderbook = scenario.take_shared<OrderBook>();
        let trading_fee_percentage = 100;

        earlytrade::create_market<USDC>(&admin_cap, market_name ,  &mut orderbook, &clock, trading_fee_percentage, MINIMUM_TRADING_VALUE, scenario.ctx());
    
        test_scenario::return_shared(orderbook);
        test_scenario::return_to_sender(&scenario, admin_cap);
    };

    // step4 init user orders
    scenario.next_tx(BUYER);{
        let orderbook = scenario.take_shared<OrderBook>();
        user::init_user_orders(&orderbook, scenario.ctx());
        test_scenario::return_shared(orderbook);
    };

    // step5 init user orders for writer
    scenario.next_tx(WRITER);{
        let orderbook = scenario.take_shared<OrderBook>();
        user::init_user_orders(&orderbook, scenario.ctx());
        test_scenario::return_shared(orderbook);
    };
    
    (scenario, clock)
}


#[test]
public fun test_buyer_place_order(): (Scenario, Clock) {
    let (mut scenario, clock) = setup();



    scenario.next_tx(BUYER);{

        // initialize a user ordder
        let mut orderbook = scenario.take_shared<OrderBook>();
        // take user orders from the sender
        let mut user_orders = scenario.take_from_sender<UserOrders>();
        
        // Get the market
        let mut market = scenario.take_shared<Market<USDC>>();
        
        // if we set strike price is 0.01 usdc/test coin, then the strike price is 10_000
        // premium_value is 0.005 usdc, then the premium_value is 5000
        // then the collateral_value is 10000 - 5000 = 5000
        let premium_value:u64 = 5_000_000_000;
        let collateral_value:u64    = 5_000_000_000;
        let amount:u64 = 1_000_000;
        let strike_price:u64 = 10_000;

        let fee_paid_by_buyer = strike_price * amount * market.get_fee_rate()/PERCENTAGE_DIVISOR;
        let premium_coin = coin::mint_for_testing<USDC>(premium_value +fee_paid_by_buyer, scenario.ctx());
        
        // Create option as buyer
        user::create_option_as_buyer<USDC>(
            &mut user_orders,
            &mut orderbook,
            &mut market,
            strike_price,
            premium_value,
            collateral_value,
            amount,
            premium_coin,
            &clock,
            scenario.ctx()
        );
        
        // Return objects to the scenario
        test_scenario::return_shared(market);
        test_scenario::return_shared(orderbook);
        
        // return user orders to the sender
       test_scenario::return_to_sender(&scenario, user_orders);
    };




    (scenario, clock)
}


// test writer place order
#[test]
public fun test_writer_place_order(): (Scenario, Clock) {
    let (mut scenario, clock) = setup();


    scenario.next_tx(WRITER);{
        let mut user_orders = scenario.take_from_sender<UserOrders>();
        let mut orderbook = scenario.take_shared<OrderBook>();
        let mut market = scenario.take_shared<Market<USDC>>();
        
        // get the option
        let premium_value:u64 = 5_000_000_000;
        let collateral_value:u64    = 5_000_000_000;
        let amount:u64 = 1_000_000;
        let strike_price:u64 = 10_000;

        let fee_paid_by_buyer = strike_price * amount * market.get_fee_rate()/PERCENTAGE_DIVISOR;
        let collateral_coin = coin::mint_for_testing<USDC>(premium_value +fee_paid_by_buyer, scenario.ctx());
        
        // cancel the option
        user::create_option_as_writer<USDC>(
            &mut user_orders,
            &mut orderbook,
            &mut market,
            strike_price,
            premium_value,
            collateral_value,
            amount,
            
            &clock, collateral_coin, scenario.ctx());

        // return objects to the scenario
        test_scenario::return_shared(market);
        test_scenario::return_shared(orderbook);
        test_scenario::return_to_sender(&scenario, user_orders);
    };

    (scenario, clock)
}

// test cancel option
#[test]
public fun test_buyer_cancel_option(): (Scenario, Clock) {
    let (mut scenario, clock) = test_buyer_place_order();


    scenario.next_tx(BUYER);{
        let mut user_orders = scenario.take_from_sender<UserOrders>();
        let mut orderbook = scenario.take_shared<OrderBook>();
        let mut market = scenario.take_shared<Market<USDC>>();
 
        let option = scenario.take_shared<CoveredPutOption<USDC>>();
        
        // cancel the option
        let return_coin = user::cancel_option<USDC>(
            &mut user_orders,
            &mut orderbook,
            &mut market, option, scenario.ctx());
        
        std::debug::print(&return_coin.value());

        transfer::public_transfer(return_coin, scenario.ctx().sender());

        // return objects to the scenario
        test_scenario::return_shared(market);
        test_scenario::return_shared(orderbook);
        test_scenario::return_to_sender(&scenario, user_orders);
    };
    
    (scenario, clock)
}

#[test]
public fun test_writer_cancel_option(): (Scenario, Clock) {
    let (mut scenario, clock) = test_writer_place_order();

    
    scenario.next_tx(WRITER);{
        let mut user_orders = scenario.take_from_sender<UserOrders>();
        let mut orderbook = scenario.take_shared<OrderBook>();
        let mut market = scenario.take_shared<Market<USDC>>();
        
        let option = scenario.take_shared<CoveredPutOption<USDC>>();

        // cancel the option
        let return_coin = user::cancel_option<USDC>(
            &mut user_orders,
            &mut orderbook,
            &mut market, option, scenario.ctx());

        std::debug::print(&return_coin.value());

        transfer::public_transfer(return_coin, scenario.ctx().sender());

        // return objects to the scenario
        test_scenario::return_shared(market);
        test_scenario::return_shared(orderbook);
        test_scenario::return_to_sender(&scenario, user_orders);
    };

    (scenario, clock)
}

// test buyer fill order 
#[test]
public fun test_buyer_fill_order(): (Scenario, Clock) {
    let (mut scenario, clock) = test_writer_place_order();

    scenario.next_tx(BUYER);{
        let mut user_orders = scenario.take_from_sender<UserOrders>();
        let mut orderbook = scenario.take_shared<OrderBook>();
        let mut market = scenario.take_shared<Market<USDC>>();

        let mut option = scenario.take_shared<CoveredPutOption<USDC>>();

        let strike_price = option.get_strike_price();
        let amount = option.get_underlying_asset_amount();

        let fee_paid_by_buyer = strike_price * amount * market.get_fee_rate()/PERCENTAGE_DIVISOR;
        let premium_value = option.get_premium();

        // fill the order
        // create premium coin
        let premium_coin = coin::mint_for_testing<USDC>(fee_paid_by_buyer+premium_value, scenario.ctx());
        
        // fill the option as buyer
        user::fill_option_as_buyer<USDC>(
            &mut user_orders,
            &mut orderbook,
            &mut market,
            &mut option,
            &clock,
            premium_coin,
            scenario.ctx()
        );
        // return objects to the scenario
        test_scenario::return_shared(option);
        test_scenario::return_shared(market);
        test_scenario::return_shared(orderbook);
        test_scenario::return_to_sender(&scenario, user_orders);
    };

    (scenario, clock)
}


#[test]
// test writer fill order
public fun test_writer_fill_order(): (Scenario, Clock) {
    let (mut scenario, clock) = test_buyer_place_order();

    
    scenario.next_tx(WRITER);{
        let mut user_orders = scenario.take_from_sender<UserOrders>();
        let mut orderbook = scenario.take_shared<OrderBook>();
        let mut market = scenario.take_shared<Market<USDC>>();

        let mut option = scenario.take_shared<CoveredPutOption<USDC>>();

        let strike_price = option.get_strike_price();
        let amount = option.get_underlying_asset_amount();

        let fee_paid_by_buyer = strike_price * amount * market.get_fee_rate()/PERCENTAGE_DIVISOR;
        let collateral_value = option.get_collateral_value();

        // fill the order
        // create premium coin
        let collateral_coin = coin::mint_for_testing<USDC>(fee_paid_by_buyer+collateral_value, scenario.ctx());
        
        // fill the option as buyer
        user::fill_option_as_writer<USDC>(
            &mut user_orders,
            &mut orderbook,
            &mut market,
            &mut option,
            &clock,
            collateral_coin,
            scenario.ctx()
        );
        // return objects to the scenario
        test_scenario::return_shared(option);
        test_scenario::return_shared(market);
        test_scenario::return_shared(orderbook);
        test_scenario::return_to_sender(&scenario, user_orders);
    };

    (scenario, clock)
}

// test add exercise date and expiration date
#[test]
public fun test_add_exercise_date_and_expiration_date(): (Scenario, Clock) {
    let (mut scenario, clock) = test_buyer_fill_order();

    scenario.next_tx(ADMIN);{
        let admin_cap = scenario.take_from_sender<AdminCap>();
        let mut market = scenario.take_shared<Market<USDC>>();
        earlytrade::set_exericse_expiration_date(
            &mut market,
            &admin_cap,
            &clock, 7*ONE_DAY_IN_MS, 8*ONE_DAY_IN_MS, scenario.ctx());

        test_scenario::return_shared(market);
        test_scenario::return_to_sender(&scenario, admin_cap);
    };

    (scenario, clock)
}

// test add settlemnt coin and decimal
#[test]
public fun test_add_settlement_coin_and_decimal(): (Scenario, Clock) {
    let (mut scenario, clock) = test_add_exercise_date_and_expiration_date();

    // create a test coin for test
    scenario.next_tx(ADMIN);{
        test_coin::test_init(scenario.ctx());

    };

    scenario.next_tx(ADMIN);{
        let admin_cap = scenario.take_from_sender<AdminCap>();
        let mut market = scenario.take_shared<Market<USDC>>();
        earlytrade::set_underlying_asset_type_and_decimal<TEST_COIN, USDC>(
            &mut market,
            &admin_cap,
            7,
            scenario.ctx()
        );

        test_scenario::return_shared(market);
        test_scenario::return_to_sender(&scenario, admin_cap);
    };

    (scenario, clock)
}
// test buyer exercise option
#[test]
public fun test_buyer_exercise_option() {
    let (mut scenario, mut clock) = test_add_settlement_coin_and_decimal();

    clock::increment_for_testing(&mut clock, 7*ONE_DAY_IN_MS+1000);

    scenario.next_tx(BUYER);{
        let market = scenario.take_shared<Market<USDC>>();
        let mut option = scenario.take_shared<CoveredPutOption<USDC>>();
        let mut orderbook = scenario.take_shared<OrderBook>();


        let amount = option.get_underlying_asset_amount();

        let underlying_asset = coin::mint_for_testing<TEST_COIN>( amount* 10_000_000, scenario.ctx());

        user::buyer_exercise_option<TEST_COIN, USDC>(
            &mut option,
            &mut orderbook, 
            underlying_asset, 
            & market, 
            & clock, 
            scenario.ctx()
        );


        test_scenario::return_shared(option);
        test_scenario::return_shared(market);
        test_scenario::return_shared(orderbook);
    };


    clock::destroy_for_testing(clock);
    scenario.end();
}



// test writer reclaim collateral after expiration
#[test]
public fun test_writer_reclaim_collateral_after_expiration() {
    let (mut scenario, mut clock) = test_add_settlement_coin_and_decimal();

    clock::increment_for_testing(&mut clock, 8*ONE_DAY_IN_MS+1000);
    
    scenario.next_tx(WRITER);{
        let mut option = scenario.take_shared<CoveredPutOption<USDC>>();
        let mut orderbook = scenario.take_shared<OrderBook>();
        let market = scenario.take_shared<Market<USDC>>();

        user::seller_take_back_premium_and_collateral<USDC>(
            &mut option, &mut orderbook, & market, &clock, scenario.ctx());

        test_scenario::return_shared(option);
        test_scenario::return_shared(market);
        test_scenario::return_shared(orderbook);
    };

    clock::destroy_for_testing(clock);
    scenario.end();
}



// withdraw fees as admin
#[test]
public fun test_withdraw_fees_as_admin() {
    let (mut scenario, clock) = test_writer_fill_order();


    scenario.next_tx(ADMIN);{
        let admin_cap = scenario.take_from_sender<AdminCap>();
        let mut market = scenario.take_shared<Market<USDC>>();
        
        // withdraw fees
        let fee_coin = earlytrade::withdraw_fees<USDC>(
            &mut market,
            &admin_cap,
            scenario.ctx()
        );

        std::debug::print(&fee_coin.value());

        transfer::public_transfer(fee_coin, scenario.ctx().sender());

        scenario.return_to_sender(admin_cap);

        // return objects to the scenario
        test_scenario::return_shared(market);
    };

    clock::destroy_for_testing(clock);
    scenario.end();
}