// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ILumineonPriceFeed} from "../../src/interfaces/ILumineonPriceFeed.sol";

/// @notice A minimal contract that depends on the feed, showing both read styles.
/// @dev Example only; it is not part of the deployment.
contract ExampleConsumer {
    ILumineonPriceFeed public immutable feed;

    error PriceAboveBudget(uint256 priceCents, uint256 budgetCents);

    constructor(ILumineonPriceFeed feed_) {
        feed = feed_;
    }

    /// @notice Strict: reverts (bubbling the feed's error) unless the feed has a fresh price.
    function requireAffordable(uint256 budgetCents) external view returns (uint256 priceCents) {
        (priceCents,) = feed.priceCents();
        if (priceCents > budgetCents) revert PriceAboveBudget(priceCents, budgetCents);
    }

    /// @notice Lenient: returns the last price and freshness, zero when the feed is empty.
    function lastKnownPrice() external view returns (uint256 priceCents, bool fresh, uint64 issuedAt) {
        (ILumineonPriceFeed.Observation memory o, bool isFresh) = feed.latestObservation();
        return (o.priceCents, isFresh, o.issuedAt);
    }

    /// @notice Price in whole dollars, truncated, from the strict reader.
    function priceDollars() external view returns (uint256) {
        (uint256 cents,) = feed.priceCents();
        return cents / 100;
    }
}
