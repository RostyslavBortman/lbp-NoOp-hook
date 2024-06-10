# LPB Hook (NoOp)

### Introduction

The Uniswap V4 LBP NoOp Hook is a specialized hook designed for use with Liquidity Bootstrapping Pools (LBPs). The primary function of this hook is to serve as a "No Operation" (NoOp) placeholder, which can be utilized in scenarios where specific actions or logic need to override the Pool Manager (PM) operations such as swaps. This hook is particularly useful for developers who need to implement custom behavior during the lifecycle events of an LBP without altering the core logic of the PM.

### Features

- No Operation Hook: A simple and efficient NoOp hook implementation for Uniswap V4 LBPs.
- Customizable: Provides a baseline hook that can be extended or modified to fit specific needs.

### Understanding Liquidity Bootstrapping Pools (LBP)

Liquidity Bootstrapping Pools (LBPs) are a specialized type of automated market maker (AMM) designed to facilitate the fair and efficient distribution of new tokens. They achieve this by using adjustable weights in the token pools, which can change over time. This mechanism helps in price discovery and reduces the impact of large buy or sell orders.

**Key Concepts of LBPs** 

- Adjustable Weights: Unlike traditional constant product AMMs, LBPs use variable weights for the tokens in the pool. This means the weight of the new token can start high and gradually decrease, while the weight of the paired token (usually a stablecoin) increases.

- Price Discovery: By adjusting the weights, LBPs allow the market to determine the token's price. As the weight of the new token decreases, the price should ideally find its true market value through supply and demand dynamics.

- Fair Launch: LBPs are designed to prevent front-running and ensure a fair distribution of tokens. The initial high price and subsequent decrease in token weight discourage immediate large buys and encourage more gradual participation.

### Setting Up

- `forge test`

### Flow

The hook acts as a middleman between the User and the Pool Manager.

Liquidity Providers add liquidity through the hook, where the hook takes their tokens and put that liquidity into Pool Manager without actual tick range. 

**Initialization Phase**
- Create the Pool: A new LBP is created with two tokens: the new token (e.g., Token A) and a paired token (e.g., Token B, often a stablecoin).
- Set Initial Weights: The initial weights are set, typically with the new token having a higher weight (e.g., 90% Token A and 10% Token B).

**Bootstrapping Phase**
- Weight Adjustment: Over the time of the bootstrapping period, the weights are adjusted. For example, Token A's weight might decrease from 90% to 10%, while Token B's weight increases from 10% to 90%.
- Price Adjustment: As the weights change, the price of Token A adjusts accordingly. Initially, the high weight of Token A results in a higher price. As the weight decreases, the price gradually lowers, allowing for price discovery.

**Trading Phase**
- Swaps and Liquidity: Users can trade between Token A and Token B within the pool. The changing weights influence the price dynamics, encouraging more organic price discovery and participation.
- Fair Participation: The gradual decrease in Token A's weight discourages early speculation and allows more participants to acquire tokens at a fair market price.

**Finalization Phase**
- Completion: After the bootstrapping period, the weights stabilize at their final values (e.g., 10% Token A and 90% Token B).
- Pool Conversion: The LBP can be converted to a standard AMM pool or the liquidity can be removed as desired.

### Further Improvements

- Add function to withdraw liquidity (from Pool Manager) & Add liquidity into the specified by manager range, after LBP sale has ended;
- Add additional modifications like fees adjustment, whitelist, vesting schedule for the users, etc.;
- Add more tests; 

LBP functionality library was taken from https://www.fjordfoundry.com/
