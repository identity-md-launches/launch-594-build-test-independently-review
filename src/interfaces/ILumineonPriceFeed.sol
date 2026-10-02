// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The reader surface another contract needs from LumineonPriceFeed.
interface ILumineonPriceFeed {
    struct Observation {
        uint256 priceCents;
        bytes32 requestId;
        bytes32 questionHash;
        bytes32 panelJobId;
        uint64 issuedAt;
        uint64 expiresAt;
        uint64 receivedAt;
        uint16 panelSize;
        uint16 quorum;
        uint16 agreed;
    }

    /// @notice Strict reader: reverts with NoObservation() or StalePrice(...) when unusable.
    function priceCents() external view returns (uint256 cents, uint64 issuedAt);

    /// @notice Lenient reader: last observation (zeroed when none) and whether it is fresh.
    function latestObservation() external view returns (Observation memory observation, bool fresh);

    function hasObservation() external view returns (bool);
    function isFresh() external view returns (bool);
    function observationAge() external view returns (uint256);
    function description() external pure returns (string memory);
}
