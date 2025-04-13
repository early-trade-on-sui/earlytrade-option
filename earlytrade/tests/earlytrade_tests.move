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
use sui::coin::{Self, Coin};

const ADMIN: address = @0x1;
const BUYER: address = @0x2;
const WRITER: address = @0x3;
const ONE_DAY_IN_MS: u64 = 24 * 60 * 60 * 1000;
const USDC_DECIMALS: u64 = 1_000_000;
const PERCENTAGE_DIVISOR: u64 = 10_000;





public fun setup(): (Scenario, Clock) {
    // step 1 publish the package by admin wallet
    let mut scenario = test_scenario::begin(ADMIN);
    let mut clock = clock::create_for_testing(scenario.ctx());
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

        earlytrade::create_market<USDC>(&admin_cap, market_name ,  &mut orderbook, &clock, trading_fee_percentage, scenario.ctx());
    
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
public fun test_place_order(): (Scenario, Clock) {
    let (mut scenario, mut clock) = setup();

    clock::increment_for_testing(&mut clock, ONE_DAY_IN_MS);



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
        let premium_value:u64 = 5_000;
        let collateral_value:u64    = 5_000;
        let amount:u64 = 1;
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




