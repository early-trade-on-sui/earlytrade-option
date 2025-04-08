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
    use sui::coin::{Self, Coin};
    use sui::table::{Self, Table};
    use sui::event;

    use std::string::{Self, String};
    use sui::clock::Clock;
    use std::type_name::{Self, TypeName};
    
    // Import the option module
    use earlytrade::covered_put_option::{Self, CoveredPutOption};

    // ====== Constants ======
    

    // Error codes
    const ENotAuthorized: u64 = 0;
    const EInvalidAmount: u64 = 1;
    const EInvalidStatus: u64 = 2;
    const EAlreadyMatched: u64 = 3;
    const EOptionExpired: u64 = 4;
    const ETGENotSet: u64 = 5;
    const EInvalidPrice: u64 = 6;
    const EInvalidDate: u64 = 7;
    const ENotExercisable: u64 = 8;
    const EExercisePeriodEnded: u64 = 9;
    const EUnderlyingAssetNotSet: u64 = 10;
    const ENotTransferable: u64 = 11;
    const EInvalidTradePrice: u64 = 12;
    const EUnderlyingAssetNotAligned: u64 = 13;

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
        exercise_fee_percentage: u64,          // Exercise fee percentage (100 = 1%)
        
        // Administrator info
        fee_balance: Balance<TradingCoinType>,   // Accumulated fees for admin withdrawal
        
        // Market timeline
        creation_date: u64,                     // When market was created
        exericse_date: Option<u64>,                  // Token Generation Event date (if set)
        expiration_date: Option<u64>,         // Last date to exercise after TGE
        

        // After TGE
        underlying_asset_type: Option<String>,  // Address of underlying asset after TGE
        decimal: u8,
        
        // Trading metrics
        total_premium_volume: u64,              // Total premium volume traded
        total_collateral_volume: u64,           // Total collateral volume locked
        active_options_count: u64,              // Number of active options
        secondary_market_volume: u64,           // Volume of secondary market trades
    }


    /// serve as a indexer for all options
    /// 
    public struct OrderBook has key {
        // Object properties
        id: UID,                                // Unique object identifier
        name: String,                           // Name of the orderbook: WAV Premarket Orderbook, WAL Premarket Orderbook
        market_id: vector<ID>,                  // Reference to markets(Buck, USDC, SUI and etc.)
        
        // Primary market orders
        pending_writer_orders: Table<ID,ID>,  
        pending_buyer_orders: Table<ID,ID>,   
        
        // Secondary market listings
        secondary_market_listings: Table<ID,ID>, 
        
        // Status tracking
        active_options: Table<ID, ID>,                // Active options
        exercised_options: Table<ID, ID>,             // Exercised options
        expired_options: Table<ID, ID>,               // Expired options
        
        // Statistics
        last_matched_timestamp: u64,            // When last order was matched
        created_at: u64,                        // When orderbook was created
    }

    
    // ====== Events ======

    /// Event emitted when a market is created
    public struct MarketCreatedEvent has copy, drop {
        market_id: ID,
        market_name: String,
        trading_coin_type: String,
        creation_date: u64,
    }

    public struct OrderBookCreatedEvent has copy, drop {
        orderbook_id: ID,
        orderbook_name: String,
        creation_date: u64,
    }

    // ====== Initialization Functions ======

    /// Initialize the module and create the admin capability
    fun init(ctx: &mut TxContext) {
        let admin_cap = AdminCap {
            id: object::new(ctx)
        };
        transfer::public_transfer(admin_cap, tx_context::sender(ctx));
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

            pending_writer_orders: table::new<ID,ID>(ctx),
            pending_buyer_orders: table::new<ID,ID>(ctx),
            secondary_market_listings: table::new<ID,ID>(ctx),
            active_options: table::new<ID,ID>(ctx),
            exercised_options: table::new<ID,ID>(ctx),
            expired_options: table::new<ID,ID>(ctx),
            
            last_matched_timestamp: 0,
            created_at: current_time,
        };

        event::emit(OrderBookCreatedEvent {
            orderbook_id: object::id(&orderbook),
            orderbook_name: orderbook_name,
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
        exercise_fee_percentage: u64,
        ctx: &mut TxContext
    ) {

        let current_time = clock.timestamp_ms();
        
        let market_id = object::new(ctx);
        
        let market = Market<TradingCoinType> {
            id: market_id,
            market_name: name,

            trading_fee_percentage: trading_fee_percentage,
            exercise_fee_percentage: exercise_fee_percentage,

            fee_balance: balance::zero(),

            creation_date: current_time,
            exericse_date: option::none(),
            expiration_date: option::none(),
            
            underlying_asset_type: option::none(),
            decimal: 0u8,

            total_premium_volume: 0u64,
            total_collateral_volume: 0u64,
            active_options_count: 0u64,
            secondary_market_volume: 0u64,
        };
        
        // add market to orderbook
        vector::push_back(&mut orderbook.market_id, object::id(&market));
        
        // Emit market created event
        event::emit(MarketCreatedEvent {
            market_id: object::id(&market),
            market_name: name,
            trading_coin_type: string::from_ascii(*type_name::borrow_string(&type_name::get<TradingCoinType>())),
            creation_date: current_time,
        });
        
        // Transfer market to admin and orderbook as shared
        transfer::share_object(market);
    }


    // ====== Market Admin Functions ======

    /// Set TGE date (admin only)
    public fun set_exericse_expiration_date<CoinType>(
        market: &mut Market<CoinType>,
        _: &AdminCap,
        clock: &Clock,
        exericse_date: u64,
        expiration_date: u64,
    ) {
        // Validate dates
        let current_time = clock.timestamp_ms();
        assert!(exericse_date > current_time, EInvalidDate);
        assert!(expiration_date > exericse_date, EInvalidDate);
        
        // Set TGE date and exercise period
        market.exericse_date = option::some(exericse_date);
        market.expiration_date = option::some(expiration_date);
    }

    /// Set underlying asset address after TGE (admin only)
    public fun set_underlying_asset<CoinType>(
        market: &mut Market<CoinType>,
        _: &AdminCap,
        underlying_asset_address: String,
        decimal: u8,
    ) {
        // Ensure TGE date has been set
        assert!(option::is_some(&market.exericse_date), ETGENotSet);
        
        // Set underlying asset and enable exercising
        market.underlying_asset_type = option::some(underlying_asset_address);
    }


    /// Withdraw accumulated fees (admin only)
    public fun withdraw_fees<CoinType>(
        market: &mut Market<CoinType>,
        _: &AdminCap,
        ctx: &mut TxContext
    ): Coin<CoinType> {
    
        // Extract all accumulated fees
        let fee_balance = balance::withdraw_all(&mut market.fee_balance);
        coin::from_balance(fee_balance, ctx)
    }

    

    // ====== Helper Functions ======

    // assert whether the underlying assets is aligned with the market
    public fun assert_underlying_asset_aligned<TradingCoinType>(
        market: &Market<TradingCoinType>,
        underlying_asset_address: String,
    ) {
        // check whether the underlying asset is set
        assert!(option::is_some(&market.underlying_asset_type), EUnderlyingAssetNotSet);
        // check whether the underlying asset is aligned with the market
        assert!(market.underlying_asset_type == option::some(underlying_asset_address), EUnderlyingAssetNotAligned);
    }


    // ====== Update Orderbook Functions ======   

    // push covered-put option id into orderbook's pending writer orders
    public fun push_covered_put_option_id_into_pending_writer(
        orderbook: &mut OrderBook,
        covered_put_option_id: ID,
    ) {
        table::add(&mut orderbook.pending_writer_orders, covered_put_option_id, covered_put_option_id);
    }
    // push covered-put option id into orderbook's pending buyer orders
    public fun push_covered_put_option_id_into_pending_buyer(
        orderbook: &mut OrderBook,
        covered_put_option_id: ID,
    ) {
        table::add(&mut orderbook.pending_buyer_orders, covered_put_option_id, covered_put_option_id);
    }

    // push covered-put option id into orderbook's secondary market listings
    public fun push_covered_put_option_id_into_secondary_market(
        orderbook: &mut OrderBook,
        covered_put_option_id: ID,
    ) {
        table::add(&mut orderbook.secondary_market_listings, covered_put_option_id, covered_put_option_id);
    }

    // push covered-put option id into orderbook's active options
    public fun push_covered_put_option_id_into_active(
        orderbook: &mut OrderBook,
        covered_put_option_id: ID,
    ) {
        table::add(&mut orderbook.active_options, covered_put_option_id, covered_put_option_id);
    }

    // push covered-put option id into orderbook's exercised options
    public fun push_covered_put_option_id_into_exercised(
        orderbook: &mut OrderBook,
        covered_put_option_id: ID,
    ) {
        table::add(&mut orderbook.exercised_options, covered_put_option_id, covered_put_option_id);
    }

    // push covered-put option id into orderbook's expired options
    public fun push_covered_put_option_id_into_expired(
        orderbook: &mut OrderBook,
        covered_put_option_id: ID,
    ) {
        table::add(&mut orderbook.expired_options, covered_put_option_id, covered_put_option_id);
    }

    // pop up covered-put option id from orderbook's pending writer orders
    public fun pop_covered_put_option_id_from_pending_writer(
        orderbook: &mut OrderBook,
        covered_put_option_id: ID,
    ) {
        table::remove(&mut orderbook.pending_writer_orders, covered_put_option_id);
    }

    // pop up covered-put option id from orderbook's pending buyer orders
    public fun pop_covered_put_option_id_from_pending_buyer(
        orderbook: &mut OrderBook,
        covered_put_option_id: ID,
    ) {
        table::remove(&mut orderbook.pending_buyer_orders, covered_put_option_id);
    }

    // pop up covered-put option id from orderbook's secondary market listings  
    public fun pop_covered_put_option_id_from_secondary_market(
        orderbook: &mut OrderBook,
        covered_put_option_id: ID,
    ) {
        table::remove(&mut orderbook.secondary_market_listings, covered_put_option_id);
    }

    // pop up covered-put option id from orderbook's active options 
    public fun pop_covered_put_option_id_from_active(
        orderbook: &mut OrderBook,
        covered_put_option_id: ID,
    ) {
        table::remove(&mut orderbook.active_options, covered_put_option_id);
    }

    // pop up covered-put option id from orderbook's exercised options
    public fun pop_covered_put_option_id_from_exercised(
        orderbook: &mut OrderBook,
        covered_put_option_id: ID,
    ) {
        table::remove(&mut orderbook.exercised_options, covered_put_option_id);
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
