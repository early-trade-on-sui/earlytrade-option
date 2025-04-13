module earlytrade::test_coin;
use sui::coin;
use sui::url;

public struct TEST_COIN has drop {}

const DECIMALS: u8 = 6;
const SYMBOL: vector<u8> = b"TEST";
const NAME: vector<u8> = b"TEST Coin";
const DESCRIPTION: vector<u8> = b"TEST Coin Description";
const ICON_URL: vector<u8> = b"https://example.com/icon.png";


fun init(otw: TEST_COIN, ctx: &mut TxContext) {
    let (treasury_cap, coin_metadata) = coin::create_currency(
        otw, 
        DECIMALS, 
        SYMBOL, 
        NAME, 
        DESCRIPTION, 
        option::some(url::new_unsafe_from_bytes(ICON_URL)), 
        ctx
    );

    transfer::public_transfer(treasury_cap, ctx.sender());
    transfer::public_share_object(coin_metadata);
}

#[test_only]
public fun test_init(ctx: &mut TxContext) {
    let otw = TEST_COIN {};
    init(otw, ctx);
}
