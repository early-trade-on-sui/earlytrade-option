# EarlyTrade Option

A covered-put option trading marketplace on Sui for early trading before TGE (Token Generation Event).

## Overview

This project allows users who will receive tokens after TGE to buy covered-put options to lock in prices. Option writers can gain exposure before TGE and earn premiums from buyers.

## Features

- Buyers can create covered-put option orders, pay premiums, and set strike prices
- Writers can set strike prices and premiums, waiting for buyers
- Writers can accept options by paying collateral
- Buyers can accept the option, pay premiums from existing orders
- After TGE, buyers can exercise options to get covered assets
- Unexercised options return collateral to writers after expiration

## To-Do List

1. ✅ Add minimum trading assets feature:
   - ✅ Implement minimum trading assets value validation
   - ✅ When users place an order, the value of assets should exceed min_trading_assets_value
   - ✅ Add configuration for administrators to set minimum values

2. Integrate Scallop to improve capital efficiency:
   - Implement Scallop integration for collateral assets
   - Allow writers to deposit collateral into Scallop lending pools
   - Enable earning interest on locked collateral while options are active
   - Add withdrawal mechanisms for interest earned
   - Implement safety measures to ensure collateral availability for exercise
   - Support automatic rebalancing of collateral based on market conditions


3. Add secondary market functionality:
   - Implement option listing and delisting on secondary market
   - Allow option holders to set a selling price
   - Enable other users to purchase listed options
   - Implement transfer of ownership when options are sold
   - Add events for tracking secondary market activities
   - Support cancellation of listings


4. Add potato pattern to improve composability - trading fee reduction, referal fees:
   - Refactor option creation and filling to use the potato pattern
   - Separate creation logic from transaction effects
   - Allow for better composability with other modules
   - Implement builder pattern for option creation


## Rules

- Collateral, premium, and option price must be in the same coin type
- Options must be exercised in the same coin type
- Trading fees (1%) are paid to the administrator
