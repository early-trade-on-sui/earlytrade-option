#[test_only]
module earlytrade::tests;

use earlytrade::test_coin::{Self, TEST_COIN};
use usdc::usdc::{Self, USDC};
use sui::sui::{Self, SUI};
use sui::test_scenario::{Self, Scenario};
use earlytrade::earlytrade::{Self, AdminCap};
use std::string;
use sui::clock;

const ADMIN: address = @0x1;
const BUYER: address = @0x2;
const WRITER: address = @0x3;




#[test]
public fun setup(): Scenario {
    // step 1 publish the package by admin wallet
    let mut scenario = test_scenario::begin(ADMIN);
    let mut clock = clock::create_for_testing(scenario.ctx());
    earlytrade::init_for_testing(scenario.ctx());

    // step 2 initialize an orderbook
    scenario.next_tx(ADMIN);{
        let admin_cap = scenario.take_from_sender<AdminCap>();
        let orderbook_name = string::utf8(b"test_orderbook");
        earlytrade::init_orderbook(orderbook_name, &admin_cap, &clock, scenario.ctx());
    };
    
    // step 3 Create TEST_COIN - USDC Market
    scenario.next_tx(ADMIN);{
        let admin_cap = scenario.take_from_sender<AdminCap>();
        let test_coin = TEST_COIN {};
        test_coin::init(test_coin, scenario.ctx());
    };
    
    
    scenario
}





